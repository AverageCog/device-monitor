#!/usr/bin/env bash
# End-to-end test of the iOS app against a real hub, on a simulator. Runs on a Mac with Xcode,
# Node and openssl.
#
#   ios/Tools/e2e.sh [--sim <udid>] [--port 8543] [--control <port+1>] [--hub-dir <dir>]
#                    [--derived-data <dir>] [--result <path.xcresult>] [--skip-build]
#                    [-- <extra xcodebuild arguments>]
#
# It starts the fixture hub (build/test/mobile-hub.js: the real server.js behind TLS on
# localhost), trusts the fixture's CA in the simulator, builds the app and the UI tests, asks the
# hub for a fresh invitation and runs HubFlowUITests with it: pair, go live, relaunch, survive two
# TLS key rotations, be revoked, pair again, disconnect. The hub and whatever command is running
# (xcodebuild, simctl) are stopped when the script ends, also when it is interrupted or terminated.
#
#   --sim           the simulator to use (default: the first booted one)
#   --port          the hub's HTTPS port; its origin is https://localhost:<port>
#   --control       the port of the hub's control endpoint on 127.0.0.1
#   --hub-dir       where the fixture's CA is kept, so one CA stays trusted across runs
#                   (default: ios/.build/e2e-hub). The hub's data is fresh every run.
#   --derived-data  passed to xcodebuild as -derivedDataPath
#   --result        passed to xcodebuild as -resultBundlePath. The .xcresult bundle an earlier
#                   run left there is replaced; anything else in its place is refused.
#   --skip-build    run the tests that were built last time
#
# Exit status: xcodebuild's, 1 when the hub could not be started, 2 for arguments that cannot be
# used, 130 when interrupted. ios/Tools/e2e-selftest.sh checks this script without a simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIM="" PORT=8543 CONTROL="" HUB_DIR="$ROOT/ios/.build/e2e-hub" DERIVED="" RESULT="" SKIP_BUILD=0
EXTRA=()

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --sim) SIM="${2:?--sim needs a simulator UDID}"; shift 2 ;;
    --port) PORT="${2:?--port needs a number}"; shift 2 ;;
    --control) CONTROL="${2:?--control needs a number}"; shift 2 ;;
    --hub-dir) HUB_DIR="${2:?--hub-dir needs a directory}"; shift 2 ;;
    --derived-data) DERIVED="${2:?--derived-data needs a directory}"; shift 2 ;;
    --result) RESULT="${2:?--result needs a path}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "e2e.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
CONTROL="${CONTROL:-$((PORT + 1))}"
CONTROL_URL="http://127.0.0.1:$CONTROL"

# xcodebuild refuses a result path that exists, and would do so only after the hub was started
# and everything built. What an earlier run left there is replaced, just before the tests run;
# anything else is not this script's to delete.
replaceable() { [ ! -e "$1" ] || { [ -d "$1" ] && [ "${1%.xcresult}" != "$1" ]; }; }
RESULT="${RESULT%/}"
if [ -n "$RESULT" ] && ! replaceable "$RESULT"; then
  echo "e2e.sh: --result $RESULT exists and is not an .xcresult bundle" >&2
  exit 2
fi

for tool in node openssl xcodebuild xcrun curl; do
  command -v "$tool" > /dev/null || { echo "e2e.sh: $tool is not on PATH" >&2; exit 1; }
done

LOGS="$(mktemp -d "${TMPDIR:-/tmp}/dm-e2e.XXXXXX")"
HUB_PID="" JOB_PID=""

# stop <pid>: asks the process to end, and ends it if it has not after ten seconds.
stop() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2> /dev/null || return 0
  kill -TERM "$pid" 2> /dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2> /dev/null || break
    sleep 0.2
  done
  kill -KILL "$pid" 2> /dev/null || true
  wait "$pid" 2> /dev/null || true
}

