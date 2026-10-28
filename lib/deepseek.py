"""Pinned, resumable DeepSeek model deployment. No driver/package changes."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import subprocess
import tarfile
import time

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "configs/deepseek/manifest.json").read_text())
STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "ubuntu-setup/deepseek"


def save(path, data):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def guard(data, mount):
    data, mount = Path(data), Path(mount)
    for path in (data, mount):
        if not path.is_absolute() or any(c.isspace() or c in '%"\\' for c in str(path)):
            raise ValueError("Use absolute paths without whitespace, quotes, backslash or %")
    mount = mount.resolve(strict=True)
    if not os.path.ismount(mount) or mount.stat().st_dev == Path('/').stat().st_dev:
        raise ValueError("Backing mount must be a mounted filesystem separate from /")
    data = data.resolve()
    if data == mount or mount not in data.parents:
        raise ValueError("Data directory must be below the backing mount")
    ancestor = data
    while not ancestor.exists():
        ancestor = ancestor.parent
    if ancestor.stat().st_dev != mount.stat().st_dev:
        raise ValueError("Unexpected nested mount for data directory")
    return data, mount


def digest(path):
    with path.open('rb') as stream:
        value = hashlib.sha256()
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def check(path, item, full=True):
    if not path.is_file() or path.is_symlink() or path.stat().st_size != item['size']:
        raise ValueError(f"Missing, linked or wrong-size file: {path}")
    if full and digest(path) != item['sha256']:
        raise ValueError(f"SHA256 mismatch: {path}; file retained for inspection")


def download(url, path, item):
    if path.exists():
        check(path, item)
        print(f"Verified existing {path.name}", flush=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + '.part')
    if partial.is_symlink():
        raise ValueError(f"Refusing linked partial file: {partial}")
    print(f"Downloading {path.name} ({item['size']} bytes)", flush=True)
    subprocess.run(['curl', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
                    '--silent', '--show-error', '--retry', '4', '--retry-delay', '3',
                    '--connect-timeout', '30', '--speed-limit', '1024', '--speed-time', '120',
                    '--continue-at', '-', '--output', str(partial), url], check=True)
    check(partial, item)
    partial.replace(path)
    print(f"SHA256 OK {path.name}", flush=True)


def config():
    state = json.loads((STATE / 'config.json').read_text())
    data, mount = guard(state['data_dir'], state['backing_mount'])
    if mount_uuid(mount) != state['mount_uuid']:
        raise ValueError("Backing filesystem changed since installation")
    return state, data, mount


def mount_uuid(mount):
    value = subprocess.check_output(['findmnt', '--noheadings', '--output', 'UUID', '--target', str(mount)], text=True).strip()
    if not value:
        raise ValueError('Backing filesystem needs a stable UUID')
    return value


def model_files(data):
    for item in MANIFEST['shards']:
        yield data / 'models' / item['path'], item


def installed(full=False):
    _, data, _ = config()
    for path, item in model_files(data):
        check(path, item, full=full)
    binary = data / 'runtime/llama-server'
    if not os.access(binary, os.X_OK):
        raise ValueError(f"Runtime unavailable: {binary}")
    version = subprocess.run([str(binary), '--version'], check=True, timeout=30, capture_output=True, text=True)
    print(version.stdout + version.stderr, end='', flush=True)
    print(f"DeepSeek-V4.1-Flash-1017 UD-IQ1_S: {data}", flush=True)
    return data


def unit_text(data, mount, user):
    model = next(model_files(data))[0]
    escaped_mount = subprocess.check_output(['systemd-escape', '--path', '--suffix=mount', str(mount)], text=True).strip()
    # Small initial context and one request at a time bound memory demand. Fit chooses
    # GPU placement after reboot; the Engram table remains lazily mapped on SSD.
    command = [str(data / 'runtime/llama-server'), '--model', str(model),
               '--alias', 'deepseek-v4.1-flash-1017', '--host', '127.0.0.1', '--port', '18080',
               '--ctx-size', '4096', '--parallel', '1', '--threads', '24',
               '--batch-size', '128', '--ubatch-size', '128', '--gpu-layers', 'auto',
               '--load-mode', 'mmap', '--lazy-mode', 'on',
               '--override-tensor', 'per_layer_token_embd.weight=CPU',
               '--temp', '1.0', '--top-p', '1.0', '--top-k', '0', '--min-p', '0.0',
               '--jinja', '--chat-template-kwargs', '{"reasoning_effort":75}']
    quoted = ' '.join('"' + token.replace('\\', '\\\\').replace('"', '\\"') + '"' for token in command)
    return f'''# Managed by ubuntu-setup deepseek
[Unit]
Description=DeepSeek V4.1 Flash 1017 local inference
RequiresMountsFor={mount}
ConditionPathIsMountPoint={mount}
BindsTo={escaped_mount}
After={escaped_mount}

[Service]
Type=simple
User={user}
WorkingDirectory={data}
ExecStartPre=/usr/bin/nvidia-smi -L
ExecStart={quoted}
Restart=no
TimeoutStopSec=90
MemoryHigh=112G
MemoryMax=118G
MemorySwapMax=0
Nice=5
NoNewPrivileges=true
UMask=0077

[Install]
WantedBy=multi-user.target
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['plan', 'install', 'verify', 'status', 'unit'])
    parser.add_argument('--data-dir')
    parser.add_argument('--backing-mount')
    args = parser.parse_args()
    if args.action in ('plan', 'install'):
        if not args.data_dir or not args.backing_mount:
            parser.error('--data-dir and --backing-mount are required')
        if platform.machine() != 'x86_64' or platform.system() != 'Linux':
            raise ValueError('Pinned binary supports Linux x86_64 only')
        data, mount = guard(args.data_dir, args.backing_mount)
        total = sum(s['size'] for s in MANIFEST['shards']) + MANIFEST['runtime']['size']
        remaining = total - sum(min(p.stat().st_size, s['size']) for p, s in model_files(data) if p.is_file())
        free = shutil.disk_usage(mount).free
        print(json.dumps({'data_dir':str(data), 'backing_mount':str(mount),
                          'total_download_bytes':total, 'free_bytes':free,
                          'required_free_bytes':remaining + 2 * 1024**3,
                          'model_revision':MANIFEST['model_revision'],
                          'runtime':MANIFEST['runtime']['tag']}, indent=2), flush=True)
        if free < remaining + 2 * 1024**3:
            raise ValueError('Insufficient free space')
        if args.action == 'plan':
            return
        if os.geteuid() == 0:
            raise ValueError('Run installation as the intended ordinary user')
        STATE.mkdir(parents=True, mode=0o700, exist_ok=True)
        with (STATE / 'install.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            data.mkdir(parents=True, mode=0o700, exist_ok=True)
            record = {'data_dir':str(data), 'backing_mount':str(mount), 'mount_uuid':mount_uuid(mount)}
            if (STATE / 'config.json').exists() and json.loads((STATE / 'config.json').read_text()) != record:
                raise ValueError('Existing deployment uses another location; refusing replacement')
            save(STATE / 'config.json', record)
            runtime = MANIFEST['runtime']
            archive = data / 'downloads' / runtime['asset']
            download(runtime['url'], archive, runtime)
            target = data / 'runtime'
            if not (target / 'llama-server').exists():
                staging = data / 'runtime-staging'
                staging.mkdir(exist_ok=True)
                with tarfile.open(archive) as tar:
                    tar.extractall(staging, filter='data')
                binaries = list(staging.rglob('llama-server'))
                if len(binaries) != 1:
                    raise ValueError('Expected one llama-server in verified archive')
                binaries[0].parent.rename(target)
            help_text = subprocess.check_output([str(target / 'llama-server'), '--help'], text=True, timeout=30)
            for flag in ['--lazy-mode', '--load-mode', '--override-tensor', '--gpu-layers', '--chat-template-kwargs']:
                if flag not in help_text:
                    raise ValueError(f'Runtime lacks required feature: {flag}')
            save(STATE / 'runtime.json', {'sha256':runtime['sha256'], 'tag':runtime['tag'], 'checked_at':time.time()})
            for path, item in model_files(data):
                guard(data, mount)
                url = f"https://huggingface.co/{MANIFEST['model_repo']}/resolve/{MANIFEST['model_revision']}/{item['path']}?download=true"
                download(url, path, item)
            installed()
            save(STATE / 'verified.json', {'manifest':MANIFEST, 'checked_at':time.time()})
    elif args.action in ('status', 'verify'):
        installed(full=args.action == 'verify')


if __name__ == '__main__':
    # unit output is used by the Bash entry point as one filename.
    import contextlib
    import sys
    try:
        if len(sys.argv) == 2 and sys.argv[1] == 'unit':
            with contextlib.redirect_stdout(sys.stderr):
                data = installed()
            _, _, mount = config()
            STATE.mkdir(parents=True, mode=0o700, exist_ok=True)
            candidate = STATE / 'deepseek-local.service'
            candidate.write_text(unit_text(data, mount, pwd.getpwuid(os.getuid()).pw_name))
            print(candidate)
        else:
            main()
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
