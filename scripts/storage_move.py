#!/usr/bin/env python3
"""Recorded directory relocation: copy, verify, exchange, check, then retire.

This is an explicit per-directory maintenance tool, not an automatic cleanup.
Machine paths and execution records belong in the caller's private state directory.
"""
import argparse
import ctypes
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def exchange(left, right):
    """Linux atomic exchange keeps the original pathname continuously present."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renameat2(-100, os.fsencode(left), -100, os.fsencode(right), 2):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def writers(path):
    prefix = str(path).rstrip('/') + '/'
    found = []
    for process in Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            for fd in (process/'fd').iterdir():
                try:
                    target = os.readlink(fd)
                    if target != str(path) and not target.startswith(prefix):
                        continue
                    flags = re.search(r'^flags:\s*([0-7]+)',
                                      (process/'fdinfo'/fd.name).read_text(), re.M)
                    if flags and int(flags.group(1), 8) & os.O_ACCMODE:
                        found.append({'pid':int(process.name), 'path':target})
                except OSError:
                    pass
        except OSError:
            pass
    if found:
        raise RuntimeError('Directory has active writable file descriptors: ' + json.dumps(found))


def mount_guard(mount):
    """Generate a systemd drop-in for a service that depends on a data disk."""
    mount = Path(mount).absolute()
    if not mount.is_mount() or any(c.isspace() for c in str(mount)):
        raise RuntimeError('Mount guard requires an existing mount without whitespace')
    unit = subprocess.run(['systemd-escape', '--path', '--suffix=mount', str(mount)],
                          check=True, capture_output=True, text=True).stdout.strip()
    return (f'[Unit]\nRequiresMountsFor={mount}\nConditionPathIsMountPoint={mount}\n'
            f'BindsTo={unit}\nAfter={unit}\n')


class Move:
    def __init__(self, record):
        self.record = Path(record)
        self.data = json.loads(self.record.read_text())

    def save(self):
        self.data['updated_at'] = now()
        temporary = self.record.with_suffix('.tmp')
        with temporary.open('w') as stream:
            os.chmod(temporary, 0o600)
            json.dump(self.data, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(self.record)

    def run(self, command, *, privileged=None, capture=False):
        if privileged is None:
            privileged = self.data.get('privileged', False)
        invocation = list(map(str, command))
        if privileged:
            common = Path(__file__).resolve().parents[1] / 'lib/common.sh'
            invocation = ['bash', '-c', 'source "$1"; shift; sudo_run "$@"',
                          'storage-move', str(common), *invocation]
        number = len(self.data.setdefault('commands', [])) + 1
        log = self.record.parent / f'{self.record.stem}-{number:03d}.log'
        self.data['commands'].append({'command':list(map(str, command)),
                                     'privileged':privileged, 'started_at':now(),
                                     'log':str(log)})
        self.save()
        with log.open('w') as stream:
            os.chmod(log, 0o600)
            if capture:
                result = subprocess.run(invocation, capture_output=True, text=True)
                stream.write(result.stdout)
                stream.write(result.stderr)
            else:
                result = subprocess.run(invocation, stdout=stream, stderr=stream)
        self.data['commands'][-1].update(exit_code=result.returncode, finished_at=now())
        self.save()
        if result.returncode:
            raise RuntimeError(f'Command failed ({result.returncode}); see {log}')
        return result.stdout if capture else None

    def target(self):
        mount = Path(self.data['mount'])
        destination = Path(self.data['destination'])
        if not mount.is_mount() or mount.stat().st_dev != self.data['target_device']:
            raise RuntimeError('Expected destination filesystem is not mounted')
        if not destination.is_relative_to(mount) or str(destination.resolve()) != str(destination):
            raise RuntimeError('Destination path changed or escaped the approved mount')
        if destination.exists() and destination.stat().st_dev != self.data['target_device']:
            raise RuntimeError('Destination device changed')
        if 'destination_inode' in self.data and destination.stat().st_ino != self.data['destination_inode']:
            raise RuntimeError('Destination directory identity changed')
        return destination

    def original(self, retired=False):
        path = Path(self.data['retired'] if retired else self.data['source'])
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or (info.st_dev, info.st_ino) != tuple(self.data['identity']):
            raise RuntimeError('Original directory identity changed')
        return path

    def verify(self, source, *, allow_new_files=False):
        options = ['rsync', '-aHAXSxnc', '--numeric-ids', '--checksum-choice=xxh128',
                   '--itemize-changes', '--out-format=%i %n%L']
        if allow_new_files:
            options.append('--omit-dir-times')
        else:
            options.append('--delete')  # Dry-run only: extra files are a mismatch.
        result = self.run([*options, str(source)+'/', str(self.target())+'/'], capture=True)
        if result.strip():
            raise RuntimeError('Content or metadata verification differs; original retained')

    def copy(self):
        if self.data['state'] not in ['planned', 'copying', 'copied']:
            raise RuntimeError('Copy is only allowed before cutover')
        source = self.original()
        destination = self.target()
        if destination.exists() and 'destination_inode' not in self.data:
            raise RuntimeError('Unrecognized destination from an interrupted creation')
        self.data['state'] = 'copying'
        self.save()
        self.run(['mkdir', '-p', str(destination)])
        self.data['destination_inode'] = destination.stat().st_ino
        self.save()
        self.run(['rsync', '-aHAXSx', '--numeric-ids', '--delete-delay', '--info=progress2,stats2',
                  str(source)+'/', str(destination)+'/'])
        self.data['state'] = 'copied'
        self.save()

    def switch(self):
        if self.data['state'] not in ['copied', 'switching']:
            raise RuntimeError('A verified copy is required before cutover')
        destination = self.target()
        source = Path(self.data['source'])
        retired = Path(self.data['retired'])
        if self.data['state'] == 'switching' and source.is_symlink() and source.resolve() == destination:
            self.verify(self.original(retired=True))
            self.data['state'] = 'switched'
            self.save()
            return
        self.original()
        self.verify(source)
        self.run([sys.executable, str(Path(__file__).resolve()), '_writers', str(source)])
        if retired.exists() or retired.is_symlink():
            raise RuntimeError('Retired path already exists; inspect interrupted cutover')
        self.data['state'] = 'switching'
        self.save()
        self.run(['ln', '-s', str(destination), str(retired)])
        self.run([sys.executable, str(Path(__file__).resolve()), '_exchange',
                  str(source), str(retired)])
        self.original(retired=True)
        if not source.is_symlink() or source.resolve() != destination:
            raise RuntimeError('Compatibility link verification failed')
        self.data['state'] = 'switched'
        self.save()

    def check(self, command):
        if self.data['state'] not in ['switched', 'validated']:
            raise RuntimeError('Switch paths before functional checks')
        self.target()
        self.run(command, privileged=False)
        self.data['state'] = 'validated'
        self.save()

    def finish(self):
        if self.data['state'] not in ['validated', 'retiring']:
            raise RuntimeError('Functional checks are required before removing the original')
        retired = self.original(retired=True)
        source = Path(self.data['source'])
        destination = self.target()
        if not source.is_symlink() or source.resolve() != destination:
            raise RuntimeError('Compatibility link changed; original retained')
        self.verify(retired, allow_new_files=True)
        self.run(['sync', '-f', str(destination)])
        self.target()
        self.data['state'] = 'retiring'
        self.save()
        self.run([sys.executable, str(Path(__file__).resolve()), '_retire',
                  str(retired), str(self.data['identity'][0]), str(self.data['identity'][1])])
        self.data['state'] = 'complete'
        self.save()


def prepare(record, source, destination, mount, privileged=False):
    record, source, destination, mount = map(lambda p:Path(p).absolute(),
                                            [record, source, destination, mount])
    if record.exists() or destination.exists() or destination.is_symlink():
        raise RuntimeError('Record or destination already exists')
    if not source.is_dir() or source.is_symlink() or source.resolve() != source:
        raise RuntimeError('Source must be an existing ordinary directory without aliased parents')
    if len(source.parts) < 3 or destination == source or destination.is_relative_to(source) or source.is_relative_to(destination):
        raise RuntimeError('Unsafe or overlapping directory selection')
    if not mount.is_mount() or not destination.is_relative_to(mount) or destination == mount:
        raise RuntimeError('Select an existing mount and a destination underneath it')
    info = source.stat()
    retired = source.parent / f'.{source.name}.storage-move-{record.stem}'
    if retired.exists() or retired.is_symlink():
        raise RuntimeError('Retired path already exists')
    data = {'schema_version':1, 'created_at':now(), 'state':'planned',
            'source':str(source), 'destination':str(destination), 'mount':str(mount),
            'target_device':mount.stat().st_dev, 'identity':[info.st_dev, info.st_ino],
            'retired':str(retired), 'privileged':privileged, 'commands':[]}
    record.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with record.open('x') as stream:
        os.chmod(record, 0o600)
        json.dump(data, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    return Move(record)


def retire(path, device, inode):
    path = Path(path)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or '.storage-move-' not in path.name
            or (info.st_dev, info.st_ino) != (device, inode)):
        raise RuntimeError('Refusing to remove an unrecognized original directory')
    writers(path)
    for current, dirs, files in os.walk(path, followlinks=False):
        for name in dirs + files:
            if (Path(current)/name).lstat().st_dev != device:
                raise RuntimeError('Nested mount found; original retained')
    shutil.rmtree(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare','copy','switch','check','finish','_exchange','_retire','_writers'])
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    values = args.arguments
    if args.action == '_exchange':
        exchange(*values)
        return
    if args.action == '_retire':
        retire(values[0], int(values[1]), int(values[2]))
        return
    if args.action == '_writers':
        writers(values[0])
        return
    record = Path(values[0])
    record.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (record.parent/(record.name+'.lock')).open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == 'prepare':
            move = prepare(*values[:4], privileged='--privileged' in values[4:])
        else:
            move = Move(record)
            if args.action == 'check':
                move.check(values[1:])
            else:
                getattr(move, args.action)()
        print(json.dumps({'record':str(record), 'state':move.data['state']}, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
