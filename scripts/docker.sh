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

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. Proper nouns stay UNtranslated
# ("Docker", the literal "docker" group name, "systemctl"); only descriptive wording is
# localized. Resolve with _docker_t KEY (fallback en -> key, like ui_t).
declare -gA DOCKER_I18N
DOCKER_I18N[en:runtime_suffix]="Docker — container runtime"
DOCKER_I18N[en:status]="Status"
DOCKER_I18N[en:docker_group]="docker group"
DOCKER_I18N[en:service]="service"
DOCKER_I18N[en:no_systemctl]="(no systemctl)"
DOCKER_I18N[en:configure_row]="add you to the docker group + enable/start service"
DOCKER_I18N[en:confirm_remove]="Uninstall Docker? (apt remove docker.io — keeps your data)"
DOCKER_I18N[en:foot_main]="↑↓ move   ↵/space select   esc/q close"
DOCKER_I18N[zh:runtime_suffix]="Docker — 容器运行时"
DOCKER_I18N[zh:status]="状态"
DOCKER_I18N[zh:docker_group]="docker 组"
DOCKER_I18N[zh:service]="服务"
DOCKER_I18N[zh:no_systemctl]="(无 systemctl)"
DOCKER_I18N[zh:configure_row]="把你加入 docker 组 + 启用/启动服务"
DOCKER_I18N[zh:confirm_remove]="卸载 Docker?(apt remove docker.io — 保留你的数据)"
DOCKER_I18N[zh:foot_main]="↑↓ 移动   ↵/space 选择   esc/q 关闭"
DOCKER_I18N[ja:runtime_suffix]="Docker — コンテナランタイム"
DOCKER_I18N[ja:status]="状態"
DOCKER_I18N[ja:docker_group]="docker グループ"
DOCKER_I18N[ja:service]="サービス"
DOCKER_I18N[ja:no_systemctl]="(systemctl なし)"
DOCKER_I18N[ja:configure_row]="あなたを docker グループに追加 + サービスを有効化/起動"
DOCKER_I18N[ja:confirm_remove]="Docker をアンインストールしますか?(apt remove docker.io — データは保持)"
DOCKER_I18N[ja:foot_main]="↑↓ 移動   ↵/space 選択   esc/q 閉じる"

# _docker_t KEY — localized Docker string for $UI_LANG (en/zh/ja), fallback en -> key.
_docker_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${DOCKER_I18N[$lang:$1]:-${DOCKER_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=docker
name=Docker (docker.io)
category=terminal
tags=cli
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

# --- Interactive management screen (the script's own UI) -----------------------
# A bespoke full-screen panel: header shows the installed badge + docker version; when
# installed, a small status panel reports whether the current user is in the docker group
# and whether the service is active. Action rows install / configure / uninstall, each
# shelling out via ui_run (so apt/sudo output is visible + logged); the screen reloads its
# live status after every change. Limited terminals fall back to the synthesized op menu.
# `ui` is an entry mode (kit_dispatch) — never listed in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver="" user in_group=0 svc_active=0 svc_known=0
    user="${SUDO_USER:-$(id -un)}"
    if status >/dev/null 2>&1; then
      installed=1
      ver="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
      if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then in_group=1; fi
      if have_cmd systemctl; then
        svc_known=1
        [[ "$(systemctl is-active docker 2>/dev/null || true)" == "active" ]] && svc_active=1
      fi
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) $(_docker_t runtime_suffix)")
    else
      # Status panel (non-selectable info rows).
      dkind+=(header); did+=(""); dlabel+=("$(_docker_t status)")
      local grp_badge svc_badge
      if (( in_group )); then grp_badge="$(ui_badge active)"; else grp_badge="$(ui_badge inactive)"; fi
      dkind+=(info); did+=(""); dlabel+=("$(printf '  %-13s %s %s' "$(_docker_t docker_group)" "$grp_badge" "${UI_MUTED}$user${UI_OFF}")")
      if (( svc_known )); then
        if (( svc_active )); then svc_badge="$(ui_badge active)"; else svc_badge="$(ui_badge inactive)"; fi
      else
        svc_badge="$(ui_badge inactive) ${UI_MUTED}$(_docker_t no_systemctl)${UI_OFF}"
      fi
      dkind+=(info); did+=(""); dlabel+=("$(printf '  %-13s %s' "$(_docker_t service)" "$svc_badge")")
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(configure); did+=(configure); dlabel+=("$(ui_t configure) — $(_docker_t configure_row)")
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(remove); did+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Docker")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header|info)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header|info) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Docker" "v$ver ${UI_OK}${UI_CHECK}${UI_OFF}"
    else ui_header "Docker" "$(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        info)   ui_move "$row" 1; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    ui_footer "$(_docker_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header|info) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header|info) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install)   ui_run "$(ui_t install) Docker" -- "$0" install ;;
          configure) ui_run "$(ui_t configure) · docker" -- "$0" configure ;;
          remove)    ui_confirm "$(_docker_t confirm_remove)" n \
                       && ui_run "$(ui_t remove) Docker" -- "$0" remove ;;
        esac ;;
      q|Q|esc|backspace) break ;;
    esac
  done
  ui_end
  return 0
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Commands:
  install    Install Docker via apt (docker.io; idempotent)
  remove     Uninstall Docker (apt remove docker.io — keeps your data)
  configure  Add you to the docker group + enable/start the service (idempotent)
  ui         Open the interactive manager (needs a terminal)
  status     Print 'docker --version'; exit 0 iff installed
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
