#!/usr/bin/env bash
set -uo pipefail

# Black-box contract tests for scripts/run-metro.sh. External programs are
# replaced at the process boundary, but uname remains real: run this suite on
# both Linux and macOS (see run-metro-contract-in-linux.sh).

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$ROOT/scripts/run-metro.sh"
PASS=0
FAIL=0

fail() { echo "not ok - $1"; FAIL=$((FAIL + 1)); }
pass() { echo "ok - $1"; PASS=$((PASS + 1)); }

assert() {
  local description=$1
  shift
  if "$@"; then pass "$description"; else fail "$description"; fi
}

contains() { grep -Fq -- "$2" "$1"; }
not_contains() { ! grep -Fq -- "$2" "$1"; }

setup_case() {
  CASE_DIR=$(mktemp -d)
  export CASE_DIR
  export HOME="$CASE_DIR/home"
  export FAKE_STATE="$CASE_DIR/state"
  export FAKE_LOG="$CASE_DIR/commands.log"
  export FAKE_CURL_MODE=ok
  mkdir -p "$HOME/Library/LaunchAgents" "$CASE_DIR/bin" "$CASE_DIR/project"
  printf '{"expo":{"slug":"fixture","scheme":"fixture"}}\n' > "$CASE_DIR/project/app.json"
  : > "$FAKE_LOG"
  : > "$FAKE_STATE"

  # Preserve only the basic tools used by the script. Supervisor commands are
  # explicit fakes, so an implementation cannot accidentally manage the host.
  for command in awk bash grep head sed seq tail; do
    path=$(command -v "$command" 2>/dev/null || true)
    [ -n "$path" ] && ln -s "$path" "$CASE_DIR/bin/$command"
  done

  cat > "$CASE_DIR/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH

  cat > "$CASE_DIR/bin/jq" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'@uri'*) printf 'https%%3A%%2F%%2Ffixture.tuft.host\n' ;;
  *'.expo.slug'*) printf 'fixture\n' ;;
  *'.expo.scheme'*) printf 'fixture\n' ;;
  *'.extra.expoClient.slug'*) printf 'fixture\n' ;;
  *) exit 2 ;;
esac
SH

  cat > "$CASE_DIR/bin/tuft" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'tuft %s\n' "$*" >> "$FAKE_LOG"
case "${1:-} ${2:-}" in
  "host list")
    cat "$FAKE_STATE"
    ;;
  "host add")
    [ "${FAKE_HOST_ADD_FAIL:-0}" = 0 ] || exit 42
    port=$3; name=$5
    grep -v "^$name " "$FAKE_STATE" > "$FAKE_STATE.next" || true
    printf '%s %s: https://%s.tuft.host\n' "$name" "$port" "$name" >> "$FAKE_STATE.next"
    mv "$FAKE_STATE.next" "$FAKE_STATE"
    ;;
  "host stop")
    name=$3
    grep -v "^$name " "$FAKE_STATE" > "$FAKE_STATE.next" || true
    mv "$FAKE_STATE.next" "$FAKE_STATE"
    ;;
  "process start"|"process restart"|"process stop"|"process status")
    ;;
  *) exit 64 ;;
esac
SH

  cat > "$CASE_DIR/bin/launchctl" <<'SH'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >> "$FAKE_LOG"
[ "${FAKE_LAUNCHCTL_FAIL:-0}" = 0 ] || exit 43
SH

  cat > "$CASE_DIR/bin/lsof" <<'SH'
#!/usr/bin/env bash
port=${2##*:}
case ",${FAKE_BUSY_PORTS:-}," in *,$port,*) exit 0;; *) exit 1;; esac
SH

  cat > "$CASE_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$FAKE_LOG"
url=${*: -1}
if [ "${FAKE_CURL_MODE:-ok}" = fail ]; then exit 22; fi
case "$url" in
  */status) printf 'packager-status:running\n' ;;
  *) printf '{"extra":{"expoClient":{"slug":"fixture"}},"launchAsset":{"url":"https://fixture.tuft.host/index.bundle"}}\n' ;;
esac
SH

  chmod +x "$CASE_DIR/bin/"{tuft,launchctl,lsof,curl,sleep,jq}
  export PATH="$CASE_DIR/bin:/usr/bin:/bin"
}

teardown_case() { rm -rf "$CASE_DIR"; }

run_runner() {
  "$RUNNER" "$CASE_DIR/project" "${1:-fixture}" "${2:-}" > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
}

