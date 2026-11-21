#!/usr/bin/env bash
# Checks ios/Tools/e2e.sh itself. `xcrun` and `xcodebuild` are replaced by stand-ins and the
# fixture hub is the real one, so it needs no Xcode and no simulator: it runs wherever Node,
# openssl and curl are, macOS or Linux, in under a minute.
#
#   ios/Tools/e2e-selftest.sh [--port 8581]        (the port after it is used as well)
#
# It checks that e2e.sh
#   - hands the test runner a fresh invitation and the control address, shows the invitation
#     nowhere, and leaves no hub behind;
#   - replaces the result bundle of an earlier run, and refuses a --result that is something
#     else before it starts anything;
#   - ends at once, with its hub, when it is sent TERM: while a simulator command hangs, and
#     while xcodebuild runs.
#
# Exit status: 0 when every check passed, 1 otherwise.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E="$ROOT/ios/Tools/e2e.sh"
PORT=8581
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:?--port needs a number}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "e2e-selftest.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
CONTROL=$((PORT + 1))

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dm-e2e-selftest.XXXXXX")"
RUN_PID=""
# The hub of the run in <output file>, as e2e.sh announced it.
hub_pid() { sed -nE 's/^e2e\.sh: fixture hub at .*, pid ([0-9]+)$/\1/p' "$1" 2> /dev/null | head -1; }
# Ends what a run that did not clean up after itself has left: that is what is being tested.
sweep() {
  local pid
  for pid in "$RUN_PID" "$(cat "$WORK/hang.pid" 2> /dev/null)" "$(hub_pid "$WORK/out-last")"; do
    # Only what it still is: a number that has gone may be somebody else's process by now.
    [ -n "$pid" ] && ps -p "$pid" -o command= 2> /dev/null | grep -q -e 'e2e\.sh' -e 'sleep 600' -e 'mobile-hub\.js' && kill -KILL "$pid" 2> /dev/null
  done
  RUN_PID=""
  rm -f "$WORK/hang.pid" "$WORK/out-last"
}
finish() {
  status=$?
  trap - EXIT INT TERM
  sweep
  rm -rf "$WORK"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM

# ---- The stand-ins. Each notes its command line; "hang" makes one step wait to be killed. ----
mkdir "$WORK/bin"
cat > "$WORK/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
echo "xcrun $*" >> "$E2E_STUB_LOG"
case "$*" in
  "simctl list devices booted") echo "    iPhone 17 Pro (11111111-2222-4333-8444-555555555555) (Booted)" ;;
  "simctl bootstatus "*)
    if [ "${E2E_STUB_HANG:-}" = bootstatus ]; then echo $$ > "$E2E_STUB_PID"; exec sleep 600; fi ;;
  "simctl keychain "*" add-root-cert "*)
    for last; do :; done
    [ -s "$last" ] || { echo "xcrun stand-in: no certificate at $last" >&2; exit 1; } ;;
  *) echo "xcrun stand-in: unexpected arguments: $*" >&2; exit 1 ;;
esac
STUB
cat > "$WORK/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
echo "xcodebuild $*" >> "$E2E_STUB_LOG"
result=""
for last; do :; done
while [ $# -gt 1 ]; do
  [ "$1" != -resultBundlePath ] || result="$2"
  shift
done
case "$last" in
  build-for-testing) ;;
  test-without-building)
    # What the real one says about a result path that exists, and its exit status.
    if [ -n "$result" ] && [ -e "$result" ]; then
      echo "xcodebuild: error: Existing file at -resultBundlePath \"$result\"" >&2
      exit 64
    fi
    if [ -n "$result" ]; then mkdir -p "$result" && echo "$$-$RANDOM" > "$result/made"; fi
    printf '%s\n%s\n' "${TEST_RUNNER_DM_E2E_INVITATION:-}" "${TEST_RUNNER_DM_E2E_CONTROL:-}" > "$E2E_STUB_ENV"
    if [ "${E2E_STUB_HANG:-}" = test ]; then echo $$ > "$E2E_STUB_PID"; exec sleep 600; fi ;;
  *) echo "xcodebuild stand-in: unexpected action: $last" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/xcrun" "$WORK/bin/xcodebuild"
export PATH="$WORK/bin:$PATH"
export E2E_STUB_LOG="$WORK/commands" E2E_STUB_ENV="$WORK/runner-env" E2E_STUB_PID="$WORK/hang.pid"

FAILED=0
pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; [ -z "${2:-}" ] || echo "$2" | sed 's/^/        /'; FAILED=1; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

