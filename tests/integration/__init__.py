"""Real-install integration tier: clean Ubuntu 24.04 guests, driven end-to-end.

This package verifies catalog entries against the *real* tool inside disposable
guests (fresh ``ubuntu:24.04``, never a reused dirty container): build the
project wheel on the host, inject it into the guest (venv — 24.04 is PEP 668
externally-managed), then run the per-entry protocol
``fresh check -> install -> idempotent re-run`` and assert exit codes, stdout
and manifest semantics against the spec.

Gating (the ``UBUNTU_SETUP_SMOKE`` convention): everything here is locked
behind ``UBUNTU_SETUP_INTEGRATION=1`` — the default
``python -m unittest discover -s tests`` collects these modules but skips the
gated classes instantly, so the unit suite stays green and fast. The driver
unit tests (``test_drivers.py``, mock host-run — no docker/lxd needed) are NOT
gated and always run.

How to run:

    # container tier (Docker; the 95-entry apt/dpkg/file class)
    UBUNTU_SETUP_INTEGRATION=1 python -m unittest tests.integration.test_container -v

    # system tier (LXD/Incus system containers; the 15-entry systemd/snap class)
    UBUNTU_SETUP_INTEGRATION=1 python -m unittest tests.integration.test_system -v

    # both tiers
    UBUNTU_SETUP_INTEGRATION=1 python -m unittest discover -s tests/integration -t . -v

Knobs:

- ``UBUNTU_SETUP_INTEGRATION_ARTIFACTS`` — where failure diagnostics (guest
  transcript + audit log + manifest snapshot) are written; defaults to
  ``tests/integration/_artifacts/`` (gitignored).
- ``UBUNTU_SETUP_INTEGRATION_KEEP=1`` — keep a *failed* guest alive for manual
  inspection instead of destroying it.
- ``UBUNTU_SETUP_VERIFY_BASE_IMAGE`` — alternate reference for the official
  ``ubuntu:24.04`` base (proxied/mirrored docker.io hosts; e.g.
  ``mirror.gcr.io/library/ubuntu:24.04``). Must stay byte-identical upstream.

Hard rule: this tier NEVER installs software on the host (no sudo / apt /
snap). A missing docker daemon or lxd/incus is an explicit skip with the
reason — unlocking the system tier is the user's call (e.g. ``snap install
lxd`` or ``apt install incus``), never the test suite's.
"""
