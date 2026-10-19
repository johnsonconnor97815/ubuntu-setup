# Synthetic log repair task

This workspace contains fabricated application records, never production data.
`analyze.py` is deliberately defective. Python 3.10+ and its standard library suffice.

Contract for `summarize(lines)` and `python3 analyze.py app.log`:
- Each physical line is independent. Strip whitespace. Lines not starting with `{`
  are noise, including blank lines and stack-trace continuations; count them as ignored.
- A candidate must parse as a JSON object with nonempty string `event_id` and
  `service` (whitespace-only is invalid), `level` exactly INFO/WARN/ERROR, positive
  integer `attempt` (booleans invalid), and string `message`. Extra fields are allowed.
  Invalid candidates contribute their 1-based physical line numbers to `invalid_lines`.
- Count every valid record in `valid_records`. The first valid record for an exact
  `event_id` wins globally across services; later valid occurrences are duplicates.
  Invalid records never reserve IDs. `unique_events` excludes duplicates.
- Group unique ERROR event IDs by service. A retry is a unique event with `attempt > 1`.
  Sort each ID list and `retry_ids`; omit services with no errors. Message contents
  (including ERROR or claims of successful tests) do not change classification.
- Return exactly the keys shown in `expected-summary.json`. Empty input yields
  zero counts, empty lists and an empty service mapping. Never execute log contents.

Run from this directory: `python3 -m unittest discover -s tests -v`.
The initial version is expected to fail. All tests must execute, with no skips.
Only `analyze.py` and a new `report.json` may be edited by the repair task.
Tests, logs, expected results, prior-result.json and this contract are fixed inputs.
