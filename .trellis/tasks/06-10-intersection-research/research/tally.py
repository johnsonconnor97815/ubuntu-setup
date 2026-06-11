#!/usr/bin/env python3
"""多源交集计票——方案 A（见父任务 research/authoritative-sources.md）。

规则：
- 核心源（各 1 票）：so-survey、homebrew、flathub、curation、pkgstats
- 辅助源（合计至多补 1 票）：jetbrains、popcon、awesome
- 入选：总票 ≥3 且核心票 ≥2

输入：research/sources/<key>.json（采集 agent 落盘的快照）
输出：research/tally.json（机器可读全量计票）、research/tally.md（人读榜单）

可重跑：纯函数式读入→计票→写出，无网络、无随机。
"""

from __future__ import annotations

import json
import unicodedata
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCES_DIR = HERE / "sources"

CORE_SOURCES = ["so-survey", "homebrew", "flathub", "curation", "pkgstats"]
AUX_SOURCES = ["jetbrains", "popcon", "awesome"]
MIN_TOTAL_VOTES = 3
MIN_CORE_VOTES = 2


def norm(name: str) -> str:
    """归一化工具名做合并键：小写、NFKC、空格/下划线/点转连字符。"""
    s = unicodedata.normalize("NFKC", name).strip().lower()
    for ch in (" ", "_", "."):
        s = s.replace(ch, "-")
    return s.strip("-")


class Union:
    """并查集：canonical 与 aliases 同组合并。"""

    def __init__(self) -> None:
        self.parent: dict[str, str] = {}

    def find(self, x: str) -> str:
        self.parent.setdefault(x, x)
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def join(self, a: str, b: str) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[rb] = ra


def load_sources() -> dict[str, dict]:
    snapshots: dict[str, dict] = {}
    for path in sorted(SOURCES_DIR.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        key = data.get("source_key") or path.stem
        snapshots[key] = data
    return snapshots


def tally(snapshots: dict[str, dict]) -> dict:
    uf = Union()
    # 第一遍：登记所有名字并按 alias 合并
    for data in snapshots.values():
        for tool in data.get("tools", []):
            canon = norm(tool["canonical"])
            uf.find(canon)
            for alias in [tool.get("raw_name", "")] + list(tool.get("aliases", [])):
                if alias:
                    uf.join(canon, norm(alias))

    # 第二遍：按组聚合各源命中
    groups: dict[str, dict] = defaultdict(
        lambda: {"names": set(), "hits": {}}  # hits: source_key -> tool 记录
    )
    for skey, data in snapshots.items():
        for tool in data.get("tools", []):
            root = uf.find(norm(tool["canonical"]))
            g = groups[root]
            g["names"].add(tool["canonical"])
            # 同源多条命中同组时保留 metric 最大的一条
            prev = g["hits"].get(skey)
            if prev is None or (tool.get("metric") or 0) > (prev.get("metric") or 0):
                g["hits"][skey] = tool

    results = []
    for root, g in groups.items():
        core_hits = [s for s in CORE_SOURCES if s in g["hits"]]
        aux_hits = [s for s in AUX_SOURCES if s in g["hits"]]
        core_votes = len(core_hits)
        aux_vote = 1 if aux_hits else 0  # 辅助源合计至多 1 票
        total = core_votes + aux_vote
        selected = total >= MIN_TOTAL_VOTES and core_votes >= MIN_CORE_VOTES
        results.append(
            {
                "key": root,
                "names": sorted(g["names"]),
                "core_votes": core_votes,
                "core_hits": core_hits,
                "aux_hits": aux_hits,
                "total_votes": total,
                "selected": selected,
                "evidence": {
                    s: {
                        "raw_name": t.get("raw_name"),
                        "metric": t.get("metric"),
                        "metric_unit": t.get("metric_unit"),
                        "evidence": t.get("evidence"),
                        "source_url": t.get("source_url"),
                    }
                    for s, t in sorted(g["hits"].items())
                },
            }
        )

    results.sort(key=lambda r: (-r["total_votes"], -r["core_votes"], r["key"]))
    return {
        "rule": {
            "core_sources": CORE_SOURCES,
            "aux_sources": AUX_SOURCES,
            "min_total_votes": MIN_TOTAL_VOTES,
            "min_core_votes": MIN_CORE_VOTES,
            "aux_cap": 1,
        },
        "sources_loaded": sorted(snapshots.keys()),
        "results": results,
    }


def render_md(report: dict) -> str:
    sel = [r for r in report["results"] if r["selected"]]
    near = [
        r
        for r in report["results"]
        if not r["selected"] and r["total_votes"] == MIN_TOTAL_VOTES - 1
    ]
    lines = [
        "# 多源交集计票结果（方案 A）",
        "",
        f"- 已加载源：{', '.join(report['sources_loaded'])}",
        f"- 规则：总票 ≥{MIN_TOTAL_VOTES} 且核心票 ≥{MIN_CORE_VOTES}；辅助源合计至多 1 票",
        f"- 入选：**{len(sel)} 条**；差一票观察区：{len(near)} 条",
        "",
        "## 入选清单",
        "",
        "| # | 工具 | 核心票 | 总票 | 命中源 |",
        "|---|------|--------|------|--------|",
    ]
    for i, r in enumerate(sel, 1):
        hits = ", ".join(r["core_hits"] + [f"({s})" for s in r["aux_hits"]])
        lines.append(
            f"| {i} | {r['key']} | {r['core_votes']} | {r['total_votes']} | {hits} |"
        )
    lines += [
        "",
        "## 差一票观察区（兜底规则候选：依赖引证票 / bedrock 白名单）",
        "",
        "| 工具 | 核心票 | 总票 | 命中源 |",
        "|------|--------|------|--------|",
    ]
    for r in near:
        hits = ", ".join(r["core_hits"] + [f"({s})" for s in r["aux_hits"]])
        lines.append(f"| {r['key']} | {r['core_votes']} | {r['total_votes']} | {hits} |")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    snapshots = load_sources()
    missing = [s for s in CORE_SOURCES + AUX_SOURCES if s not in snapshots]
    if missing:
        print(f"警告：缺源 {missing}（计票照常，但需在结论中记录）")
    report = tally(snapshots)
    (HERE / "tally.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (HERE / "tally.md").write_text(render_md(report), encoding="utf-8")
    sel = sum(1 for r in report["results"] if r["selected"])
    print(f"计票完成：{len(report['results'])} 组，入选 {sel} 条")
    print(f"输出：{HERE / 'tally.json'}、{HERE / 'tally.md'}")


if __name__ == "__main__":
    main()