test_platform_contract() {
  setup_case
  if [ "$(uname -s)" = Linux ]; then
    # The production cloud VM has no launchd/systemd user session. The portable
    # contract is a Tuft-owned process supervisor, not an ambient init system.
    rm -f "$CASE_DIR/bin/launchctl"
    run_runner fixture 8091 || true
    assert "Linux starts Metro through the Tuft persistent supervisor" contains "$FAKE_LOG" "tuft process start"
    assert "Linux never executes launchctl" not_contains "$FAKE_LOG" "launchctl "
    assert "Linux does not write a LaunchAgent" test ! -e "$HOME/Library/LaunchAgents/com.tuft.metro.fixture.plist"
  else
    run_runner fixture 8091 || true
    assert "macOS bootstraps a launchd agent" contains "$FAKE_LOG" "launchctl bootstrap"
    assert "macOS persists EXPO_PACKAGER_PROXY_URL" contains "$HOME/Library/LaunchAgents/com.tuft.metro.fixture.plist" "https://fixture.tuft.host"
  fi
  teardown_case
}

test_no_supervisor_has_no_side_effects() {
  setup_case
  rm -f "$CASE_DIR/bin/launchctl"
  PATH="$CASE_DIR/bin:/usr/bin:/bin" run_runner fixture 8092 || true
  assert "unsupported runtime fails before creating a host binding" not_contains "$FAKE_LOG" "tuft host add"
  assert "unsupported runtime gives an actionable error" contains "$CASE_DIR/stderr" "supervisor"
  teardown_case
}

test_host_failure_does_not_start_process() {
  setup_case
  export FAKE_HOST_ADD_FAIL=1
  run_runner fixture 8093 || true
  assert "host publication failure does not start Metro" not_contains "$FAKE_LOG" "bootstrap"
  assert "host publication failure does not start a Tuft process" not_contains "$FAKE_LOG" "tuft process start"
  unset FAKE_HOST_ADD_FAIL
  teardown_case
}

test_supervisor_failure_rolls_back_new_binding() {
  setup_case
  export FAKE_LAUNCHCTL_FAIL=1
  run_runner fixture 8094 || true
  assert "supervisor failure removes a newly-created public binding" contains "$FAKE_LOG" "tuft host stop fixture"
  unset FAKE_LAUNCHCTL_FAIL
  teardown_case
}

test_verification_failure_cleans_up_started_process() {
  setup_case
  export FAKE_CURL_MODE=fail
  run_runner fixture 8095 || true
  if [ "$(uname -s)" = Darwin ]; then
    # One bootout is the pre-start cleanup; a second one is rollback.
    count=$(grep -c 'launchctl bootout' "$FAKE_LOG" || true)
    assert "verification failure stops the process it just started" test "$count" -ge 2
  else
    assert "verification failure stops the process it just started" contains "$FAKE_LOG" "tuft process stop"
  fi
  assert "verification failure removes a newly-created binding" contains "$FAKE_LOG" "tuft host stop fixture"
  unset FAKE_CURL_MODE
  teardown_case
}

test_existing_binding_is_not_removed_on_failure() {
  setup_case
  printf 'fixture 8096: https://fixture.tuft.host\n' > "$FAKE_STATE"
  export FAKE_CURL_MODE=fail
  run_runner fixture || true
  assert "rollback preserves a pre-existing host binding" not_contains "$FAKE_LOG" "tuft host stop fixture"
  unset FAKE_CURL_MODE
  teardown_case
}

test_explicit_busy_port_does_not_repoint_binding() {
  setup_case
  printf 'fixture 8097: https://fixture.tuft.host\n' > "$FAKE_STATE"
  export FAKE_BUSY_PORTS=8098
  run_runner fixture 8098 || true
  assert "an explicitly busy port fails before repointing the stable host" not_contains "$FAKE_LOG" "tuft host add 8098"
  unset FAKE_BUSY_PORTS
  teardown_case
}

test_name_is_a_safe_identifier() {
  setup_case
  run_runner '../other project' 8099 || true
  assert "unsafe service/host names are rejected before side effects" not_contains "$FAKE_LOG" "tuft host add"
  assert "unsafe names produce a validation error" contains "$CASE_DIR/stderr" "invalid host name"
  teardown_case
}

test_project_path_is_not_shell_interpolated() {
  setup_case
  mv "$CASE_DIR/project" "$CASE_DIR/project & quoted"
  CASE_PROJECT="$CASE_DIR/project & quoted"
  "$RUNNER" "$CASE_PROJECT" fixture 8100 > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr" || true
  if [ "$(uname -s)" = Darwin ]; then
    plist="$HOME/Library/LaunchAgents/com.tuft.metro.fixture.plist"
    assert "project path is XML-escaped in the launchd plist" not_contains "$plist" "<string>$CASE_PROJECT</string>"
  else
    assert "project path is passed as a process argument, not shell text" contains "$FAKE_LOG" "tuft process start"
  fi
  teardown_case
}

test_platform_contract
test_no_supervisor_has_no_side_effects
test_host_failure_does_not_start_process
test_supervisor_failure_rolls_back_new_binding
test_verification_failure_cleans_up_started_process
test_existing_binding_is_not_removed_on_failure
test_explicit_busy_port_does_not_repoint_binding
test_name_is_a_safe_identifier
test_project_path_is_not_shell_interpolated

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
