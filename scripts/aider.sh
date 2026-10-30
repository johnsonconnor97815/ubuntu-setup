#!/usr/bin/env bash
# Isolated Aider installation and a local-model MCP entry for Codex.
set -Eeuo pipefail
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

readonly AIDER_VERSION=0.86.2 AIDER_MCP_VERSION=1.1.0 AIDER_MCP_SDK_VERSION=2.0.0-alpha.2

meta() {
  cat <<'META'
key=aider
name=Aider local coding worker
category=ai
tags=cli
ops=install,remove,configure,serve
desc=Isolated Aider and MCP executor for an OpenAI-compatible local model
META
}
_aider_user_guard() {
  [[ "$EUID" -ne 0 ]] || { log_err "Run Aider management as your normal user."; return 2; }
}
_aider_mcp_dir() { printf '%s/ubuntu-setup/aider-mcp\n' "${XDG_DATA_HOME:-$HOME/.local/share}"; }
_aider_path() {
  have_cmd uv || { log_err "uv is required; use swkit python install-uv."; return 1; }
  local bin
  bin="$(uv tool dir --bin)"
  export PATH="$bin:$PATH"
}
status() {
  _aider_path || return
  have_cmd aider && have_cmd node || return 1
  [[ "$(aider --version)" == "aider $AIDER_VERSION" ]] || return 1
  node -e 'const p = require(process.argv[1]); if (p.version !== process.argv[2]) process.exit(1)' \
    "$(_aider_mcp_dir)/node_modules/mcp-aider-executor/package.json" "$AIDER_MCP_VERSION" || return
  node -e 'const p = require(process.argv[1]); if (p.version !== process.argv[2]) process.exit(1)' \
    "$(_aider_mcp_dir)/node_modules/@modelcontextprotocol/server/package.json" "$AIDER_MCP_SDK_VERSION" || return
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0
  aider --version
  printf 'mcp-aider-executor %s (user-local npm prefix)\n' "$AIDER_MCP_VERSION"
}
do_install() {
  _aider_user_guard
  _aider_path
  if ! have_cmd npm || ! have_cmd node; then
    log_err "Node.js and npm are required."
    return 1
  fi
  if status >/dev/null 2>&1; then
    log_info "Pinned Aider and MCP executor are already installed."
    return 0
  fi
  log_info "uv tool install --python python3.12 --with pip aider-chat==$AIDER_VERSION"
  uv tool install --python python3.12 --with pip "aider-chat==$AIDER_VERSION"
  log_info "Installing mcp-aider-executor@$AIDER_MCP_VERSION in a private npm prefix."
  # The executor imports the alpha SDK's root StdioServerTransport export. Its
  # broad upstream range also selects stable SDKs that removed that export.
  npm install --prefix "$(_aider_mcp_dir)" --ignore-scripts --no-audit --no-fund --save-exact \
    "mcp-aider-executor@$AIDER_MCP_VERSION" "@modelcontextprotocol/server@$AIDER_MCP_SDK_VERSION"
  status
}
do_remove() {
  log_err "Remove explicitly with uv tool uninstall aider-chat; MCP files and Codex configuration are preserved."
  return 2
}
do_configure() {
  _aider_user_guard
  status >/dev/null
  python3 "$KIT_ROOT/lib/aider_config.py" --kit-root "$KIT_ROOT" "$@"
}
do_serve() {
  _aider_user_guard
  _aider_path
  local root="${1:-}"
  [[ "$root" == /* && -d "$root" ]] || { log_err "serve requires an existing absolute workspace root."; return 2; }
  exec node "$(_aider_mcp_dir)/node_modules/mcp-aider-executor/dist/index.js" \
    --model openai/deepseek-v4.1-flash-1017 --edit-format diff --no-architect \
    --no-register-git-tools --no-register-file-tools --whitelist "$root/**"
}
usage() {
  cat <<'HELP'
swkit aider install|status
swkit aider configure --root ABS_WORKSPACE_ROOT
swkit aider serve ABS_WORKSPACE_ROOT
Installs aider-chat 0.86.2 with uv/Python 3.12 and mcp-aider-executor 1.1.0 in
a private npm prefix. No sudo; existing system Python and npm prefix are untouched.
configure registers aider-deepseek in the current user's Codex config, pointing at
127.0.0.1:18080/v1. Aider auto/dirty commits, analytics and .gitignore edits are off.
The advertised context is 8192 tokens (6144 input, 2048 output); no model-service
changes are made. Each task still needs explicit files and project instructions.
serve is the stdio MCP entry, normally started by Codex. Restart/reconnect the
client after configuration. remove deliberately preserves files and settings.
HELP
}
kit_dispatch "$@"