cleanup() {
  status=$?
  trap - EXIT INT TERM
  stop "$JOB_PID"
  stop "$HUB_PID"
  if [ "$status" -ne 0 ] && [ -s "$LOGS/hub.err" ]; then
    echo "e2e.sh: the hub's error output:" >&2
    tail -n 20 "$LOGS/hub.err" >&2
  fi
  rm -rf "$LOGS"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# run <command...>: runs it so that the script can be interrupted meanwhile. Bash acts on a
# signal only once the command in the foreground has returned, and an xcodebuild that cannot
# start its test session does not return for a long time; neither does simctl when the
# simulator is stuck. Every command that waits for something else goes through here.
run() {
  "$@" &
  JOB_PID=$!
  local status=0
  wait "$JOB_PID" || status=$?
  JOB_PID=""
  return "$status"
}

if [ -z "$SIM" ]; then
  run xcrun simctl list devices booted > "$LOGS/booted"
  SIM="$(sed -nE 's/.*\(([0-9A-F-]{36})\) \(Booted\).*/\1/p' "$LOGS/booted" | head -1)"
  [ -n "$SIM" ] || { echo "e2e.sh: no simulator is booted; boot one or pass --sim <udid>" >&2; exit 1; }
fi

# The hub prints one line, with an invitation in it, when it is ready. That line is not shown:
# the invitation the test uses is asked for just before the test starts.
mkdir -p "$HUB_DIR"
node "$ROOT/build/test/mobile-hub.js" --port "$PORT" --control "$CONTROL" --dir "$HUB_DIR" > "$LOGS/hub.out" 2> "$LOGS/hub.err" &
HUB_PID=$!
ready=0
for _ in $(seq 1 150); do
  if [ -s "$LOGS/hub.out" ]; then ready=1; break; fi
  kill -0 "$HUB_PID" 2> /dev/null || break
  sleep 0.2
done
[ "$ready" = 1 ] || { echo "e2e.sh: the fixture hub did not start on port $PORT (control $CONTROL)" >&2; exit 1; }
echo "e2e.sh: fixture hub at https://localhost:$PORT (control $CONTROL_URL), pid $HUB_PID"

run xcrun simctl bootstatus "$SIM" -b > /dev/null
run xcrun simctl keychain "$SIM" add-root-cert "$HUB_DIR/ca.pem"
echo "e2e.sh: simulator $SIM trusts the fixture's CA"

XCODE=(xcodebuild -project "$ROOT/ios/DeviceMonitor.xcodeproj" -scheme DeviceMonitor -configuration Debug
  -destination "platform=iOS Simulator,id=$SIM")
[ -z "$DERIVED" ] || XCODE+=(-derivedDataPath "$DERIVED")

if [ "$SKIP_BUILD" = 0 ]; then
  run "${XCODE[@]}" ${EXTRA[@]+"${EXTRA[@]}"} build-for-testing
fi

# Single use and good for ten minutes, so it is fetched after the build. xcodebuild hands
# TEST_RUNNER_<NAME> to the test runner as <NAME>. Exported rather than put on a command line,
# where other users of this Mac could read it; on its way it is a file only this user can reach.
run curl -fsS -o "$LOGS/invitation" "$CONTROL_URL/invite"
TEST_RUNNER_DM_E2E_INVITATION="$(cat "$LOGS/invitation")"
rm -f "$LOGS/invitation"
TEST_RUNNER_DM_E2E_CONTROL="$CONTROL_URL"
export TEST_RUNNER_DM_E2E_INVITATION TEST_RUNNER_DM_E2E_CONTROL
TEST=("${XCODE[@]}" -parallel-testing-enabled NO -only-testing:DeviceMonitorUITests/HubFlowUITests)
if [ -n "$RESULT" ]; then
  # Looked at again: the build took a while.
  replaceable "$RESULT" || { echo "e2e.sh: --result $RESULT exists and is not an .xcresult bundle" >&2; exit 2; }
  rm -rf "$RESULT"
  TEST+=(-resultBundlePath "$RESULT")
fi
run "${TEST[@]}" ${EXTRA[@]+"${EXTRA[@]}"} test-without-building
