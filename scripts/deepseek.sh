#!/usr/bin/env bash
# Pinned DeepSeek GGUF deployment; model data is always on an explicit backing mount.
set -Eeuo pipefail
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

meta() {
  cat <<'META'
key=deepseek
name=DeepSeek local model
category=ai
tags=cli
ops=plan,install,deploy,background,stop-download,prepare-cuda,verify,configure,start,stop
desc=Pinned DeepSeek-V4.1-Flash-1017 UD-IQ1_S and Unsloth llama.cpp (233 GB)
META
}

_deepseek() { python3 "$KIT_ROOT/lib/deepseek.py" "$@"; }
status() { _deepseek status; }
do_plan() { _deepseek plan "$@"; }
do_install() { _deepseek install "$@"; }
do_verify() { _deepseek verify; }
do_prepare_cuda() { _deepseek prepare-cuda "$@"; }
do_deploy() { do_install "$@"; do_configure; }
_deepseek_user_bus() {
  local runtime
  runtime="/run/user/$(id -u)"
  [[ -S "$runtime/bus" ]] || { log_err "No user systemd bus at $runtime/bus"; return 2; }
  env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" "$@"
}
do_background() {
  do_plan "$@"
  _deepseek_user_bus systemd-run --user --no-block --collect --unit=deepseek-deploy \
    --description='Download, verify and prepare DeepSeek local service' \
    --property=Type=oneshot --property=TimeoutStartSec=infinity \
    --property=MemoryMax=1G --property=Nice=10 \
    "$KIT_ROOT/scripts/deepseek.sh" deploy "$@"
  log_info "Background download started; journalctl --user -u deepseek-deploy -f"
  log_info "Survives closing the terminal, but not reboot. Re-run background after reboot to resume."
}
do_stop_download() { _deepseek_user_bus systemctl --user stop deepseek-deploy.service; }
do_configure() {
  local candidate
  candidate="$(_deepseek unit)"
  if [[ -e /etc/systemd/system/deepseek-local.service ]] &&
     ! grep -qxF '# Managed by ubuntu-setup deepseek' /etc/systemd/system/deepseek-local.service; then
    log_err "Existing unmanaged deepseek-local.service; refusing to replace it."
    return 2
  fi
  systemd-analyze verify "$candidate"
  if ! cmp -s "$candidate" /etc/systemd/system/deepseek-local.service; then
    if [[ -e /etc/systemd/system/deepseek-local.service ]]; then
      sudo_run cp -p /etc/systemd/system/deepseek-local.service "${candidate}.backup.$(date +%s)"
    fi
    sudo_run install -m 0644 "$candidate" /etc/systemd/system/deepseek-local.service
    sudo_run systemctl daemon-reload
  fi
  log_info "Service prepared, not started or enabled. After reboot: swkit deepseek start"
}
do_start() {
  status
  nvidia-smi -L
  sudo_run systemctl start deepseek-local.service
  log_info "Loading is asynchronous; readiness: curl http://127.0.0.1:18080/health"
}
do_stop() { sudo_run systemctl stop deepseek-local.service; }
do_remove() {
  log_err "Automatic deletion is not supported; stop preserves the 233 GB model."
  return 2
}
usage() {
  cat <<'HELP'
swkit deepseek plan|install|deploy|background --data-dir ABS_PATH --backing-mount ABS_MOUNT
swkit deepseek status|verify|configure|start|stop
plan: read-only source, space and mount checks. install: resumable pinned downloads,
SHA256 verification and user-owned runtime extraction. Requires curl, Python 3.12+.
configure: verify and install a system service as the current user; needs sudo.
The service listens only on 127.0.0.1:18080 and is NOT started/enabled automatically.
start requires a working NVIDIA driver. verify rehashes every model shard.
deploy: install, then configure. background: run deploy in the user service manager.
stop-download: stop that job, preserving partial downloads; background resumes them.
Background jobs survive terminal closure, not reboot.
Optional model source: --model-source huggingface|modelscope (default: huggingface).
ModelScope must match every pinned file size and SHA256; existing partials are kept.
prepare-cuda --from-dir ABS_DIR: copy existing compatible CUDA 12 runtime libraries
into this deployment, checksum the copies, then require a CUDA device listing.
HELP
}
kit_dispatch "$@"
