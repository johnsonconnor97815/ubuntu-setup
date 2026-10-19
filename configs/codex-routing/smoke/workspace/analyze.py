"""Synthetic log analyzer; intentionally defective acceptance starting point."""
import json
import sys
from pathlib import Path


def summarize(lines):
    records = []
    invalid = []
    ignored = 0
    for number, line in enumerate(lines, 1):
        if not line.strip().startswith("{"):
            ignored += 1
            continue
        try:
            records.append(json.loads(line))
        except ValueError:
            invalid.append(number)
    return {"valid_records": len(records), "unique_events": len(records),
            "duplicate_records": 0, "invalid_lines": invalid, "ignored_lines": ignored,
            "error_ids_by_service": {}, "retry_ids": []}


if __name__ == "__main__":
    print(json.dumps(summarize(Path(sys.argv[1]).read_text().splitlines()), sort_keys=True))
