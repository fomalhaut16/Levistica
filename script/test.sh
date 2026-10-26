#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:---unit}"
case "$MODE" in --unit|--ui|--all|--profile-ui|--idle-ui|--release-idle-ui|--measure-idle-ui|--deadline-ui|--public-pdf-ui|--public-video-ui|--public-viewport-ui) ;; *) echo "usage: $0 [--unit|--ui|--all|--profile-ui|--idle-ui|--release-idle-ui|--measure-idle-ui|--deadline-ui|--public-pdf-ui|--public-video-ui|--public-viewport-ui]" >&2; exit 2;; esac
VIEWPORT_PAGE=public-html
if [[ $# -gt 1 ]]; then
    if [[ $# == 2 && "$MODE" == --public-viewport-ui && "$2" == --video ]]; then
        VIEWPORT_PAGE=public-video
    elif [[ $# == 2 && "$MODE" == --public-viewport-ui && "$2" == --pdf ]]; then
        VIEWPORT_PAGE=public-pdf
    elif [[ $# == 2 && "$MODE" == --public-viewport-ui && "$2" == --x-login ]]; then
        VIEWPORT_PAGE=public-social-login
    elif [[ $# == 2 && "$MODE" == --public-viewport-ui && "$2" == --discord-login ]]; then
        VIEWPORT_PAGE=public-chat-login
    else echo '--video, --pdf, --x-login and --discord-login are supported only with --public-viewport-ui' >&2; exit 2; fi
fi
# Diagnostic selection is fixed; never run normal launch-based tests against Profile.
if [[ ( "$MODE" == --profile-ui || "$MODE" == --idle-ui || "$MODE" == --release-idle-ui || "$MODE" == --measure-idle-ui || "$MODE" == --deadline-ui || "$MODE" == --public-pdf-ui || "$MODE" == --public-video-ui || "$MODE" == --public-viewport-ui ) && -n "${TEST_ONLY:-}" ]]; then
    echo "$MODE does not accept TEST_ONLY" >&2; exit 2
fi
case "${LEVISTICA_MALLOC_STACKS:-0}" in 0|1) ;; *) echo 'LEVISTICA_MALLOC_STACKS must be 0 or 1' >&2; exit 2;; esac
if [[ "${LEVISTICA_MALLOC_STACKS:-0}" == 1 && "$MODE" != --profile-ui ]]; then
    echo 'MALLOC_STACKS requires --profile-ui' >&2; exit 2
fi
# The idle modes differ only in the isolated app's build and signing policy.
IDLE_VARIANT=Profile
IDLE_TEST=testProfileTwentyTabIdleRevisit
IDLE_BUILD_ENV=(CONFIGURATION=Release LEVISTICA_EPHEMERAL=1 LEVISTICA_PROFILE=1 LEVISTICA_MEASUREMENT=0)
if [[ "$MODE" == --release-idle-ui || "$MODE" == --measure-idle-ui || "$MODE" == --deadline-ui || "$MODE" == --public-pdf-ui || "$MODE" == --public-video-ui || "$MODE" == --public-viewport-ui ]]; then
    IDLE_VARIANT=Measurement
    IDLE_TEST=testReleaseTwentyTabIdleRevisit
    IDLE_BUILD_ENV=(CONFIGURATION=Release LEVISTICA_EPHEMERAL=1 LEVISTICA_PROFILE=0 LEVISTICA_MEASUREMENT=1)
fi
unset LEVISTICA_PROFILE_WORKLOAD LEVISTICA_PROFILE_IDLE_WORKLOAD LEVISTICA_DEADLINE_WORKLOAD LEVISTICA_VIEWPORT_PROBE
if [[ "$MODE" == --public-viewport-ui || "$MODE" == --public-video-ui ]]; then
    IDLE_BUILD_ENV+=(LEVISTICA_VIEWPORT_PROBE=1)
fi
if [[ "$MODE" == --deadline-ui || "$MODE" == --public-pdf-ui || "$MODE" == --public-video-ui || "$MODE" == --public-viewport-ui ]]; then
    unset LEVISTICA_MEASUREMENT_STORE_ID LEVISTICA_MEASUREMENT_CLEANUP_REQUEST LEVISTICA_SESSION_TEST_ID
    export LEVISTICA_MEASUREMENT_PERSIST_METADATA=0
fi
# UI workloads require a known unlocked screen before any app is stopped or built.
if [[ "$MODE" != --unit ]]; then
    python3 "$ROOT_DIR/script/check-ui-session.py"
fi
# Reuse the canonical entrypoint to stop this checkout's verified development apps first.
LEVISTICA_MALLOC_STACKS=0 "$ROOT_DIR/script/build_and_run.sh" --build
python3 "$ROOT_DIR/script/check-app-processes.py" --only Debug
mkdir -p "$ROOT_DIR/.local/artifacts"
RUN_DIR="$(mktemp -d "$ROOT_DIR/.local/artifacts/tests.XXXXXX")"
FIXTURE_PID=""
COLLECTOR_PID=""
MEMORY_PID=""
DEADLINE_PID=""
cleanup() {
    local result=$?
    if [[ -n "$DEADLINE_PID" ]]; then kill "$DEADLINE_PID" 2>/dev/null || true; wait "$DEADLINE_PID" 2>/dev/null || true; fi
    if [[ -n "$MEMORY_PID" ]]; then kill "$MEMORY_PID" 2>/dev/null || true; wait "$MEMORY_PID" 2>/dev/null || true; fi
    if [[ -n "$COLLECTOR_PID" ]]; then kill "$COLLECTOR_PID" 2>/dev/null || true; wait "$COLLECTOR_PID" 2>/dev/null || true; fi
    if [[ "$MODE" == --profile-ui || "$MODE" == --idle-ui || "$MODE" == --release-idle-ui || "$MODE" == --measure-idle-ui || "$MODE" == --deadline-ui || "$MODE" == --public-pdf-ui || "$MODE" == --public-video-ui || "$MODE" == --public-viewport-ui ]]; then
        # Reuse the verified stop/build path even if XCTest never reaches its defer.
        if python3 "$ROOT_DIR/script/check-app-processes.py" --only "$IDLE_VARIANT"; then
            env "${IDLE_BUILD_ENV[@]}" \
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
fi
if [[ "$MODE" == --deadline-ui || "$MODE" == --public-pdf-ui || "$MODE" == --public-video-ui || "$MODE" == --public-viewport-ui ]]; then
    if ! /usr/bin/xcodebuild "${BUILD_ARGS[@]}" build-for-testing >"$RUN_DIR/build-for-testing.log" 2>&1; then
        tail -n 70 "$RUN_DIR/build-for-testing.log" >&2; exit 1
    fi
    TEST_ACTION=test-without-building
    env "${IDLE_BUILD_ENV[@]}" "$ROOT_DIR/script/build_and_run.sh" --verify
    python3 "$ROOT_DIR/script/isolated-app-deadline.py" prepare "$RUN_DIR/deadline-workload.json"
    DEADLINE_SECONDS=20
    DEADLINE_TEST=testMeasurementDeadlineExit
    DEADLINE_ALLOWANCE=60
    if [[ "$MODE" == --public-pdf-ui || "$MODE" == --public-video-ui || "$MODE" == --public-viewport-ui ]]; then
        # Fixed public workloads only; keep normal profiles and arbitrary URLs out of these trials.
        python3 - "$ROOT_DIR" "$RUN_DIR/deadline-workload.json" "$MODE" "$VIEWPORT_PAGE" <<'PYPDF'
import importlib.util
import json
import pathlib
import subprocess
import sys
root, workload = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location('deadline', root / 'script/isolated-app-deadline.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
record = json.loads(workload.read_text())
guard.verify_owned(record)
app = pathlib.Path(record['executable']).parents[2]
viewport_urls = {'public-html': 'https://www.w3.org/TR/2024/REC-WCAG22-20241212/',
                 'public-video': 'https://www.youtube.com/watch?v=aqz-KE-bpKQ&hl=en',
                 'public-pdf': 'https://arxiv.org/pdf/1706.03762v7',
                 'public-social-login': 'https://x.com/i/flow/login',
                 'public-chat-login': 'https://discord.com/login'}
urls = {'--public-pdf-ui': 'https://arxiv.org/pdf/1706.03762v7',
        '--public-video-ui': 'https://www.youtube.com/watch?v=aqz-KE-bpKQ&hl=en',
        '--public-viewport-ui': viewport_urls[sys.argv[4]]}
if sys.argv[3] == '--public-viewport-ui':
    record['viewportPageID'] = sys.argv[4]
    workload.write_text(json.dumps(record) + '\n')
subprocess.run(['/usr/bin/open', '-a', str(app), urls[sys.argv[3]]],
               check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
guard.verify_owned(record)
PYPDF
        DEADLINE_SECONDS=120
        DEADLINE_TEST=testPublicPDFReadiness
        DEADLINE_ALLOWANCE=90
        if [[ "$MODE" == --public-video-ui ]]; then
            DEADLINE_SECONDS=180
            DEADLINE_TEST=testPublicVideoReadiness
            DEADLINE_ALLOWANCE=150
        elif [[ "$MODE" == --public-viewport-ui ]]; then
            DEADLINE_SECONDS=60
            DEADLINE_TEST=testPublicViewportReadiness
            DEADLINE_ALLOWANCE=45
        fi
    fi
    python3 "$ROOT_DIR/script/isolated-app-deadline.py" monitor "$RUN_DIR/deadline-workload.json" \
        "$RUN_DIR/deadline-result.json" --seconds "$DEADLINE_SECONDS" >"$RUN_DIR/deadline-monitor.log" 2>&1 &
    DEADLINE_PID=$!
    BUILD_ARGS+=("LEVISTICA_DEADLINE_WORKLOAD=$RUN_DIR/deadline-workload.json"
        "-only-testing:LevisticaUITests/BrowserFlowTests/$DEADLINE_TEST"
        -test-timeouts-enabled YES -maximum-test-execution-time-allowance "$DEADLINE_ALLOWANCE")
elif [[ "$MODE" == --idle-ui || "$MODE" == --release-idle-ui || "$MODE" == --measure-idle-ui ]]; then
    if ! /usr/bin/xcodebuild "${BUILD_ARGS[@]}" build-for-testing >"$RUN_DIR/build-for-testing.log" 2>&1; then
        tail -n 70 "$RUN_DIR/build-for-testing.log" >&2; exit 1
    fi
    TEST_ACTION=test-without-building
    python3 "$ROOT_DIR/script/cross-site-fixture.py" --count 20 --state "$RUN_DIR/idle-state.json" >"$RUN_DIR/fixture.log" 2>&1 &
    FIXTURE_PID=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -f "$RUN_DIR/idle-state.json" ]] && break
        kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$RUN_DIR/fixture.log" >&2; exit 1; }
        sleep 0.1
    done
    env "${IDLE_BUILD_ENV[@]}" "$ROOT_DIR/script/build_and_run.sh" --verify
    python3 "$ROOT_DIR/script/idle-workload.py" prepare "$RUN_DIR/idle-state.json" "$RUN_DIR/idle-workload.json" --variant "$IDLE_VARIANT"
    python3 "$ROOT_DIR/script/idle-workload.py" monitor "$RUN_DIR/idle-health.json" >"$RUN_DIR/idle-health.log" 2>&1 &
    COLLECTOR_PID=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -f "$RUN_DIR/idle-health.json" ]] && break
        kill -0 "$COLLECTOR_PID" 2>/dev/null || { echo 'Pressure monitor exited before startup' >&2; exit 1; }
        sleep 0.1
    done
    [[ -f "$RUN_DIR/idle-health.json" ]] || { echo 'Pressure monitor did not become ready' >&2; exit 1; }
    python3 "$ROOT_DIR/script/idle-workload.py" deliver "$RUN_DIR/idle-state.json" "$RUN_DIR/idle-workload.json"
    if [[ "$MODE" == --measure-idle-ui ]]; then
        python3 "$ROOT_DIR/script/idle-workload.py" capture "$RUN_DIR/idle-state.json" "$RUN_DIR/idle-workload.json" >"$RUN_DIR/memory-collector.log" 2>&1 &
        MEMORY_PID=$!
    fi
    BUILD_ARGS+=("LEVISTICA_PROFILE_IDLE_WORKLOAD=$RUN_DIR/idle-workload.json"
        "-only-testing:LevisticaUITests/BrowserFlowTests/$IDLE_TEST"
        -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300)
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
    if [[ "${LEVISTICA_MALLOC_STACKS:-0}" == 1 ]]; then
        python3 "$ROOT_DIR/script/profile-workload.py" serve "$RUN_DIR/lifecycle.json" "$RUN_DIR/workload.json" >"$RUN_DIR/collector.log" 2>&1 &
        COLLECTOR_PID=$!
        for ((attempt=0; attempt<100; attempt++)); do
            [[ -f "$RUN_DIR/collector-ready.json" ]] && break
            kill -0 "$COLLECTOR_PID" 2>/dev/null || { cat "$RUN_DIR/collector.log" >&2; exit 1; }
            sleep 0.1
        done
        [[ -f "$RUN_DIR/collector-ready.json" ]] || { echo 'Diagnostic collector did not become ready' >&2; exit 1; }
    fi
    BUILD_ARGS+=("LEVISTICA_PROFILE_WORKLOAD=$RUN_DIR/workload.json"
        -only-testing:LevisticaUITests/BrowserFlowTests/testProfileSleepWorkload
        -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180)
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
[[ "$MODE" != --profile-ui && "$MODE" != --idle-ui && "$MODE" != --release-idle-ui && "$MODE" != --measure-idle-ui && "$MODE" != --deadline-ui && "$MODE" != --public-pdf-ui && "$MODE" != --public-video-ui && "$MODE" != --public-viewport-ui ]] || EXPECTED_VARIANT="$IDLE_VARIANT"
python3 "$ROOT_DIR/script/check-app-processes.py" --only "$EXPECTED_VARIANT"
echo "Test artifacts: $RUN_DIR"
if ! /usr/bin/xcodebuild "${BUILD_ARGS[@]}" "$TEST_ACTION" >"$RUN_DIR/xcodebuild.log" 2>&1; then
    tail -n 90 "$RUN_DIR/xcodebuild.log" >&2
    # WebKit diagnostics can push the actual assertion out of the log tail.
    # Reporting is best-effort; it must never turn a failed build/test into success.
    if /usr/bin/xcrun xcresulttool get test-results summary --path "$RUN_DIR/Results.xcresult" \
        --format json >"$RUN_DIR/test-summary.json" 2>"$RUN_DIR/test-summary-error.log"; then
        python3 "$ROOT_DIR/script/report-test-failures.py" "$RUN_DIR/test-summary.json" >&2 \
            || echo 'Could not report test failure details; inspect the result bundle and xcodebuild.log.' >&2
    else
        echo 'Test summary unavailable; inspect xcodebuild.log for build or runner failures.' >&2
    fi
    python3 "$ROOT_DIR/script/check-app-processes.py" --only "$EXPECTED_VARIANT" >&2 || true
    exit 1
fi
python3 "$ROOT_DIR/script/check-app-processes.py" --only "$EXPECTED_VARIANT"
# xcodebuild can return success when a selector matches no tests. Verify the
# result bundle, rather than treating its exit status as execution evidence.
/usr/bin/xcrun xcresulttool get test-results summary --path "$RUN_DIR/Results.xcresult" \
    --format json >"$RUN_DIR/test-summary.json"
python3 - "$RUN_DIR/test-summary.json" <<'PYRESULT'
import json
import pathlib
import sys
summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
counts = [summary.get(key) for key in ('totalTestCount', 'passedTests', 'failedTests')]
if (any(type(value) is not int or value < 0 for value in counts)
        or counts[0] == 0 or counts[1] == 0 or counts[2] != 0):
    raise SystemExit('No successful test execution in the result bundle; check TEST_ONLY and test results.')
print(f'Verified test result: {counts[1]} passed of {counts[0]} total, {counts[2]} failed.')
PYRESULT
if [[ "$MODE" == --deadline-ui ]]; then
    wait "$DEADLINE_PID"
    DEADLINE_PID=""
    echo 'Isolated app deadline and XCTest completion verified; no browsing or memory comparison.'
elif [[ "$MODE" == --public-pdf-ui || "$MODE" == --public-video-ui || "$MODE" == --public-viewport-ui ]]; then
    # The successful UI test terminates its verified app. Cancel its remaining watchdog.
    kill "$DEADLINE_PID" 2>/dev/null || true
    MONITOR_STATUS=0
    wait "$DEADLINE_PID" 2>/dev/null || MONITOR_STATUS=$?
    if [[ "$MONITOR_STATUS" != 0 && "$MONITOR_STATUS" != 143 ]]; then
        python3 - "$RUN_DIR/deadline-result.json" <<'PYPDFEND'
import json
import pathlib
import sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if result.get('status') != 'identity_changed_no_signal':
    raise SystemExit('Deadline monitor failed unexpectedly')
PYPDFEND
    fi
    DEADLINE_PID=""
    echo 'Public workload UI conditions verified; no memory comparison.'
elif [[ "$MODE" == --profile-ui ]]; then
    if [[ -n "$COLLECTOR_PID" ]]; then
        wait "$COLLECTOR_PID"
        COLLECTOR_PID=""
    fi
    python3 "$ROOT_DIR/script/profile-workload.py" validate "$RUN_DIR/lifecycle.json"
elif [[ "$MODE" == --idle-ui || "$MODE" == --release-idle-ui || "$MODE" == --measure-idle-ui ]]; then
    python3 "$ROOT_DIR/script/idle-workload.py" validate "$RUN_DIR/idle-state.json"
    if [[ "$MODE" == --measure-idle-ui ]]; then
        wait "$MEMORY_PID"
        MEMORY_PID=""
        echo "Single RAM sample and UI trial succeeded; no comparison or product acceptance."
    fi
fi
tail -n 25 "$RUN_DIR/xcodebuild.log"
