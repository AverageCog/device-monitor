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
# TLS key rotations, be revoked, pair again, disconnect. The hub is always shut down at the end.
#
#   --sim           the simulator to use (default: the first booted one)
#   --port          the hub's HTTPS port; its origin is https://localhost:<port>
#   --control       the port of the hub's control endpoint on 127.0.0.1
#   --hub-dir       where the fixture's CA is kept, so one CA stays trusted across runs
#                   (default: ios/.build/e2e-hub). The hub's data is fresh every run.
#   --derived-data  passed to xcodebuild as -derivedDataPath
#   --result        passed to xcodebuild as -resultBundlePath (must not exist yet)
#   --skip-build    run the tests that were built last time
#
# Exit status: xcodebuild's, or 1 when the hub could not be started.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIM="" PORT=8543 CONTROL="" HUB_DIR="$ROOT/ios/.build/e2e-hub" DERIVED="" RESULT="" SKIP_BUILD=0
EXTRA=()

usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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

for tool in node openssl xcodebuild xcrun curl; do
  command -v "$tool" > /dev/null || { echo "e2e.sh: $tool is not on PATH" >&2; exit 1; }
done

if [ -z "$SIM" ]; then
  SIM="$(xcrun simctl list devices booted | sed -nE 's/.*\(([0-9A-F-]{36})\) \(Booted\).*/\1/p' | head -1)"
  [ -n "$SIM" ] || { echo "e2e.sh: no simulator is booted; boot one or pass --sim <udid>" >&2; exit 1; }
fi

LOGS="$(mktemp -d "${TMPDIR:-/tmp}/dm-e2e.XXXXXX")"
HUB_PID=""
cleanup() {
  status=$?
  if [ -n "$HUB_PID" ] && kill -0 "$HUB_PID" 2> /dev/null; then
    kill -TERM "$HUB_PID" 2> /dev/null || true
    wait "$HUB_PID" 2> /dev/null || true
  fi
  if [ "$status" -ne 0 ] && [ -s "$LOGS/hub.err" ]; then
    echo "e2e.sh: the hub's error output:" >&2
    tail -n 20 "$LOGS/hub.err" >&2
  fi
  rm -rf "$LOGS"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

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

xcrun simctl bootstatus "$SIM" -b > /dev/null
xcrun simctl keychain "$SIM" add-root-cert "$HUB_DIR/ca.pem"
echo "e2e.sh: simulator $SIM trusts the fixture's CA"

XCODE=(xcodebuild -project "$ROOT/ios/DeviceMonitor.xcodeproj" -scheme DeviceMonitor -configuration Debug
  -destination "platform=iOS Simulator,id=$SIM")
[ -z "$DERIVED" ] || XCODE+=(-derivedDataPath "$DERIVED")

if [ "$SKIP_BUILD" = 0 ]; then
  "${XCODE[@]}" ${EXTRA[@]+"${EXTRA[@]}"} build-for-testing
fi

# Single use and good for ten minutes, so it is fetched after the build. xcodebuild hands
# TEST_RUNNER_<NAME> to the test runner as <NAME>.
INVITATION="$(curl -fsS "$CONTROL_URL/invite")"
TEST=("${XCODE[@]}" -parallel-testing-enabled NO -only-testing:DeviceMonitorUITests/HubFlowUITests)
[ -z "$RESULT" ] || TEST+=(-resultBundlePath "$RESULT")
TEST_RUNNER_DM_E2E_INVITATION="$INVITATION" TEST_RUNNER_DM_E2E_CONTROL="$CONTROL_URL" \
  "${TEST[@]}" ${EXTRA[@]+"${EXTRA[@]}"} test-without-building
