#!/usr/bin/env python3
"""Read local Codex tree telemetry without exposing conversation contents."""
import argparse
import json
from pathlib import Path
import sqlite3


FIELDS = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens",
          "output_tokens", "reasoning_output_tokens", "total_tokens")


def read_rollout(path):
    result = {"model": None, "effort": None, "models_seen": [], "usage": None,
              "usage_timestamp": None, "completed": None,
              "completion_timestamp": None, "errors": []}
    try:
        with Path(path).open(encoding="utf-8") as stream:
            for number, line in enumerate(stream, 1):
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    result["errors"].append(f"invalid JSON at line {number}")
                    continue
                if not isinstance(record, dict):
                    result["errors"].append(f"invalid record at line {number}")
                    continue
                payload = record.get("payload", {})
                if not isinstance(payload, dict):
                    result["errors"].append(f"invalid payload at line {number}")
                    continue
                kind = record.get("type")
                if kind == "turn_context":
                    result["model"] = payload.get("model")
                    result["effort"] = payload.get("effort", payload.get("reasoning_effort"))
                    model = result["model"]
                    if model and model not in result["models_seen"]:
                        result["models_seen"].append(model)
                usage = None
                if kind == "token_usage_record":
                    usage = payload.get("thread_token_usage")
                elif kind == "event_msg":
                    event = payload.get("type")
                    if event == "token_count":
                        info = payload.get("info")
                        if info is not None and not isinstance(info, dict):
                            result["errors"].append(f"invalid token info at line {number}")
                            continue
                        usage = (info or {}).get("total_token_usage")
                    elif event == "task_started":
                        result["completed"] = False
                        result["completion_timestamp"] = None
                    elif event == "task_complete":
                        result["completed"] = True
                        result["completion_timestamp"] = record.get("timestamp")
                if isinstance(usage, dict):
                    normalized = {
                        field: usage.get(field) if type(usage.get(field)) is int
                        and usage[field] >= 0 else None for field in FIELDS}
                    previous = result["usage"]
                    # Older event schemas omit cache-write usage. Retain richer
                    # data only when both records describe the same cumulative total.
                    if previous and normalized["total_tokens"] is not None and (
                        normalized["total_tokens"] == previous["total_tokens"]
                        and all(value is None or value == previous[field]
                                for field, value in normalized.items())
                    ):
                        normalized = {field: previous[field] if field not in usage else value
                                      for field, value in normalized.items()}
                    result["usage"] = normalized
                    result["usage_timestamp"] = record.get("timestamp")
    except (OSError, TypeError) as error:
        result["errors"].append(type(error).__name__)
    return result


def summed_usage(threads):
    complete = all(t["usage"] is not None and not t["errors"]
                   and all(t["usage"][f] is not None for f in FIELDS) for t in threads)
    return {"telemetry_complete": complete,
            "totals": {f: sum(t["usage"][f] for t in threads) for f in FIELDS}
            if complete else None}


def collect(root, state_db):
    database = Path(state_db).expanduser().resolve()
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
        connection.row_factory = sqlite3.Row
        pending = [(root, None, 0)]
        visited = set()
        threads = []
        while pending:
            thread_id, parent, depth = pending.pop(0)
            if thread_id in visited:
                continue
            visited.add(thread_id)
            row = connection.execute(
                "SELECT id, rollout_path, model, reasoning_effort FROM threads WHERE id=?",
                (thread_id,)).fetchone()
            data = read_rollout(row["rollout_path"]) if row else {
                "model": None, "effort": None, "models_seen": [], "usage": None,
                "usage_timestamp": None, "completed": None,
                "completion_timestamp": None, "errors": ["thread missing from database"]}
            data.update({"thread_id": thread_id, "parent_thread_id": parent, "depth": depth,
                         "rollout_path": row["rollout_path"] if row else None,
                         "database_model": row["model"] if row else None,
                         "database_effort": row["reasoning_effort"] if row else None})
            threads.append(data)
            children = connection.execute(
                "SELECT child_thread_id FROM thread_spawn_edges WHERE parent_thread_id=? "
                "ORDER BY child_thread_id", (thread_id,))
            pending.extend((child[0], thread_id, depth + 1) for child in children)
    groups = {}
    for thread in threads:
        # Cumulative usage cannot be allocated to one model after a model switch.
        model = thread["model"] if len(thread["models_seen"]) == 1 else "unknown"
        groups.setdefault(model, []).append(thread)
    return {"root_thread_id": root, "thread_count": len(threads), "threads": threads,
            **summed_usage(threads),
            "all_threads_completed": all(t["completed"] is True for t in threads),
            "model_allocation_complete": "unknown" not in groups,
            "by_model": {model: {"thread_count": len(items), **summed_usage(items)}
                         for model, items in groups.items()},
            "counting_notes": ["Each thread contributes its latest cumulative usage once.",
                               "Cached input is a subset of input; reasoning is a subset of output.",
                               "Completion comes from rollout task_complete, not SQLite status.",
                               "Tree membership is the current SQLite spawn-edge snapshot."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root_thread_uuid")
    parser.add_argument("--state-db", default="~/.codex/state_5.sqlite")
    args = parser.parse_args()
    try:
        result = collect(args.root_thread_uuid, args.state_db)
    except (OSError, sqlite3.Error) as error:
        print(json.dumps({"telemetry_complete": False, "error": type(error).__name__}))
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
