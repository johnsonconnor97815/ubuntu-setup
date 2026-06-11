#!/usr/bin/env python3
"""组装定稿清单：tally.json（计票）× annotations.json（标注）→ final-list.{json,md}。

可重跑：纯读入→合成→写出。统计 provider 分布（驱动 provider-* 子任务开题）、
类别分布（类别空洞复查素材）、可验性分布（验证基建分流）。
"""

from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main() -> None:
    tally = json.loads((HERE / "tally.json").read_text(encoding="utf-8"))
    ann_raw = json.loads((HERE / "annotations.json").read_text(encoding="utf-8"))
    ann = {e["key"]: e for batch in ann_raw["batches"] for e in batch["entries"]}

    selected = [r for r in tally["results"] if r["selected"]]
    rows, missing_ann = [], []
    for r in selected:
        a = ann.get(r["key"])
        if a is None:
            missing_ann.append(r["key"])
            continue
        rows.append(
            {
                "key": r["key"],
                "display_name": a.get("display_name", r["key"]),
                "category": a["category"],
                "votes": {
                    "core": r["core_votes"],
                    "total": r["total_votes"],
                    "core_hits": r["core_hits"],
                    "aux_hits": r["aux_hits"],
                },
                "evidence": r["evidence"],
                "gui": a["gui"],
                "requires": a.get("requires", []),
                "official_method": a["official_method"],
                "official_doc_url": a["official_doc_url"],
                "official_cmd": a.get("official_cmd", ""),
                "ubuntu_apt_package": a.get("ubuntu_apt_package"),
                "ubuntu_apt_note": a.get("ubuntu_apt_note", ""),
                "provider_type": a["provider_type"],
                "provider_rationale": a.get("provider_rationale", ""),
                "prerequisites": a.get("prerequisites", []),
                "testability": a["testability"],
                "testability_reason": a.get("testability_reason", ""),
                "notes": a.get("notes", ""),
            }
        )

    rows.sort(key=lambda x: (x["category"], -x["votes"]["total"], x["key"]))

    providers = Counter(x["provider_type"] for x in rows)
    categories = Counter(x["category"] for x in rows)
    testability = Counter(x["testability"] for x in rows)
    prereq_votes = Counter(p for x in rows for p in set(x["prerequisites"]))

    out = {
        "generated_from": ["tally.json", "annotations.json"],
        "count": len(rows),
        "missing_annotations": missing_ann,
        "provider_distribution": dict(providers.most_common()),
        "category_distribution": dict(categories.most_common()),
        "testability_distribution": dict(testability.most_common()),
        "prerequisite_citations": dict(prereq_votes.most_common()),
        "entries": rows,
    }
    (HERE / "final-list.json").write_text(
        json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    by_cat = defaultdict(list)
    for x in rows:
        by_cat[x["category"]].append(x)

    lines = [
        "# 首发清单定稿（计票 × 标注）",
        "",
        f"- 条目：**{len(rows)}**" + (f"；缺标注：{missing_ann}" if missing_ann else ""),
        f"- provider 分布：{dict(providers.most_common())}",
        f"- 可验性：{dict(testability.most_common())}",
        f"- 依赖引证票（被 ≥2 条官方步骤要求即自动入选资格）：{ {k: v for k, v in prereq_votes.most_common() if v >= 2} }",
        "",
    ]
    for cat in sorted(by_cat):
        lines += [
            f"## {cat}（{len(by_cat[cat])}）",
            "",
            "| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |",
            "|------|----|---------|----------|----------|------|------|",
        ]
        for x in by_cat[cat]:
            req = ",".join(x["requires"]) or "-"
            note = (x["ubuntu_apt_note"] or x["notes"] or "").replace("|", "/")[:60]
            lines.append(
                f"| {x['key']} | {x['votes']['core']}+{x['votes']['total'] - x['votes']['core']} "
                f"| [{x['official_method']}]({x['official_doc_url']}) | {x['provider_type']} "
                f"| {req} | {x['testability']} | {note} |"
            )
        lines.append("")
    (HERE / "final-list.md").write_text("\n".join(lines), encoding="utf-8")

    print(f"组装完成：{len(rows)} 条（缺标注 {len(missing_ann)}）")
    print(f"provider 分布：{dict(providers.most_common())}")
    print(f"类别分布：{dict(categories.most_common())}")
    print(f"可验性：{dict(testability.most_common())}")
    top_prereq = {k: v for k, v in prereq_votes.most_common() if v >= 2}
    print(f"依赖引证 ≥2 票：{top_prereq}")


if __name__ == "__main__":
    main()
