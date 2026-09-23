#!/usr/bin/env bash
# Runtime-aware launcher tests. These tests never install packages or use the host Python.
# The compact assertions below intentionally use the established `cond && ok || bad`
# test style; `ok` always returns zero.
# shellcheck disable=SC2015
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }

make_fake() {
  local path="$1" version="$2"
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
  for arg in "\$@"; do
    case "\$arg" in
      -c)
        printf '%s\\n' '$version'
        exit 0
        ;;
      -m)
        printf 'dispatched:%s\\n' "\$*"
        printf 'PYTHONPATH=%s\\n' "\${PYTHONPATH:-}"
        exit 0
        ;;
    esac
  done
  printf 'unexpected invocation\\n' >&2
  exit 97
EOF
  chmod +x "$path"
}

make_isolated_bin() {
  local dir="$1" command_name
  mkdir -p "$dir"
  for command_name in bash dirname readlink; do
    ln -s "$(command -v "$command_name")" "$dir/$command_name"
  done
}

LOW="$TMP/python-low"
make_fake "$LOW" 3.8.10
if out="$(UBUNTU_SETUP_PYTHON="$LOW" "$HERE/ubuntu-setup" runtime --format json 2>/dev/null)"; then
  bad "low explicit Python was accepted"
else
  rc=$?
  [[ "$rc" -eq 3 && "$out" == *'"error_code":"runtime_unavailable"'* && "$out" == *'configure --python 3.12'* ]] \
    && ok "low explicit Python is blocked with exit code 3 and structured JSON" \
    || bad "low Python error was rc=$rc, not structured JSON, or had the wrong repair command"
fi

OK="$TMP/python-ok"
make_fake "$OK" 3.12.4
out="$(UBUNTU_SETUP_PYTHON="$OK" "$HERE/ubuntu-setup" inspect --format json --no-open)"
[[ "$out" == *'dispatched:-m ubuntu_setup inspect --format json --no-open'* ]] \
  && ok "compatible Python receives the inspection command" \
  || bad "compatible Python was not used to dispatch"
if [[ "$out" == *"PYTHONPATH=$HERE:"* || "$out" == *"PYTHONPATH=$HERE" ]]; then
  ok "inspection command receives the checkout first on PYTHONPATH"
else
  bad "inspection command did not receive the checkout first on PYTHONPATH"
fi

CONTROL_PATH="$TMP/python"$'\x01'
make_fake "$CONTROL_PATH" 3.8.10
if out="$(UBUNTU_SETUP_PYTHON="$CONTROL_PATH" "$HERE/ubuntu-setup" runtime --format json 2>/dev/null)"; then
  bad "low explicit Python with control character was accepted"
else
  rc=$?
  escaped_control='\u0001'
  [[ "$rc" -eq 3 && "$out" == *"$escaped_control"* && "$out" != *$'\x01'* ]] \
    && ok "runtime error JSON escapes control characters" \
    || bad "runtime error JSON did not escape control characters safely"
fi

PATH_BIN="$TMP/path-bin"
make_isolated_bin "$PATH_BIN"
for name in python python3 python3.10 python3.11 python3.12 python3.13 python3.14; do
  make_fake "$PATH_BIN/$name" 3.8.10
done
if out="$(PATH="$PATH_BIN" HOME="$TMP/home" "$HERE/ubuntu-setup" inspect --format json 2>/dev/null)"; then
  bad "no compatible PATH interpreter was accepted"
else
  rc=$?
  [[ "$rc" -eq 3 && "$out" == *'"error_code":"runtime_unavailable"'* ]] \
    && ok "missing compatible runtime returns exit code 3 and JSON" \
    || bad "missing runtime was rc=$rc or JSON was not returned"
fi

HIGH_BIN="$TMP/high-bin"
make_isolated_bin "$HIGH_BIN"
make_fake "$HIGH_BIN/python3" 3.8.10
make_fake "$HIGH_BIN/python3.10" 3.10.9
make_fake "$HIGH_BIN/python3.12" 3.12.1
out="$(PATH="$HIGH_BIN" HOME="$TMP/home2" "$HERE/ubuntu-setup" runtime status)"
[[ "$out" == *"python3.12"*"3.12.1"* ]] && ok "highest compatible interpreter is selected" || bad "runtime selection did not prefer the highest version"

PYTHON_ONLY_BIN="$TMP/python-only-bin"
make_isolated_bin "$PYTHON_ONLY_BIN"
make_fake "$PYTHON_ONLY_BIN/python" 3.12.4
for name in python3 python3.10 python3.11 python3.12 python3.13 python3.14; do
  make_fake "$PYTHON_ONLY_BIN/$name" 3.8.10
done
out="$(PATH="$PYTHON_ONLY_BIN" HOME="$TMP/home3" "$HERE/ubuntu-setup" runtime status --format json)"
[[ "$out" == *'/python'*,*'"version":"3.12.4"'* ]] \
  && ok "compatible unversioned python command is selected" \
  || bad "unversioned python command was not considered"

FUTURE_BIN="$TMP/future-bin"
make_isolated_bin "$FUTURE_BIN"
make_fake "$FUTURE_BIN/python3" 3.8.10
make_fake "$FUTURE_BIN/python3.15" 3.15.0
out="$(PATH="$FUTURE_BIN" HOME="$TMP/home4" "$HERE/ubuntu-setup" runtime status --format json)"
[[ "$out" == *'python3.15'*'"version":"3.15.0"'* ]] \
  && ok "future versioned Python command is discovered" \
  || bad "future versioned Python command was not discovered"

if out="$(UBUNTU_SETUP_PYTHON="$OK" "$HERE/ubuntu-setup" runtime status --bogus 2>/dev/null)"; then
  bad "unknown runtime argument was accepted"
else
  rc=$?
  [[ "$rc" -eq 2 ]] && ok "unknown runtime argument returns exit code 2" || bad "unknown runtime argument was rc=$rc"
fi

(( fail == 0 )) && { printf '\nAll runtime launcher checks passed.\n'; exit 0; }
printf '\nSome runtime launcher checks FAILED.\n'
exit 1
