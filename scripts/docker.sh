#!/usr/bin/env bash
#
# scripts/docker.sh — install / configure / manage Docker on Ubuntu (docker.io).
#
# Channel-conservative: uses Ubuntu's own `docker.io` package, NOT docker-ce from
# get.docker.com. A vendor-repo (docker-ce) variant is a possible future evolution.

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

meta() {
  cat <<'META'
key=docker
name=Docker (docker.io)
category=common
ops=install,remove,configure
desc=Container runtime from Ubuntu's docker.io package
META
}

status() { have_cmd docker && docker --version; }

do_install() {
  if status >/dev/null 2>&1; then
    log_info "Docker already installed ($(docker --version 2>/dev/null)) — skipping."
    return 0
  fi
  apt_install docker.io
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Docker is not installed — nothing to remove."
    return 0
  fi
  apt_remove docker.io
}

# Minimal, safe configuration: let the real user run docker without sudo (docker group)
# and make the daemon start on boot / right now. Both steps are idempotent.
do_configure() {
  local user
  user="${SUDO_USER:-$(id -un)}"

  if ! status >/dev/null 2>&1; then
    log_info "Docker is not installed — install it first."
    return 0
  fi

  if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
    log_info "User '$user' is already in the docker group — skipping."
  else
    sudo_run usermod -aG docker "$user"
    log_info "Added '$user' to the docker group — log out and back in for it to take effect."
  fi

  if have_cmd systemctl; then
    sudo_run systemctl enable --now docker || log_warn "could not enable/start docker"
  else
    log_info "no systemctl — start the docker daemon yourself."
  fi
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Commands:
  install    Install Docker via apt (docker.io; idempotent)
  remove     Uninstall Docker (apt remove docker.io — keeps your data)
  configure  Add you to the docker group + enable/start the service (idempotent)
  status     Print 'docker --version'; exit 0 iff installed
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
