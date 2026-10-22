#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:---unit}"
case "$MODE" in --unit|--ui|--all|--profile-ui) ;; *) echo "usage: $0 [--unit|--ui|--all|--profile-ui]" >&2; exit 2;; esac
# Diagnostic selection is fixed; never run normal launch-based tests against Profile.
if [[ "$MODE" == --profile-ui && -n "${TEST_ONLY:-}" ]]; then
    echo '--profile-ui does not accept TEST_ONLY' >&2; exit 2
fi
unset LEVISTICA_PROFILE_WORKLOAD
# Reuse the canonical entrypoint to stop this checkout's verified development apps first.
"$ROOT_DIR/script/build_and_run.sh" --build
python3 "$ROOT_DIR/script/check-app-processes.py" --only Debug
mkdir -p "$ROOT_DIR/.local/artifacts"
RUN_DIR="$(mktemp -d "$ROOT_DIR/.local/artifacts/tests.XXXXXX")"
FIXTURE_PID=""
cleanup() {
    local result=$?
    if [[ "$MODE" == --profile-ui ]]; then
        # Reuse the verified stop/build path even if XCTest never reaches its defer.
        if python3 "$ROOT_DIR/script/check-app-processes.py" --only Profile; then
            CONFIGURATION=Release LEVISTICA_EPHEMERAL=1 LEVISTICA_PROFILE=1 \
                "$ROOT_DIR/script/build_and_run.sh" --build >"$RUN_DIR/cleanup.log" 2>&1 || result=1
        else result=1; fi
    fi
    if [[ -n "$FIXTURE_PID" ]]; then kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true; fi
    exit "$result"
}
trap cleanup EXIT
TEST_ACTION=test
BUILD_ARGS=(-project "$ROOT_DIR/Levistica.xcodeproj" -scheme Levistica
    -configuration Debug -destination 'platform=macOS'
    -derivedDataPath "$ROOT_DIR/.local/DerivedData")
if [[ "$MODE" == --unit ]]; then
    if [[ -z "${TEST_ONLY:-}" ]]; then BUILD_ARGS+=(-only-testing:LevisticaTests); fi
elif [[ "$MODE" == --profile-ui ]]; then
    if ! /usr/bin/xcodebuild "${BUILD_ARGS[@]}" build-for-testing >"$RUN_DIR/build-for-testing.log" 2>&1; then
        tail -n 70 "$RUN_DIR/build-for-testing.log" >&2; exit 1
    fi
    TEST_ACTION=test-without-building
    python3 "$ROOT_DIR/script/cross-site-fixture.py" --lifecycle --state "$RUN_DIR/lifecycle.json" >"$RUN_DIR/fixture.log" 2>&1 &
    FIXTURE_PID=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -f "$RUN_DIR/lifecycle.json" ]] && break
        kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$RUN_DIR/fixture.log" >&2; exit 1; }
        sleep 0.1
    done
    CONFIGURATION=Release LEVISTICA_EPHEMERAL=1 LEVISTICA_PROFILE=1 "$ROOT_DIR/script/build_and_run.sh" --verify
    python3 "$ROOT_DIR/script/profile-workload.py" prepare "$RUN_DIR/lifecycle.json" "$RUN_DIR/workload.json"
    BUILD_ARGS+=("LEVISTICA_PROFILE_WORKLOAD=$RUN_DIR/workload.json"
        -only-testing:LevisticaUITests/BrowserFlowTests/testProfileSleepWorkload
        -test-timeouts-enabled YES -maximum-test-execution-time-allowance 240)
else
    /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 -subj /CN=localhost \
        -keyout "$RUN_DIR/key.pem" -out "$RUN_DIR/cert.pem" >"$RUN_DIR/cert.log" 2>&1
    python3 "$ROOT_DIR/script/test-fixture.py" "$RUN_DIR/fixture.json" "$RUN_DIR/cert.pem" "$RUN_DIR/key.pem" >"$RUN_DIR/fixture.log" 2>&1 &
    FIXTURE_PID=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -f "$RUN_DIR/fixture.json" ]] && break
        kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$RUN_DIR/fixture.log" >&2; exit 1; }
        sleep 0.1
    done
    LEVISTICA_FIXTURE_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$RUN_DIR/fixture.json")"
    export LEVISTICA_FIXTURE_URL
    LEVISTICA_TLS_FIXTURE_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tlsUrl"])' "$RUN_DIR/fixture.json")"
    export LEVISTICA_TLS_FIXTURE_URL
    LEVISTICA_FAILURE_FIXTURE_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["failureUrl"])' "$RUN_DIR/fixture.json")"
    export LEVISTICA_FAILURE_FIXTURE_URL
    if [[ "$MODE" == --ui && -z "${TEST_ONLY:-}" ]]; then BUILD_ARGS+=(-only-testing:LevisticaUITests); fi
fi
if [[ -n "${LEVISTICA_FIXTURE_URL:-}" ]]; then BUILD_ARGS+=("LEVISTICA_FIXTURE_URL=$LEVISTICA_FIXTURE_URL"); fi
if [[ -n "${LEVISTICA_TLS_FIXTURE_URL:-}" ]]; then BUILD_ARGS+=("LEVISTICA_TLS_FIXTURE_URL=$LEVISTICA_TLS_FIXTURE_URL"); fi
if [[ -n "${LEVISTICA_FAILURE_FIXTURE_URL:-}" ]]; then BUILD_ARGS+=("LEVISTICA_FAILURE_FIXTURE_URL=$LEVISTICA_FAILURE_FIXTURE_URL"); fi
if [[ -n "${TEST_ONLY:-}" ]]; then BUILD_ARGS+=("-only-testing:$TEST_ONLY"); fi
BUILD_ARGS+=(-resultBundlePath "$RUN_DIR/Results.xcresult")
EXPECTED_VARIANT=Debug
[[ "$MODE" != --profile-ui ]] || EXPECTED_VARIANT=Profile
python3 "$ROOT_DIR/script/check-app-processes.py" --only "$EXPECTED_VARIANT"
echo "Test artifacts: $RUN_DIR"
if ! /usr/bin/xcodebuild "${BUILD_ARGS[@]}" "$TEST_ACTION" >"$RUN_DIR/xcodebuild.log" 2>&1; then
    tail -n 90 "$RUN_DIR/xcodebuild.log" >&2
    python3 "$ROOT_DIR/script/check-app-processes.py" --only "$EXPECTED_VARIANT" >&2 || true
    exit 1
fi
python3 "$ROOT_DIR/script/check-app-processes.py" --only "$EXPECTED_VARIANT"
if [[ "$MODE" == --profile-ui ]]; then
    python3 "$ROOT_DIR/script/profile-workload.py" validate "$RUN_DIR/lifecycle.json"
fi
tail -n 25 "$RUN_DIR/xcodebuild.log"
