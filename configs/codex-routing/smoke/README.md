# Synthetic acceptance fixture

`workspace/` is a disposable repair template. Copy it outside this checkout before
running a repair session; keep this deliberately buggy source unchanged. Feed
`task.txt` as the request. It contains a normal coding/log-analysis task without
explicit delegation instructions. The session uses whichever applicable policy
is installed in its target environment. This fixture does not run model calls.

`baseline.json` records a real local failing run: eight tests executed, six failed,
zero errors/skips. `workspace/expected-summary.json` defines the correct summary.
The wrong `prior-result.json` is synthetic test data for evidence-based rejection.
Passing these tests alone proves analyzer behavior, not that delegation occurred
or tokens were saved. A live session still needs its actual routing trace and
whole-tree input/cached-input/output usage to establish those separate claims.
