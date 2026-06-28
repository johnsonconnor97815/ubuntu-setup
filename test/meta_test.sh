#!/usr/bin/env bash
# test/meta_test.sh — contract assertions for the meta schema + dependency resolver
# (ADR-0002/0003). Dev-only, not deployed. Run: bash test/meta_test.sh
#
# The `cond && ok || bad` idiom is intentional here (ok always returns 0, so bad only runs
# when cond is false) — same style as test/cache_test.sh.
# shellcheck disable=SC2015
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"; unset SUDO_USER
export KIT_NO_CACHE=1               # always read live meta, never a cached file
# shellcheck source=/dev/null
source "$HERE/lib/common.sh"

fail=0
ok()  { printf 'ok   - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; fail=1; }

VALID_CATS=" essentials languages editors terminal ai apps other "

# --- Every real script's meta obeys the contract --------------------------------
shopt -s nullglob
for s in "$HERE"/scripts/*.sh; do
  base="${s##*/}"; [[ "$base" == "TEMPLATE.sh" ]] && continue
  key="${base%.sh}"
  m="$("$s" meta 2>/dev/null)" || { bad "$key: meta failed"; continue; }
  cat="$(printf '%s\n' "$m" | sed -n 's/^category=//p')"
  ops="$(printf '%s\n' "$m" | sed -n 's/^ops=//p')"
  req="$(printf '%s\n' "$m" | sed -n 's/^requires=//p')"
  rec="$(printf '%s\n' "$m" | sed -n 's/^recommends=//p')"
  [[ "$VALID_CATS" == *" $cat "* ]] || bad "$key: category '$cat' not in enum"
  [[ ",$ops," == *",ui,"* ]] && bad "$key: 'ui' must not appear in ops"
  # requires/recommends entries well-formed: key, optionally key>=ver  (挡 YAML/lua 注入)
  for d in $req $rec; do
    [[ "$d" =~ ^[a-z0-9][a-z0-9-]*(\>=[0-9][0-9.]*)?$ ]] || bad "$key: malformed dep '$d'"
    dk="$(_kit_dep_key "$d")"
    [[ -f "$HERE/scripts/$dk.sh" ]] || bad "$key: dep '$dk' has no scripts/$dk.sh"
  done
done
(( fail )) || ok "all scripts: category enum + ui-not-in-ops + dep edges well-formed"

# --- Backward-compat: a script with NO tags/requires/recommends must not break ---
mkdir -p "$TMP/scripts"
cat >"$TMP/scripts/bare.sh" <<'EOS'
#!/usr/bin/env bash
meta(){ printf 'key=bare\nname=bare\ncategory=apps\nops=install,remove\ndesc=x\n'; }
"$@"
EOS
chmod +x "$TMP/scripts/bare.sh"
kit_meta_into "$TMP/scripts/bare.sh" && ok "kit_meta_into tolerates missing tags/requires" || bad "kit_meta_into broke on bare meta"
[[ -z "$_KIT_META_T" ]] && ok "missing tags -> empty global" || bad "tags global not empty for bare script"
kit_resolve_requires "$TMP/scripts/bare.sh" >/dev/null 2>&1 && ok "resolver: empty requires -> rc 0" || bad "resolver errored on no-requires script"

# --- Resolver gate / cycle: run in a COPIED lib so common.sh derives ------------
# KIT_SCRIPTS_DIR=$TMP/scripts (the real one is readonly + recomputed from the lib path).
mkdir -p "$TMP/lib"; cp "$HERE"/lib/*.sh "$TMP/lib/"
mk() { cat >"$TMP/scripts/$1.sh"; chmod +x "$TMP/scripts/$1.sh"; }   # $1=key, body on stdin
mk depZ   <<'EOS'
#!/usr/bin/env bash
meta(){ printf 'key=depZ\nname=z\ncategory=apps\nops=install\ndesc=x\n'; }
status(){ return 1; }            # never installed -> an unmet hard requires
"$@"
EOS
mk needsZ  <<'EOS'
#!/usr/bin/env bash
meta(){ printf 'key=needsZ\nname=n\ncategory=apps\nrequires=depZ\nops=install\ndesc=x\n'; }
status(){ return 1; }
"$@"
EOS
mk A <<'EOS'
#!/usr/bin/env bash
meta(){ printf 'key=A\nname=A\ncategory=apps\nrequires=B\nops=install\ndesc=x\n'; }
status(){ return 1; }
"$@"
EOS
mk B <<'EOS'
#!/usr/bin/env bash
meta(){ printf 'key=B\nname=B\ncategory=apps\nrequires=A\nops=install\ndesc=x\n'; }
status(){ return 1; }
"$@"
EOS

# Resolve <key> via the copied lib (fresh process); echoes nothing, returns the resolver rc.
resolve_copied() {
  timeout 10 bash -c '
    set -uo pipefail; export KIT_NO_CACHE=1
    source "'"$TMP"'/lib/common.sh"
    kit_resolve_requires "'"$TMP"'/scripts/'"$1"'.sh"
  ' >/dev/null 2>&1
}

rc=0; resolve_copied needsZ || rc=$?
[[ "$rc" -eq "$RC_NEED_SUDO" ]] && ok "gate: unmet hard requires -> RC_NEED_SUDO ($rc)" || bad "gate rc=$rc, expected $RC_NEED_SUDO"

rc=0; resolve_copied A || rc=$?
[[ "$rc" -ne 0 && "$rc" -ne 124 ]] && ok "cycle A<->B detected (rc=$rc, not 124 hang)" || bad "cycle not detected cleanly (rc=$rc; 124=hang)"

# --- i18n: the new category labels + badge exist in en/zh/ja --------------------
for k in cat_languages cat_editors cat_terminal cat_apps badge_desktop_only; do
  miss=""
  for lang in en zh ja; do [[ -n "${UI_MSG[$lang:$k]:-}" ]] || miss+="$lang "; done
  [[ -z "$miss" ]] && ok "i18n $k present in en/zh/ja" || bad "i18n $k missing: $miss"
done

(( fail == 0 )) && { printf '\nAll meta/resolver contract checks passed.\n'; exit 0; }
printf '\nSome checks FAILED.\n'; exit 1
