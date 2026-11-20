#!/usr/bin/env python3
"""Validate and update the official Sogou hotword supplement in Rime Frost."""

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlencode

import yaml

from prepare import (
    FROST, MERGED, PACKS, existing_words, personal_words, read_header, read_scel,
    supplemental_table,
)


HOT = "sogou_hotwords"
HOT_FILE = f"{HOT}.dict.yaml"
TABLE = Path("build") / f"{MERGED}.table.bin"
ARTIFACTS = tuple(Path("build") / f"{MERGED}.{extension}.bin"
                  for extension in ("table", "prism", "reverse"))
SCHEMA = Path("build") / f"{FROST}.schema.yaml"
PREVIOUS = "previous.dict.yaml"
PENDING = "pending.json"
IGNORE = shutil.ignore_patterns("build", "build.bak.*", "*.bak.*", "*.userdb*",
                                "installation.yaml", "user.yaml", "sync", ".*")
SERVICE = "org.fcitx.Fcitx5"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def table_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_atomic(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as stream:
        tmp = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            stream.close()
            tmp.replace(path)
        finally:
            tmp.unlink(missing_ok=True)


def run(arguments, *, cwd=None, env=None, timeout=90):
    result = subprocess.run(arguments, cwd=cwd, env=env, timeout=timeout,
                            capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name} 退出码 {result.returncode}")
    return result.stdout.strip()


def desktop_env():
    env = os.environ.copy()
    runtime = env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={runtime}/bus")
    answer = run(["busctl", "--user", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
                  "org.freedesktop.DBus", "NameHasOwner", "s", SERVICE], env=env, timeout=5)
    if answer != "b true":
        raise RuntimeError("未连接到桌面 Fcitx5，保留当前词库")
    return env


def build_digests(rime):
    return {str(path): table_digest(rime / path) for path in ARTIFACTS}


def matches_build(rime, expected):
    try:
        return all(table_digest(rime / name) == digest for name, digest in expected.items())
    except FileNotFoundError:
        return False


def deploy(rime, expected, env):
    if matches_build(rime, expected):
        return
    run(["busctl", "--user", "--timeout=8", "call", SERVICE, "/controller",
         "org.fcitx.Fcitx.Controller1", "SetConfig", "sv",
         "fcitx://config/addon/rime/deploy", "a{sv}", "0"], env=env, timeout=10)
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if matches_build(rime, expected):
            return
        time.sleep(0.5)
    raise RuntimeError("桌面 RIME 未在时限内加载已验证的词库")


def recover(rime, state, env):
    marker = state / PENDING
    journal = json.loads(marker.read_text())
    if journal["rime"] != str(rime):
        raise RuntimeError("待回退记录属于另一个 RIME 目录")
    path = rime / HOT_FILE
    old = (state / PREVIOUS).read_bytes()
    if sha(old) != journal["old_source"]:
        raise RuntimeError("旧词库备份校验失败，未写入桌面配置")
    current = sha(path.read_bytes())
    if current == journal["new_source"]:
        write_atomic(path, old)
    elif current != journal["old_source"]:
        raise RuntimeError("当前词库已由其他进程修改，保留现有文件")
    deploy(rime, journal["old_build"], env)
    marker.unlink()


def signatures(directory, ignore):
    result = {}
    for parent, subdirs, files in os.walk(directory):
        skipped = ignore(parent, [*subdirs, *files])
        subdirs[:] = [name for name in subdirs if name not in skipped]
        for name in files:
            if name not in skipped:
                path = Path(parent) / name
                st = path.stat()
                result[str(path.relative_to(directory))] = (st.st_size, st.st_mtime_ns, st.st_ino)
    return result


def copy_personal(rime, work, user_dict, tools):
    name = f"{user_dict}.userdb"
    source = rime / name
    if not source.exists():
        return set()
    copy = work / name
    for _ in range(3):
        try:
            before = signatures(source, lambda *_: ())
            shutil.copytree(source, copy, ignore=shutil.ignore_patterns("LOCK"))
            if signatures(source, lambda *_: ()) == before:
                break
        except FileNotFoundError:
            pass
        if copy.exists():
            shutil.rmtree(copy)
        time.sleep(0.1)
    else:
        raise RuntimeError("个人词库正在写入，无法取得一致的只读副本")
    run([tools / "rime_dict_manager", "-b", user_dict], cwd=work)
    files = list((work / "sync").rglob(f"{user_dict}.userdb.txt"))
    if len(files) != 1:
        raise RuntimeError("未能从隔离副本导出个人词库")
    return personal_words(files[0])


def bindings(profile):
    data = yaml.safe_load((profile / SCHEMA).read_text())
    return {name: data[name] for name in ("translator", "grammar", "speller") if name in data}


def verify_compilation(profile, work, tools, current, supplement):
    run([tools / "rime_deployer", "--build", profile, "/usr/share/rime-data"], cwd=profile)
    if bindings(profile) != current:
        raise RuntimeError("试编译改变了主词库、个人词库、整句模型或拼写设置")
    output = work / "compiled.dict.yaml"
    run([tools / "rime_table_decompiler", profile / TABLE, output], cwd=work)
    expected = {tuple(row.split("\t")[:2]) for row in supplement.split("...\n", 1)[1].splitlines()}
    with output.open(encoding="utf-8-sig") as stream:
        read_header(stream, output)
        for line in stream:
            expected.discard(tuple(line.split("\t")[:2]))
    if expected:
        raise RuntimeError(f"试编译未收录 {len(expected)} 条候选热词")
    return build_digests(profile)


def publish(rime, state, existing, candidate, old_build, new_build, env):
    write_atomic(state / PREVIOUS, existing)
    journal = dict(rime=str(rime), old_source=sha(existing), new_source=sha(candidate), old_build=old_build)
    write_atomic(state / PENDING, json.dumps(journal).encode())
    try:
        write_atomic(rime / HOT_FILE, candidate)
        deploy(rime, new_build, env)
    except BaseException:
        recover(rime, state, env)
        raise
    (state / PENDING).unlink()


def update(args):
    rime = args.rime_dir.resolve()
    state = args.state_dir.resolve()
    if state.is_relative_to(rime):
        raise ValueError("运行记录须保存在 RIME 用户目录之外")
    if not rime.is_dir():
        raise ValueError(f"找不到 RIME 用户目录 {rime}")
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (state / "update.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if (state / PENDING).exists():
            if args.verify_only:
                raise RuntimeError("有未完成的更新，须先核对并回退")
            recover(rime, state, desktop_env())
        with tempfile.TemporaryDirectory(prefix="trial-", dir=state) as directory:
            work = Path(directory)
            run_update(args, rime, state, work)


def run_update(args, rime, state, work):
    old_file = rime / HOT_FILE
    existing = old_file.read_bytes()
    origin = re.search(rb"^# SCEL SHA-256 ([0-9a-f]{64})$", existing, re.M)
    if old_file.is_symlink() or not origin:
        raise RuntimeError("当前热词文件不符合本 Skill 生成的格式，保留原文件")
    pack = PACKS[0]
    if args.source:
        data = args.source.read_bytes()
    else:
        source = work / "hotwords.scel"
        query = urlencode({"id": pack[1], "name": pack[2], "f": "detail"})
        run(["curl", "--fail", "--location", "--silent", "--show-error", "--proto", "=https",
             "--proto-redir", "=https", "--connect-timeout", "8", "--max-time", "35",
             "--max-filesize", "10000000", "--output", source,
             "https://pinyin.sogou.com/d/dict/download_cell.php?" + query])
        data = source.read_bytes()
    entries = read_scel(data, pack[2])
    if sha(data) == origin[1].decode() and not args.verify_only:
        print("unchanged")
        return

    before = signatures(rime, IGNORE)
    old_build = build_digests(rime)
    current = bindings(rime)
    translator = current["translator"]
    user_dict = translator.get("user_dict")
    if translator.get("dictionary") != MERGED or not isinstance(user_dict, str) or not re.fullmatch(r"[\w.-]+", user_dict):
        raise RuntimeError("当前白霜主词库或个人词库绑定已变化")
    profile = work / "rime"
    shutil.copytree(rime, profile, ignore=IGNORE)
    merged = profile / f"{MERGED}.dict.yaml"
    with merged.open(encoding="utf-8-sig") as stream:
        if HOT not in read_header(stream, merged).get("import_tables", []):
            raise RuntimeError("网络流行新词已在汇总词库中关闭")
    dictionaries = [MERGED]
    if (profile / "melt_eng.dict.yaml").is_file():
        dictionaries.append("melt_eng")
    stock = existing_words(profile, dictionaries, {word for word, _ in entries}, skip={HOT})
    tools = args.tools_dir.resolve() if args.tools_dir else state / "tools"
    personal = copy_personal(rime, work, user_dict, tools)
    content, stats = supplemental_table(pack, data, entries, stock, personal, stock | personal)
    if not stats["added"]:
        raise RuntimeError("转换后没有可用热词，保留当前版本")
    candidate = content.encode()
    (profile / HOT_FILE).write_bytes(candidate)
    new_build = verify_compilation(profile, work, tools, current, content)
    if args.verify_only:
        print(json.dumps({"status": "verified", **stats}, ensure_ascii=False))
        return

    env = desktop_env()
    if old_file.read_bytes() != existing or signatures(rime, IGNORE) != before or not matches_build(rime, old_build):
        raise RuntimeError("试编译期间白霜配置发生变化，保留现在的版本")
    publish(rime, state, existing, candidate, old_build, new_build, env)
    print(json.dumps({"status": "updated", **stats}, ensure_ascii=False))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rime-dir", type=Path, default=Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "fcitx5/rime")
    parser.add_argument("--state-dir", type=Path, default=Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "ubuntu-setup/rime-hotwords")
    parser.add_argument("--tools-dir", type=Path)
    parser.add_argument("--source", type=Path, help="仅用于试编译的本地 SCEL")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.source and not args.verify_only:
        parser.error("--source 仅支持 --verify-only")
    try:
        update(args)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError, yaml.YAMLError) as e:
        parser.exit(1, f"热词更新失败：{e}\n")


if __name__ == "__main__":
    main()
