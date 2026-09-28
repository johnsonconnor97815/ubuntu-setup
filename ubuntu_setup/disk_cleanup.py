"""Two-model disk cleanup reports with explicit user selection."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import stat
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from .model import DataError, new_id
from .state import StateStore
from .cleanup_report import write_cleanup_report


PLAN_SCHEMA_VERSION = 3
DEFAULT_BASE_URL = "https://cf.api.fan/v1"
DEFAULT_MODEL = "jev-latest"
DEFAULT_REVIEW_BASE_URL = "http://127.0.0.1:11434/v1"
DEFAULT_REVIEW_MODEL = "qwen3.8:27b"
DEFAULT_THRESHOLD = 0.8
MAX_CANDIDATES = 200


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def default_state_dir():
    configured = os.environ.get("XDG_STATE_HOME")
    if configured and not Path(configured).is_absolute():
        raise DataError("XDG_STATE_HOME 必须是绝对路径")
    root = Path(configured) if configured else Path.home() / ".local/state"
    return root / "ubuntu-setup/cleanup"


def resolve_cleanup_root(path, kind):
    root = Path(path).expanduser().resolve(strict=True)
    if not root.is_dir():
        raise DataError(f"清理根目录不是目录：{root}")
    return root, kind


def default_roots():
    cache_configured = os.environ.get("XDG_CACHE_HOME")
    data_configured = os.environ.get("XDG_DATA_HOME")
    for configured in (cache_configured, data_configured):
        if configured and not Path(configured).is_absolute():
            raise DataError("XDG_CACHE_HOME 和 XDG_DATA_HOME 必须是绝对路径")
    cache_root = Path(cache_configured).expanduser() if cache_configured else Path.home() / ".cache"
    data_root = Path(data_configured).expanduser() if data_configured else Path.home() / ".local/share"
    return [
        (cache_root.expanduser(), "cache"),
        (Path("/tmp"), "temporary"),
        (data_root.expanduser() / "Trash/files", "trash"),
    ]


def _entry_stats(path, metadata):
    if not stat.S_ISDIR(metadata.st_mode):
        return metadata.st_size, metadata.st_mtime_ns
    total = 0
    newest_mtime_ns = metadata.st_mtime_ns
    for current, directories, files in os.walk(path, followlinks=False):
        for name in files:
            try:
                item = os.lstat(Path(current) / name)
            except OSError:
                continue
            if stat.S_ISREG(item.st_mode):
                total += item.st_size
                newest_mtime_ns = max(newest_mtime_ns, item.st_mtime_ns)
        kept_directories = []
        for name in directories:
            child = Path(current) / name
            if os.path.islink(child):
                continue
            kept_directories.append(name)
            try:
                newest_mtime_ns = max(newest_mtime_ns, child.lstat().st_mtime_ns)
            except OSError:
                continue
        directories[:] = kept_directories
    return total, newest_mtime_ns


def scan_roots(roots, *, min_age_days, max_candidates):
    if min_age_days < 0:
        raise DataError("--min-age-days 不能小于 0")
    if not 1 <= max_candidates <= MAX_CANDIDATES:
        raise DataError(f"--max-candidates 必须在 1 到 {MAX_CANDIDATES} 之间")
    cutoff = time.time() - min_age_days * 86400
    entries = []
    seen = set()
    skipped = []
    for root, root_kind in roots:
        if not root.exists():
            skipped.append({"path": str(root), "kind": root_kind, "reason": "not_found"})
            continue
        try:
            children = list(root.iterdir())
        except OSError:
            skipped.append({"path": str(root), "kind": root_kind, "reason": "unreadable"})
            continue
        for child in children:
            try:
                metadata = child.lstat()
            except OSError:
                continue
            mode = metadata.st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                continue
            if root_kind == "temporary" and metadata.st_uid != os.geteuid():
                continue
            try:
                resolved = str(child.resolve(strict=True))
            except OSError:
                continue
            if resolved in seen:
                continue
            size_bytes, newest_mtime_ns = _entry_stats(child, metadata)
            if newest_mtime_ns / 1_000_000_000 > cutoff:
                continue
            seen.add(resolved)
            entries.append({
                "id": new_id(),
                "path": str(child),
                "relative_path": child.name,
                "root_path": str(root),
                "root_kind": root_kind,
                "kind": "directory" if stat.S_ISDIR(mode) else "file",
                "size_bytes": size_bytes,
                "mtime_ns": metadata.st_mtime_ns,
                "newest_mtime_ns": newest_mtime_ns,
                "device": metadata.st_dev,
                "inode": metadata.st_ino,
                "mode": metadata.st_mode,
                "age_days": round(max(0.0, (time.time() - newest_mtime_ns / 1_000_000_000) / 86400), 3),
            })
    entries.sort(key=lambda item: (-item["size_bytes"], item["path"]))
    truncated = len(entries) > max_candidates
    return entries[:max_candidates], skipped, truncated


class JevClient:
    def __init__(self, *, api_key, base_url=DEFAULT_BASE_URL, model=DEFAULT_MODEL,
                 threshold=DEFAULT_THRESHOLD, timeout=30.0):
        if not api_key or not isinstance(api_key, str):
            raise DataError("缺少 PACKY_API_KEY；请在环境中提供 PackyApi 令牌")
        api_key = api_key.strip()
        if not api_key:
            raise DataError("缺少 PACKY_API_KEY；请在环境中提供 PackyApi 令牌")
        parsed = urllib.parse.urlparse(base_url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
            raise DataError("PackyApi 地址必须是 https URL，且不能包含 query 或 fragment")
        if not 0.0 < threshold < 1.0:
            raise DataError("--threshold 必须大于 0 且小于 1")
        if not 1.0 <= timeout <= 120.0:
            raise DataError("--timeout 必须在 1 到 120 秒之间")
        if not isinstance(model, str) or not model.strip():
            raise DataError("JEV 模型名不能为空")
        self.api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.model = model.strip()
        self.threshold = threshold
        self.timeout = timeout

    def endpoint(self):
        return f"{self.base_url}/systemone"

    def request(self, entry):
        payload = {
            "model": self.model,
            "state": {
                "task": "Review an Ubuntu disk cleanup candidate before permanent deletion.",
                "policy": "Delete only when the path and metadata clearly identify an inactive cache, temporary, or trash entry that is not user data and is not needed by a running application.",
                "entry": {
                    "root_kind": entry["root_kind"],
                    "relative_path": entry["relative_path"],
                    "kind": entry["kind"],
                    "size_bytes": entry["size_bytes"],
                    "age_days": entry["age_days"],
                },
            },
            "questions": {
                "deletable": {
                    "type": "noul",
                    "instructions": "This entry can be permanently deleted without breaking an active application or destroying data the user may need.",
                }
            },
        }
        request = urllib.request.Request(
            self.endpoint(),
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                body = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise DataError(f"PackyApi JEV 请求失败：HTTP {exc.code}") from exc
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            raise DataError("PackyApi JEV 请求失败：无法访问响应或响应不是 JSON") from exc
        answer = body.get("answers", {}).get("deletable", {})
        probability = answer.get("noul")
        if not isinstance(probability, (int, float)) or isinstance(probability, bool) or not 0.0 <= probability <= 1.0:
            raise DataError("PackyApi JEV 响应缺少有效的 deletable.noul 概率")
        return {
            "decision": "delete" if probability >= self.threshold else "keep",
            "jev_probability": probability,
            "jev_model": body.get("model", self.model),
        }

    def classify(self, entries):
        if not entries:
            return []
        payload = {
            "model": self.model,
            "state": {
                "task": "Review Ubuntu disk cleanup candidates before permanent deletion.",
                "policy": "Delete only when the path and metadata clearly identify an inactive cache, temporary, or trash entry that is not user data and is not needed by a running application.",
                "entries": [
                    {
                        "id": entry["id"],
                        "root_kind": entry["root_kind"],
                        "relative_path": entry["relative_path"],
                        "kind": entry["kind"],
                        "size_bytes": entry["size_bytes"],
                        "age_days": entry["age_days"],
                    }
                    for entry in entries
                ],
            },
            "questions": {
                f"deletable_{entry['id']}": {
                    "type": "noul",
                    "instructions": "This entry can be permanently deleted without breaking an active application or destroying data the user may need.",
                }
                for entry in entries
            },
        }
        request = urllib.request.Request(
            self.endpoint(),
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                body = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise DataError(f"PackyApi JEV 请求失败：HTTP {exc.code}") from exc
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            raise DataError("PackyApi JEV 请求失败：无法访问响应或响应不是 JSON") from exc
        answers = body.get("answers", {})
        results = []
        for entry in entries:
            answer = answers.get(f"deletable_{entry['id']}", {})
            probability = answer.get("noul")
            if not isinstance(probability, (int, float)) or isinstance(probability, bool) or not 0.0 <= probability <= 1.0:
                raise DataError("PackyApi JEV 响应缺少有效的 deletable.noul 概率")
            results.append({
                **entry,
                "jev_decision": "delete" if probability >= self.threshold else "keep",
                "jev_probability": probability,
                "jev_model": body.get("model", self.model),
            })
        return results


class LLMReviewClient:
    def __init__(self, *, base_url=DEFAULT_REVIEW_BASE_URL, model=DEFAULT_REVIEW_MODEL,
                 timeout=120.0, batch_size=10):
        parsed = urllib.parse.urlparse(base_url)
        local_http = parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}
        if ((parsed.scheme != "https" and not local_http) or not parsed.netloc or
                parsed.query or parsed.fragment):
            raise DataError("复核 LLM 地址必须是 https URL；本机可使用 localhost 的 http 地址")
        if not 1.0 <= timeout <= 300.0:
            raise DataError("--review-timeout 必须在 1 到 300 秒之间")
        if not isinstance(model, str) or not model.strip():
            raise DataError("复核 LLM 模型名不能为空")
        if not isinstance(batch_size, int) or isinstance(batch_size, bool) or not 1 <= batch_size <= 20:
            raise DataError("复核 LLM 批量大小必须在 1 到 20 之间")
        self.base_url = base_url.rstrip("/")
        self.model = model.strip()
        self.timeout = timeout
        self.batch_size = batch_size

    def review(self, entries):
        if not entries:
            return []
        output = []
        for start in range(0, len(entries), self.batch_size):
            batch = entries[start:start + self.batch_size]
            output.extend(self._review_batch(batch))
        return output

    def _review_batch(self, entries):
        metadata = [
            {
                "id": entry["id"],
                "root_kind": entry["root_kind"],
                "relative_path": entry["relative_path"],
                "kind": entry["kind"],
                "size_bytes": entry["size_bytes"],
                "age_days": entry["age_days"],
            }
            for entry in entries
        ]
        payload = {
            "model": self.model,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "You review Ubuntu disk cleanup candidates. Return exactly "
                        '{"results":[{"id":"","recommendation":"","risk_level":"","risk_score":0,"reason":""}]}. '
                        'recommendation must be "delete", "review", or "keep". '
                        "risk_level (\"low\", \"medium\", or \"high\"), risk_score (integer 0-100), "
                        "and a short reason in Chinese. Do not invent paths or read files."
                    ),
                },
                {
                    "role": "user",
                    "content": json.dumps({"candidates": metadata}, ensure_ascii=False),
                },
            ],
            "temperature": 0,
            "response_format": {"type": "json_object"},
        }
        request = urllib.request.Request(
            f"{self.base_url}/chat/completions",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                body = json.loads(response.read().decode("utf-8"))
            content = body["choices"][0]["message"]["content"]
            decoded = json.loads(content[content.find("{"):content.rfind("}") + 1])
        except urllib.error.HTTPError as exc:
            raise DataError(f"复核 LLM 请求失败：HTTP {exc.code}") from exc
        except (OSError, ValueError, KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
            raise DataError("复核 LLM 请求失败：无法访问响应或响应不是有效 JSON") from exc
        results = decoded.get("results")
        if not isinstance(results, list):
            raise DataError("复核 LLM 响应缺少 results 数组")
        by_id = {}
        for result in results:
            if not isinstance(result, dict):
                raise DataError("复核 LLM 响应条目格式错误")
            entry_id = result.get("id")
            if not isinstance(entry_id, str):
                raise DataError("复核 LLM 响应条目缺少有效 id")
            recommendation = result.get("recommendation")
            risk_level = result.get("risk_level")
            risk_score = result.get("risk_score")
            reason = result.get("reason")
            if recommendation not in {"delete", "review", "keep"}:
                raise DataError("复核 LLM 响应缺少有效 recommendation")
            if risk_level not in {"low", "medium", "high"}:
                raise DataError("复核 LLM 响应缺少有效 risk_level")
            if (isinstance(risk_score, bool) or not isinstance(risk_score, int) or
                    not 0 <= risk_score <= 100):
                raise DataError("复核 LLM 响应缺少有效 risk_score")
            if not isinstance(reason, str) or not reason.strip():
                raise DataError("复核 LLM 响应缺少有效 reason")
            by_id[entry_id] = {
                "llm_recommendation": recommendation,
                "risk_level": risk_level,
                "risk_score": risk_score,
                "llm_reason": reason.strip(),
                "llm_model": body.get("model", self.model),
            }
        batch_output = []
        for entry in entries:
            if entry["id"] not in by_id:
                raise DataError("复核 LLM 响应缺少候选条目")
            batch_output.append({**entry, **by_id[entry["id"]]})
        return batch_output


def create_plan(*, state_dir, roots, min_age_days, max_candidates, client, review_client):
    with StateStore(Path(state_dir).expanduser()) as store:
        entries, skipped, truncated = scan_roots(roots, min_age_days=min_age_days, max_candidates=max_candidates)
        judged_entries = client.classify(entries)
        jev_candidates = [entry for entry in judged_entries if entry["jev_decision"] == "delete"]
        reviewed_entries = review_client.review(jev_candidates)
        reviewed_by_id = {entry["id"]: entry for entry in reviewed_entries}
        final_entries = []
        for entry in judged_entries:
            if entry["jev_decision"] != "delete":
                final_entries.append({
                    **entry,
                    "llm_recommendation": "not_requested",
                    "risk_level": "not_assessed",
                    "risk_score": None,
                    "llm_reason": "JEV 初筛未通过，未交给第二个 LLM 复核",
                    "llm_model": "",
                })
                continue
            reviewed = reviewed_by_id.get(entry["id"])
            if reviewed is None:
                raise DataError("复核 LLM 结果缺少候选条目")
            final_entries.append({**entry, **reviewed})
        plan_id = uuid.uuid4().hex
        plan = {
            "schema_version": PLAN_SCHEMA_VERSION,
            "plan_id": plan_id,
            "created_at": _now(),
            "status": "planned",
            "policy": {
                "min_age_days": min_age_days,
                "threshold": client.threshold,
                "jev_rule": "JEV probability >= threshold sends the candidate to LLM review",
                "jev_network": "PackyApi JEV /v1/systemone",
                "review_network": "OpenAI-compatible /chat/completions",
                "review_model": review_client.model,
                "deletion_rule": "No automatic deletion; user must select entry IDs explicitly",
            },
            "roots": [{"path": str(path), "kind": kind} for path, kind in roots],
            "skipped_roots": skipped,
            "candidate_limit_reached": truncated,
            "entries": final_entries,
            "summary": {
                "candidate_count": len(final_entries),
                "reviewed_count": sum(item["llm_recommendation"] != "not_requested" for item in final_entries),
                "delete_recommendation_count": sum(item["llm_recommendation"] == "delete" for item in final_entries),
                "review_recommendation_count": sum(item["llm_recommendation"] == "review" for item in final_entries),
                "keep_recommendation_count": sum(item["llm_recommendation"] == "keep" for item in final_entries),
                "recommended_delete_bytes": sum(item["size_bytes"] for item in final_entries
                                                if item["llm_recommendation"] == "delete"),
                "risk_counts": {
                    "low": sum(item["risk_level"] == "low" for item in final_entries),
                    "medium": sum(item["risk_level"] == "medium" for item in final_entries),
                    "high": sum(item["risk_level"] == "high" for item in final_entries),
                    "not_assessed": sum(item["risk_level"] == "not_assessed" for item in final_entries),
                },
            },
        }
        relative_path = f"plans/{plan_id}.json"
        store.write(relative_path, plan)
        report_path = write_cleanup_report(store, plan)
        return {"plan_id": plan_id, "plan_path": str(store.root / relative_path),
                "report_path": str(report_path), "state_dir": str(store.root), **plan}


def _read_plan(plan_path):
    path = Path(plan_path).expanduser()
    if path.is_symlink():
        raise DataError("清理计划文件不能是符号链接")
    try:
        plan = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise DataError("清理计划文件不存在或不是有效 JSON") from exc
    if plan.get("schema_version") != PLAN_SCHEMA_VERSION:
        raise DataError("清理计划版本不支持")
    if plan.get("status") != "planned":
        raise DataError("清理计划状态不是 planned")
    if not isinstance(plan.get("entries"), list):
        raise DataError("清理计划缺少条目列表")
    if not isinstance(plan.get("plan_id"), str) or not plan["plan_id"]:
        raise DataError("清理计划缺少有效编号")
    for entry in plan["entries"]:
        if not isinstance(entry, dict):
            raise DataError("清理计划条目格式错误")
        required = ("id", "path", "kind", "size_bytes", "mtime_ns", "newest_mtime_ns", "device", "inode", "mode",
                    "jev_probability", "llm_recommendation", "risk_level", "risk_score", "llm_reason", "llm_model")
        if any(key not in entry for key in required):
            raise DataError("清理计划条目缺少执行复核字段")
        if not isinstance(entry["path"], str) or not Path(entry["path"]).is_absolute():
            raise DataError("清理计划条目路径必须是绝对路径")
        if entry["kind"] not in {"file", "directory"}:
            raise DataError("清理计划条目类型错误")
        if entry["llm_recommendation"] not in {"delete", "review", "keep", "not_requested"}:
            raise DataError("清理计划条目复核建议错误")
        if entry["risk_level"] not in {"low", "medium", "high", "not_assessed"}:
            raise DataError("清理计划条目风险等级错误")
        if entry["llm_recommendation"] == "not_requested":
            if entry["risk_score"] is not None:
                raise DataError("清理计划条目风险分数错误")
        elif (isinstance(entry["risk_score"], bool) or not isinstance(entry["risk_score"], int) or
              not 0 <= entry["risk_score"] <= 100):
            raise DataError("清理计划条目风险分数错误")
        if any(isinstance(entry[key], bool) or not isinstance(entry[key], int) or entry[key] < 0
               for key in ("size_bytes", "mtime_ns", "newest_mtime_ns", "device", "inode", "mode")):
            raise DataError("清理计划条目元数据类型错误")
    return path, plan


def _same_entry(path, entry):
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return False, "missing"
    except OSError:
        return False, "stat_failed"
    kind = "directory" if stat.S_ISDIR(metadata.st_mode) else "file" if stat.S_ISREG(metadata.st_mode) else "other"
    if kind != entry["kind"] or (kind == "file" and metadata.st_size != entry["size_bytes"]):
        return False, "changed"
    if (metadata.st_dev, metadata.st_ino, metadata.st_mtime_ns, metadata.st_mode) != (
            entry["device"], entry["inode"], entry["mtime_ns"], entry["mode"]):
        return False, "changed"
    size_bytes, newest_mtime_ns = _entry_stats(path, metadata)
    if size_bytes != entry["size_bytes"] or newest_mtime_ns != entry["newest_mtime_ns"]:
        return False, "changed"
    return True, "unchanged"


def execute_plan(*, state_dir, plan_path, confirm, selected_ids):
    selected = list(selected_ids)
    if not selected:
        raise DataError("执行清理必须至少指定一个 --select <entry-id>")
    if len(set(selected)) != len(selected):
        raise DataError("--select 不能重复指定同一个条目")
    with StateStore(Path(state_dir).expanduser()) as store:
        path, plan = _read_plan(plan_path)
        if confirm != plan.get("plan_id"):
            raise DataError("--confirm 必须精确匹配计划中的 plan_id")
        entries_by_id = {entry["id"]: entry for entry in plan["entries"]}
        selected_entries = []
        for entry_id in selected:
            if entry_id not in entries_by_id:
                raise DataError(f"--select 指定的条目不存在：{entry_id}")
            entry = entries_by_id[entry_id]
            if entry["llm_recommendation"] == "not_requested":
                raise DataError(f"JEV 初筛未通过的条目不能选择删除：{entry_id}")
            selected_entries.append(entry)
        execution_relative = f"executions/{plan['plan_id']}.json"
        if (store.root / execution_relative).exists():
            raise DataError("该清理计划已经执行过；请重新扫描生成新计划")
        results = []
        for entry in selected_entries:
            target = Path(entry["path"])
            unchanged, reason = _same_entry(target, entry)
            if not unchanged:
                results.append({**entry, "execution_status": reason})
                continue
            try:
                if entry["kind"] == "directory":
                    shutil.rmtree(target)
                else:
                    target.unlink()
            except OSError:
                results.append({**entry, "execution_status": "failed"})
                continue
            results.append({**entry, "execution_status": "deleted"})
        deleted = [item for item in results if item["execution_status"] == "deleted"]
        result = {
            "schema_version": 1,
            "execution_id": new_id(),
            "plan_id": plan["plan_id"],
            "executed_at": _now(),
            "status": "completed" if all(item["execution_status"] == "deleted" for item in results) else "partial",
            "results": results,
            "summary": {
                "selected_count": len(selected_entries),
                "selected_bytes": sum(item["size_bytes"] for item in selected_entries),
                "deleted_count": len(deleted),
                "deleted_bytes": sum(item["size_bytes"] for item in deleted),
                "skipped_count": len(results) - len(deleted),
            },
            "plan_path": str(path),
        }
        store.write(execution_relative, result)
        return result
