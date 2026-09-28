"""Human-readable HTML report for the two-model disk cleanup flow."""

from html import escape


def _bytes(value):
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{value} B"


def render_cleanup_report(plan):
    summary = plan["summary"]
    risk_counts = summary["risk_counts"]
    rows = []
    for entry in plan["entries"]:
        rows.append(
            "<tr>"
            f"<td><code>{escape(entry['id'])}</code></td>"
            f"<td><code>{escape(entry['path'])}</code></td>"
            f"<td>{escape(entry['kind'])}</td>"
            f"<td>{_bytes(entry['size_bytes'])}</td>"
            f"<td>{entry['age_days']}</td>"
            f"<td>{entry['jev_probability']:.3f}</td>"
            f"<td>{escape(entry['llm_recommendation'])}</td>"
            f"<td>{escape(entry['risk_level'])} / {entry['risk_score'] if entry['risk_score'] is not None else '-'}</td>"
            f"<td>{escape(entry['llm_reason'])}</td>"
            "</tr>"
        )
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>磁盘清理报告 {escape(plan['plan_id'])}</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 2rem; color: #17202a; }}
main {{ max-width: 1200px; margin: 0 auto; }}
table {{ border-collapse: collapse; width: 100%; margin-top: 1rem; }}
th, td {{ border: 1px solid #cbd2d9; padding: 0.5rem; text-align: left; vertical-align: top; }}
th {{ background: #eef2f5; }}
code {{ overflow-wrap: anywhere; }}
.warning {{ background: #fff4e5; border-left: 4px solid #d97708; padding: 1rem; }}
.muted {{ color: #52606d; }}
</style>
</head>
<body>
<main>
<h1>磁盘清理报告</h1>
<p>计划编号：<code>{escape(plan['plan_id'])}</code>　生成时间：{escape(plan['created_at'])}</p>
<p>候选 {summary['candidate_count']} 项；第二个 LLM 复核 {summary['reviewed_count']} 项；建议删除
{summary['delete_recommendation_count']} 项 / {_bytes(summary['recommended_delete_bytes'])}。</p>
<p>风险分布：低 {risk_counts['low']} 项，中 {risk_counts['medium']} 项，高 {risk_counts['high']} 项，未评估 {risk_counts['not_assessed']} 项。</p>
<div class="warning">
<strong>本报告不会自动删除任何文件。</strong>如需删除，请逐项核对路径和风险，再在命令中重复填写需要删除的条目 ID。
<br>命令格式：<code>./ubuntu-setup cleanup --delete --state-dir &lt;state-dir&gt; --plan-file &lt;plan-path&gt; --confirm &lt;plan-id&gt; --select &lt;entry-id&gt;</code>
</div>
<table>
<thead><tr><th>ID</th><th>路径</th><th>类型</th><th>大小</th><th>年龄（天）</th><th>JEV 概率</th><th>LLM 建议</th><th>风险</th><th>理由</th></tr></thead>
<tbody>{''.join(rows)}</tbody>
</table>
<p class="muted">两轮模型只依据路径名称、来源类型、大小和修改年龄判断，不读取文件内容；模型结论不构成删除授权。执行前会复核文件指纹，变化则跳过。</p>
</main>
</body>
</html>
"""


def write_cleanup_report(store, plan):
    relative_path = f"reports/{plan['plan_id']}.html"
    store.write(relative_path, render_cleanup_report(plan), text=True)
    return store.root / relative_path
