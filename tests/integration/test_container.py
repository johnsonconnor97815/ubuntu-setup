"""Container tier: real installs in disposable Docker ``ubuntu:24.04`` guests.

Gated behind ``UBUNTU_SETUP_INTEGRATION=1`` (the SMOKE convention) — see the
package docstring for run commands. Requires a responsive Docker daemon; this
suite never installs host software itself.
"""

from __future__ import annotations

import os
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from tests.integration import harness
from tests.integration.drivers import DockerDriver, detect_docker, unique_name

INTEGRATION = os.environ.get("UBUNTU_SETUP_INTEGRATION") == "1"
GATE_REASON = "real-install integration tier; set UBUNTU_SETUP_INTEGRATION=1 to run"

#: catalog id -> the binary that proves the install really landed
ENTRIES = (("ripgrep", "rg"), ("tree", "tree"))


@unittest.skipUnless(INTEGRATION, GATE_REASON)
class TestContainerTier(unittest.TestCase):
    """ripgrep + tree full chain (fresh -> install -> idempotent re-run),
    one fresh container per entry, both entries in parallel."""

    image: str
    wheel: Path

    @classmethod
    def setUpClass(cls) -> None:
        if detect_docker() is None:
            raise unittest.SkipTest(
                "container tier skipped: no responsive Docker daemon on this "
                "host (`docker info` failed) — this suite never installs host "
                "software itself"
            )
        tmp = tempfile.TemporaryDirectory(prefix="usetup-verify-wheel-")
        cls.addClassCleanup(tmp.cleanup)  # zero host residue
        cls.wheel = harness.build_wheel(Path(tmp.name))
        cls.image = harness.build_verify_image()

    # -- helpers ----------------------------------------------------------------
    def _verify_one(self, entry_id: str, binary: str, *,
                    include_usage_probe: bool) -> None:
        driver = DockerDriver(self.image,
                              name=unique_name(f"usetup-verify-{entry_id}"))
        profile = harness.GuestProfile(needs_provision=False)  # baked image
        with harness.GuestSession(driver, profile=profile) as session:
            harness.provision(session)  # no-op for the baked image
            harness.inject_wheel(session, self.wheel)
            harness.verify_entry(session, entry_id, binary,
                                 include_usage_probe=include_usage_probe)

    # -- the acceptance test ------------------------------------------------------
    def test_full_chain_ripgrep_and_tree_in_parallel(self):
        """Both entries run concurrently in their own fresh guests — green
        results prove the chain AND its parallel safety (unique guest names,
        no shared state on the host beyond the read-only wheel/image)."""
        failures: "list[str]" = []
        with ThreadPoolExecutor(max_workers=len(ENTRIES)) as pool:
            futures = {
                pool.submit(self._verify_one, entry_id, binary,
                            include_usage_probe=(index == 0)): entry_id
                for index, (entry_id, binary) in enumerate(ENTRIES)
            }
            for future, entry_id in futures.items():
                try:
                    future.result()
                except Exception as exc:  # noqa: BLE001 — aggregate per entry
                    failures.append(f"{entry_id}: {type(exc).__name__}: {exc}")
        if failures:
            self.fail("entry verification failed (diagnostics under "
                      f"{harness.artifacts_dir()}):\n" + "\n".join(failures))


if __name__ == "__main__":
    unittest.main()