hub_answers() { curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$CONTROL/state" 2> /dev/null; }
# e2e <output file> <arguments...>: one run, with the stand-ins and this self-test's ports.
e2e() {
  local out="$1"; shift
  : > "$E2E_STUB_LOG"; rm -f "$E2E_STUB_ENV" "$E2E_STUB_PID"
  "$E2E" --port "$PORT" --control "$CONTROL" --hub-dir "$WORK/hub" "$@" > "$out" 2>&1
}

if hub_answers; then
  echo "e2e-selftest.sh: something already answers on port $CONTROL; pass another --port" >&2
  exit 1
fi

# ---- 1. A whole run ----
status=0; e2e "$WORK/out1" --result "$WORK/run.xcresult" || status=$?
check "a run succeeds when xcodebuild does" '[ "$status" = 0 ]' "exit $status: $(cat "$WORK/out1")"
invitation="$(sed -n 1p "$E2E_STUB_ENV" 2> /dev/null)"
code="${invitation##*#join=}"
shape="^https://localhost:$PORT/mobile#join=[A-Za-z0-9_-]{43}\$"
check "the test runner gets an invitation from this hub" '[[ "$invitation" =~ $shape ]]' "got: $invitation"
check "the test runner gets the control address" '[ "$(sed -n 2p "$E2E_STUB_ENV" 2> /dev/null)" = "http://127.0.0.1:$CONTROL" ]'
check "the simulator that is booted is used, and is given the fixture's CA" \
  'grep -q "^xcrun simctl keychain 11111111-2222-4333-8444-555555555555 add-root-cert $WORK/hub/ca.pem$" "$E2E_STUB_LOG"' "$(cat "$E2E_STUB_LOG")"
check "the tests run after the build, with the result path" \
  '[ "$(grep -c "^xcodebuild " "$E2E_STUB_LOG")" = 2 ] && sed -n "\$p" "$E2E_STUB_LOG" | grep -q -- "-resultBundlePath $WORK/run.xcresult .*test-without-building$"' "$(cat "$E2E_STUB_LOG")"
check "the invitation is in no output and on no command line" \
  '[ ${#code} = 43 ] && ! grep -q -- "$code" "$WORK/out1" "$E2E_STUB_LOG"'
check "no hub is left" '! hub_answers'

# ---- 2. The result bundle of an earlier run ----
made="$(cat "$WORK/run.xcresult/made" 2> /dev/null)"
status=0; e2e "$WORK/out2" --result "$WORK/run.xcresult" --skip-build || status=$?
check "a second run with the same --result succeeds" '[ "$status" = 0 ]' "exit $status: $(tail -n 3 "$WORK/out2")"
check "and replaces the bundle" '[ -n "$made" ] && [ "$(cat "$WORK/run.xcresult/made" 2> /dev/null)" != "$made" ]'

mkdir "$WORK/keep" && echo mine > "$WORK/keep/file"
status=0; e2e "$WORK/out3" --result "$WORK/keep" || status=$?
check "a --result that exists and is no result bundle is refused" '[ "$status" = 2 ]' "exit $status: $(tail -n 3 "$WORK/out3")"
check "before anything is started, and it is left alone" '[ ! -s "$E2E_STUB_LOG" ] && [ "$(cat "$WORK/keep/file")" = mine ]' "$(cat "$E2E_STUB_LOG")"

# ---- 3. TERM ----
# terminated <step> <arguments...>: starts a run in which <step> hangs, sends TERM once it does,
# and checks that the script, the hanging command and the hub are gone within five seconds.
terminated() {
  local step="$1" waited=0 status=0 hanging; shift
  : > "$E2E_STUB_LOG"; rm -f "$E2E_STUB_PID"
  E2E_STUB_HANG="$step" "$E2E" --port "$PORT" --control "$CONTROL" --hub-dir "$WORK/hub" "$@" > "$WORK/out-last" 2>&1 &
  RUN_PID=$!
  until [ -s "$E2E_STUB_PID" ] || ! kill -0 "$RUN_PID" 2> /dev/null || [ "$waited" -ge 300 ]; do sleep 0.1; waited=$((waited + 1)); done
  check "the $step step is reached, and the hub is running by then" '[ -s "$E2E_STUB_PID" ] && hub_answers' "$(cat "$WORK/out-last")"
  hanging="$(cat "$E2E_STUB_PID" 2> /dev/null)"

  kill -TERM "$RUN_PID" 2> /dev/null
  waited=0
  while kill -0 "$RUN_PID" 2> /dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  if kill -0 "$RUN_PID" 2> /dev/null; then
    fail "TERM during the $step step ends the script within five seconds" "still running; its hub $(hub_answers && echo "still answers" || echo "is gone")"
    kill -KILL "$RUN_PID" 2> /dev/null
  else
    pass "TERM during the $step step ends the script within five seconds"
  fi
  wait "$RUN_PID" 2> /dev/null || status=$?
  RUN_PID=""
  check "with exit status 130" '[ "$status" = 130 ]' "exit $status"
  check "the hanging command is stopped" '[ -n "$hanging" ] && ! kill -0 "$hanging" 2> /dev/null'
  check "no hub is left" '! hub_answers'
  sweep
}
terminated bootstatus
terminated test --skip-build

[ "$FAILED" = 0 ] && echo "e2e-selftest.sh: all checks passed" || echo "e2e-selftest.sh: some checks FAILED" >&2
exit "$FAILED"
