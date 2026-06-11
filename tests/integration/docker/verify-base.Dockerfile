# Verification base image for the container tier (tests/integration).
#
# A "fresh Ubuntu 24.04" plus only the scaffolding the harness itself needs
# (kitchen-dokken's lesson: the stock OCI image is *too* minimal to stand in
# for a fresh install — research/isolation-tech.md §2):
#
#   - sudo + a NOPASSWD rule for the stock `ubuntu` user (uid 1000, shipped by
#     the noble OCI image): the tool runs as a normal user and escalates per
#     command, exactly like on a real machine (non-negotiable #3);
#   - python3-venv: 24.04 is PEP 668 externally-managed — the wheel installs
#     into a venv, never the system python;
#   - python3-yaml / python3-jsonschema: the wheel is installed --no-deps with
#     --system-site-packages, so runtime deps come from apt (no PyPI traffic;
#     the headless paths never import textual — tests/tui/test_boundary.py);
#   - /var/lib/apt/lists is deliberately KEPT: per-entry containers `apt-get
#     install` straight away without re-running `apt-get update` (refreshed at
#     most daily via the APT_REFRESH cache-buster below).
#
# Built by harness.build_verify_image(); per-entry guests are disposable
# containers of this image (one fresh container per entry, never reused).
#
# BASE_IMAGE must stay a byte-identical official ubuntu:24.04 — the override
# (UBUNTU_SETUP_VERIFY_BASE_IMAGE) exists for hosts where docker.io sits
# behind a broken/mitm proxy, e.g. mirror.gcr.io/library/ubuntu:24.04.
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

# cache-buster: the harness passes today's date so the apt layers (lists
# included) are rebuilt at most once a day, never served stale for weeks.
ARG APT_REFRESH=unset

RUN echo "apt-refresh=${APT_REFRESH}" \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        sudo \
        ca-certificates \
        python3-venv \
        python3-yaml \
        python3-jsonschema \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-usetup-verify \
    && chmod 0440 /etc/sudoers.d/90-usetup-verify

CMD ["sleep", "infinity"]
