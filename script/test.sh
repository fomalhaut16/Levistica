#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:---unit}"
case "$MODE" in --unit|--ui|--all) ;; *) echo "usage: $0 [--unit|--ui|--all]" >&2; exit 2;; esac
# Reuse the canonical entrypoint to stop this checkout's Debug/Release app first.
"$ROOT_DIR/script/build_and_run.sh" --build
mkdir -p "$ROOT_DIR/.local/artifacts"
RUN_DIR="$(mktemp -d "$ROOT_DIR/.local/artifacts/tests.XXXXXX")"
FIXTURE_PID=""
cleanup() { if [[ -n "$FIXTURE_PID" ]]; then kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true; fi; }
trap cleanup EXIT
BUILD_ARGS=(-project "$ROOT_DIR/Levistica.xcodeproj" -scheme Levistica
    -configuration Debug -destination 'platform=macOS'
    -derivedDataPath "$ROOT_DIR/.local/DerivedData" -resultBundlePath "$RUN_DIR/Results.xcresult")
if [[ "$MODE" == --unit ]]; then
    if [[ -z "${TEST_ONLY:-}" ]]; then BUILD_ARGS+=(-only-testing:LevisticaTests); fi
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
echo "Test artifacts: $RUN_DIR"
if ! /usr/bin/xcodebuild "${BUILD_ARGS[@]}" test >"$RUN_DIR/xcodebuild.log" 2>&1; then
    tail -n 90 "$RUN_DIR/xcodebuild.log" >&2
    exit 1
fi
tail -n 25 "$RUN_DIR/xcodebuild.log"
