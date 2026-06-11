"""System tier: LXD/Incus system containers (the systemd/snap/flatpak class).

Gated behind ``UBUNTU_SETUP_INTEGRATION=1``; additionally skips — explicitly,
with the reason — when neither LXD's ``lxc`` nor ``incus`` responds on this
host. Unlocking is the user's call (e.g. ``snap install lxd`` or
``apt install incus``): **this suite never installs host software itself**
(prd hard rule; the dev machine having docker but no lxd is the expected
state).

Until snap/systemd entries exist, this tier exercises the same two apt
entries end-to-end — proving the LxdDriver chain (launch -> provision ->
wheel inject -> verify protocol) so the 15-entry batch only adds entries,
not infrastructure. The real-VM escape hatch is ``LxdDriver(..., vm=True)``;
per-entry config (e.g. ``security.nesting`` for the docker entry) goes
through the driver's ``config=``.
"""

from __future__ import annotations

import os
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from tests.integration import harness
from tests.integration.drivers import LxdDriver, detect_lxd, unique_name

INTEGRATION = os.environ.get("UBUNTU_SETUP_INTEGRATION") == "1"
GATE_REASON = "real-install integration tier; set UBUNTU_SETUP_INTEGRATION=1 to run"

#: image per CLI: lxd ships the `ubuntu:` remote; incus uses `images:` (the
#: /cloud variant has cloud-init, which creates the default `ubuntu` user)
IMAGES = {"lxc": "ubuntu:24.04", "incus": "images:ubuntu/24.04/cloud"}

ENTRIES = (("ripgrep", "rg"), ("tree", "tree"))


@unittest.skipUnless(INTEGRATION, GATE_REASON)
class TestSystemTier(unittest.TestCase):
    binary: str
    image: str
    wheel: Path

    @classmethod
    def setUpClass(cls) -> None:
        binary = detect_lxd()
        if binary is None:
            raise unittest.SkipTest(
                "system tier skipped: neither LXD (`lxc info`) nor Incus "
                "(`incus info`) responds on this host. Install one to unlock "
                "(e.g. `snap install lxd` or `apt install incus`) — this "
                "suite never installs host software itself"
            )
        cls.binary = binary
        cls.image = IMAGES[binary]
        tmp = tempfile.TemporaryDirectory(prefix="usetup-verify-wheel-")
        cls.addClassCleanup(tmp.cleanup)  # zero host residue
        cls.wheel = harness.build_wheel(Path(tmp.name))

    # -- helpers ----------------------------------------------------------------
    def _verify_one(self, entry_id: str, binary: str) -> None:
        driver = LxdDriver(self.image, binary=self.binary,
                           name=unique_name(f"usetup-verify-{entry_id}"))
        # stock cloud image: harness provisions it in-guest (apt prerequisites
        # + NOPASSWD sudoers), unlike the baked Docker verify-base image
        profile = harness.GuestProfile(needs_provision=True)
        with harness.GuestSession(driver, profile=profile) as session:
            harness.provision(session)
            harness.inject_wheel(session, self.wheel)
            harness.verify_entry(session, entry_id, binary)

    # -- the acceptance test ------------------------------------------------------
    def test_full_chain_ripgrep_and_tree_in_parallel(self):
        failures: "list[str]" = []
        with ThreadPoolExecutor(max_workers=len(ENTRIES)) as pool:
            futures = {
                pool.submit(self._verify_one, entry_id, binary): entry_id
                for entry_id, binary in ENTRIES
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
