#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:-run}"
CONFIGURATION="${CONFIGURATION:-Debug}"
case "$MODE" in run|--build|--verify|--debug|--logs|--telemetry) ;; *) echo "usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2;; esac
case "$CONFIGURATION" in Debug|Release) ;; *) echo 'CONFIGURATION must be Debug or Release' >&2; exit 2;; esac
# Persistent manual tests must opt into both a Debug build and isolated data.
if [[ -n "${LEVISTICA_SESSION_TEST_ID:-}" ]]; then
    if [[ "$CONFIGURATION" != Debug || "${LEVISTICA_EPHEMERAL:-0}" != 1 || ! "$LEVISTICA_SESSION_TEST_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
        echo 'SESSION_TEST_ID requires Debug, EPHEMERAL=1, and a UUID' >&2
        exit 2
    fi
fi
APP_BUNDLE="$ROOT_DIR/.local/DerivedData/Build/Products/$CONFIGURATION/Levistica.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Levistica"
LOG_DIR="$ROOT_DIR/.local/artifacts"
mkdir -p "$LOG_DIR"

# Stop only this checkout's development app, after matching its executable path.
for pid in $(/usr/bin/pgrep -x Levistica || true); do
    actual="$(/bin/ps -p "$pid" -o comm= || true)"
    case "$actual" in
        "$ROOT_DIR/.local/DerivedData/Build/Products/Debug/Levistica.app/Contents/MacOS/Levistica"|\
        "$ROOT_DIR/.local/DerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica") ;;
        *) continue ;;
    esac
    bundle="${actual%/Contents/MacOS/Levistica}"
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$identifier" == dev.fomalhaut16.Levistica || "$identifier" == dev.fomalhaut16.Levistica.debug ]]; then
        /bin/kill -TERM "$pid"
        for ((attempt=0; attempt<50; attempt++)); do
            /bin/kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if /bin/kill -0 "$pid" 2>/dev/null; then
            echo 'Levistica is still running; close it before rebuilding.' >&2
            exit 1
        fi
    fi
done

if ! /usr/bin/xcodebuild -project "$ROOT_DIR/Levistica.xcodeproj" -scheme Levistica \
    -configuration "$CONFIGURATION" -destination 'platform=macOS' \
    -derivedDataPath "$ROOT_DIR/.local/DerivedData" build >"$LOG_DIR/build-$CONFIGURATION.log" 2>&1; then
    tail -n 70 "$LOG_DIR/build-$CONFIGURATION.log" >&2
    exit 1
fi
/usr/bin/codesign --verify --strict "$APP_BUNDLE"
echo "Built $APP_BUNDLE"
case "$MODE" in
    --build) exit 0 ;;
    --debug) exec /usr/bin/xcrun lldb -- "$APP_BINARY" ;;
esac
if [[ "${LEVISTICA_EPHEMERAL:-0}" == 1 ]]; then
    LEVISTICA_OPEN_ARGS=(-n --env LEVISTICA_EPHEMERAL=1)
    if [[ -n "${LEVISTICA_SESSION_TEST_ID:-}" ]]; then
        LEVISTICA_OPEN_ARGS+=(--env "LEVISTICA_SESSION_TEST_ID=$LEVISTICA_SESSION_TEST_ID")
    fi
    /usr/bin/open "${LEVISTICA_OPEN_ARGS[@]}" "$APP_BUNDLE"
else
    /usr/bin/open -n "$APP_BUNDLE"
fi
case "$MODE" in
    --verify)
        sleep 2
        for pid in $(/usr/bin/pgrep -x Levistica || true); do
            [[ "$(/bin/ps -p "$pid" -o comm= || true)" == "$APP_BINARY" ]] && { echo "Running PID $pid (process check only)"; exit 0; }
        done
        echo 'The built application did not stay running.' >&2; exit 1 ;;
    --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "Levistica"' ;;
    --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.fomalhaut16.Levistica"' ;;
esac
