#!/usr/bin/env python3
"""Prepare the two Sogou supplements for an existing Rime Frost profile."""

import argparse
import hashlib
import json
import re
import struct
import unicodedata
from pathlib import Path

import yaml


FROST = "rime_frost"
MERGED = "rime_frost.sogou"
PACKS = (
    ("hotwords", 4, "网络流行新词"),
    ("developer", 75228, "开发大神专用词库"),
)


def read_scel(data, title):
    # SCEL versions 0x44 and 0x45 use different word table offsets.
    if len(data) < 0x2628 or data[:4] != b"\x40\x15\x00\x00" or data[4] not in (0x44, 0x45):
        raise ValueError(f"{title}的 SCEL 文件头无效")
    actual = data[0x130:0x338].decode("utf-16le").split("\x00", 1)[0].strip()
    if not actual.startswith(title):
        raise ValueError(f"下载的词库是 {actual!r}，预期为 {title}")
    word_start = {0x44: 0x2628, 0x45: 0x26C4}[data[4]]
    # Some recent files append auxiliary tables after the primary word section.
    word_end = struct.unpack_from("<I", data, 0x60)[0] or len(data)
    word_count = struct.unpack_from("<I", data, 0x124)[0]
    if not word_start < word_end <= len(data):
        raise ValueError(f"{title}的词条区超出文件边界")
    cursor = 0x1544
    syllable_count = struct.unpack_from("<I", data, 0x1540)[0]

    def take(size):
        nonlocal cursor
        end = cursor + size
        if end > word_end:
            raise ValueError(f"{title}的数据在偏移 {cursor:#x} 处不完整")
        chunk = data[cursor:end]
        cursor = end
        return chunk

    def short():
        return struct.unpack("<H", take(2))[0]

    syllables = {}
    for _ in range(syllable_count):
        index = short()
        syllables[index] = take(short()).decode("utf-16le")
    if len(syllables) != syllable_count or cursor != word_start:
        raise ValueError(f"{title}的拼音表长度不符")

    entries = []
    while cursor < word_end:
        group_count, code_bytes = short(), short()
        if not group_count or not code_bytes or code_bytes % 2:
            raise ValueError(f"{title}的同音词分组无效")
        indexes = [short() for _ in range(code_bytes // 2)]
        if any(index not in syllables for index in indexes):
            raise ValueError(f"{title}引用了不存在的拼音")
        code = " ".join(syllables[index] for index in indexes)
        for _ in range(group_count):
            word = take(short()).decode("utf-16le")
            take(short())
            entries.append((normalize(word), code))
    if len(entries) != word_count:
        raise ValueError(f"{title}实读 {len(entries)} 条，文件声明 {word_count} 条")
    return entries


def normalize(word):
    return unicodedata.normalize("NFC", word.strip())


def read_header(stream, path):
    header = []
    for line in stream:
        if line.strip() == "...":
            metadata = yaml.safe_load("".join(header))
            if not isinstance(metadata, dict):
                raise ValueError(f"词库头部无效 {path}")
            return metadata
        header.append(line)
    raise ValueError(f"词库缺少头部结束标记 {path}")


def export_dictionary(config, body):
    return "---\n" + yaml.safe_dump(config, sort_keys=False, allow_unicode=True) + "...\n" + body


def existing_words(rime, dictionaries, wanted, skip=()):
    found = set()

    def scan(name):
        path = rime / f"{name}.dict.yaml"
        with path.open(encoding="utf-8-sig") as stream:
            metadata = read_header(stream, path)
            for line in stream:
                if not line.lstrip().startswith("#"):
                    word = normalize(line.split("\t", 1)[0])
                    if word in wanted:
                        found.add(word)
        return metadata.get("import_tables", [])

    # librime imports only the direct tables of each selected dictionary.
    for name in dictionaries:
        for table in scan(name):
            if table not in skip:
                scan(table)
    return found


def personal_words(personal_export):
    words = set()
    if personal_export:
        for line in personal_export.read_text(encoding="utf-8-sig").splitlines():
            if line and not line.startswith("#"):
                columns = line.split("\t")
                if len(columns) < 3:
                    raise ValueError("个人词库导出必须包含编码、词条及权重列")
                words.add(normalize(columns[1]))
    return words


def supplemental_table(pack, data, entries, stock, personal, seen):
    key, source_id, title = pack
    sha = hashlib.sha256(data).hexdigest()
    stats = dict(source_id=source_id, sha256=sha, raw=len(entries),
                 stock=0, personal=0, duplicate=0, invalid=0, added=0)
    rows = []
    for word, code in entries:
        if (not word or word.startswith("#") or any(ord(letter) < 32 for letter in word)
                or not all(re.fullmatch(r"[a-z]+|[A-Z]", syllable) for syllable in code.split(" "))):
            stats["invalid"] += 1
        elif word in seen:
            origin = "stock" if word in stock else "personal" if word in personal else "duplicate"
            stats[origin] += 1
        else:
            seen.add(word)
            rows.append(f"{word}\t{code}\t1\n")
    stats["added"] = len(rows)
    name = f"sogou_{key}"
    content = (
        f"# {title}\n# https://pinyin.sogou.com/dict/detail/index/{source_id}\n"
        f"# SCEL SHA-256 {sha}\n"
        + export_dictionary(dict(name=name, version=sha[:12], sort="by_weight",
                                 use_preset_vocabulary=False), "".join(rows))
    )
    return content, stats


def prepare(rime, sources, personal_export):
    main_dict = rime / f"{FROST}.dict.yaml"
    with main_dict.open(encoding="utf-8-sig") as stream:
        original = read_header(stream, main_dict)
        body = stream.read()
    if original.get("name") != FROST:
        raise ValueError("目标目录未使用白霜主词库")
    imports = original.get("import_tables", [])
    if not isinstance(imports, list):
        raise ValueError("白霜词库的 import_tables 应为列表")
    source_data = {}
    for key, _, title in PACKS:
        data = sources[key].read_bytes()
        source_data[key] = data, read_scel(data, title)
    wanted = {word for _, entries in source_data.values() for word, _ in entries}
    dictionaries = [FROST]
    if (rime / "melt_eng.dict.yaml").is_file():
        dictionaries.append("melt_eng")
    stock = existing_words(rime, dictionaries, wanted)
    personal = personal_words(personal_export)

    seen = stock | personal
    files = {}
    pack_report = {}
    extra_tables = []
    for pack in PACKS:
        key, _, title = pack
        data, entries = source_data[key]
        content, stats = supplemental_table(pack, data, entries, stock, personal, seen)
        pack_report[title] = stats
        name = f"sogou_{key}"
        if stats["added"]:
            extra_tables.append(name)
            files[f"{name}.dict.yaml"] = content

    patch_file = rime / f"{FROST}.custom.yaml"
    current = yaml.safe_load(patch_file.read_text(encoding="utf-8-sig")) if patch_file.is_file() else {}
    current = current or {}
    patch = current.setdefault("patch", {})
    if not isinstance(patch, dict):
        raise ValueError("白霜个人配置的 patch 应为映射")
    compiled = rime / "build" / f"{FROST}.schema.yaml"
    reference = compiled if compiled.is_file() else rime / f"{FROST}.schema.yaml"
    translator = yaml.safe_load(reference.read_text(encoding="utf-8-sig")).get("translator", {})
    dictionary = patch.get("translator/dictionary", translator.get("dictionary", FROST))
    if dictionary not in {FROST, MERGED}:
        raise ValueError(f"当前主词库是 {dictionary}，需要先核对自定义配置")
    user_dict = patch.get("translator/user_dict", translator.get("user_dict", FROST))
    if not isinstance(user_dict, str) or not user_dict:
        raise ValueError("当前个人词库绑定无效")
    patch.update({"translator/dictionary": MERGED, "translator/user_dict": user_dict})
    files[patch_file.name] = yaml.safe_dump(current, sort_keys=False, allow_unicode=True)
    # Rime 1.10 reads direct imports. Keep the main table's body and its full import list.
    merged = {**original, "name": MERGED, "import_tables": [*imports, *extra_tables]}
    files[f"{MERGED}.dict.yaml"] = export_dictionary(merged, body)
    report = {"packs": pack_report, "imports": extra_tables, "user_dict": user_dict}
    return files, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rime-dir", type=Path, required=True)
    parser.add_argument("--hotwords", type=Path, required=True)
    parser.add_argument("--developer", type=Path, required=True)
    parser.add_argument("--personal-export", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    rime = args.rime_dir.expanduser().resolve()
    out = args.output.expanduser().resolve()
    if out.is_relative_to(rime) or out.exists():
        parser.error("输出必须是 RIME 用户目录以外尚不存在的目录")
    try:
        files, report = prepare(rime, {"hotwords": args.hotwords, "developer": args.developer},
                                args.personal_export)
        out.mkdir(mode=0o700)
        for name, content in files.items():
            (out / name).write_text(content, encoding="utf-8")
        summary = json.dumps(report, ensure_ascii=False, indent=2)
        (out / "report.json").write_text(summary + "\n", encoding="utf-8")
    except (OSError, ValueError, struct.error, yaml.YAMLError) as e:
        parser.exit(1, f"{e}\n")
    print(summary)


if __name__ == "__main__":
    main()
