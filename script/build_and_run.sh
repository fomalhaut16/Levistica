#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:-run}"
CONFIGURATION="${CONFIGURATION:-Debug}"
PROFILE="${LEVISTICA_PROFILE:-0}"
MALLOC_STACKS="${LEVISTICA_MALLOC_STACKS:-0}"
case "$MODE" in run|--build|--verify|--debug|--logs|--telemetry) ;; *) echo "usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2;; esac
case "$CONFIGURATION" in Debug|Release) ;; *) echo 'CONFIGURATION must be Debug or Release' >&2; exit 2;; esac
case "$PROFILE" in 0|1) ;; *) echo 'LEVISTICA_PROFILE must be 0 or 1' >&2; exit 2;; esac
if [[ "$PROFILE" == 1 && ( "$CONFIGURATION" != Release || "${LEVISTICA_EPHEMERAL:-0}" != 1 || -n "${LEVISTICA_SESSION_TEST_ID:-}" ) ]]; then
    echo 'PROFILE requires Release, EPHEMERAL=1, and no SESSION_TEST_ID' >&2
    exit 2
fi
case "$MALLOC_STACKS" in 0|1) ;; *) echo 'LEVISTICA_MALLOC_STACKS must be 0 or 1' >&2; exit 2;; esac
if [[ "$MALLOC_STACKS" == 1 && "$PROFILE" != 1 ]]; then
    echo 'MALLOC_STACKS requires the isolated Profile build' >&2; exit 2
fi
# Persistent manual tests must opt into both a Debug build and isolated data.
if [[ -n "${LEVISTICA_SESSION_TEST_ID:-}" ]]; then
    if [[ "$CONFIGURATION" != Debug || "${LEVISTICA_EPHEMERAL:-0}" != 1 || ! "$LEVISTICA_SESSION_TEST_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
        echo 'SESSION_TEST_ID requires Debug, EPHEMERAL=1, and a UUID' >&2
        exit 2
    fi
fi
DERIVED_DATA="$ROOT_DIR/.local/DerivedData"
VARIANT="$CONFIGURATION"
EXPECTED_IDENTIFIER="dev.fomalhaut16.Levistica"
[[ "$CONFIGURATION" != Debug ]] || EXPECTED_IDENTIFIER+=".debug"
if [[ "$PROFILE" == 1 ]]; then
    DERIVED_DATA="$ROOT_DIR/.local/ProfileDerivedData"
    VARIANT=Profile
    EXPECTED_IDENTIFIER="dev.fomalhaut16.Levistica.profile"
fi
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/Levistica.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Levistica"
BUILD_ARGS=(-project "$ROOT_DIR/Levistica.xcodeproj" -scheme Levistica
    -configuration "$CONFIGURATION" -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA")
LOG_DIR="$ROOT_DIR/.local/artifacts"
# Discover by executable path first. A renamed process must not bypass the stop checks.
python3 "$ROOT_DIR/script/check-app-processes.py"
mkdir -p "$LOG_DIR"
if [[ "$PROFILE" == 1 ]]; then
    PROFILE_ENTITLEMENTS="$LOG_DIR/profile.entitlements"
    cp "$ROOT_DIR/Levistica/Levistica.entitlements" "$PROFILE_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$PROFILE_ENTITLEMENTS"
    BUILD_ARGS+=("CODE_SIGN_ENTITLEMENTS=$PROFILE_ENTITLEMENTS"
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
        "PRODUCT_BUNDLE_IDENTIFIER=$EXPECTED_IDENTIFIER"
        SWIFT_ACTIVE_COMPILATION_CONDITIONS=LEVISTICA_PROFILE)
fi

# Stop only this checkout's development app, after matching its executable path.
for pid in $(/usr/bin/pgrep -x Levistica || true); do
    actual="$(/bin/ps -p "$pid" -o comm= || true)"
    case "$actual" in
        "$ROOT_DIR/.local/DerivedData/Build/Products/Debug/Levistica.app/Contents/MacOS/Levistica") identifier_to_stop=dev.fomalhaut16.Levistica.debug ;;
        "$ROOT_DIR/.local/DerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica") identifier_to_stop=dev.fomalhaut16.Levistica ;;
        "$ROOT_DIR/.local/ProfileDerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica") identifier_to_stop=dev.fomalhaut16.Levistica.profile ;;
        *) continue ;;
    esac
    bundle="${actual%/Contents/MacOS/Levistica}"
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$identifier" == "$identifier_to_stop" ]]; then
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

if ! /usr/bin/xcodebuild "${BUILD_ARGS[@]}" build >"$LOG_DIR/build-$VARIANT.log" 2>&1; then
    tail -n 70 "$LOG_DIR/build-$VARIANT.log" >&2
    exit 1
fi
/usr/bin/codesign --verify --strict "$APP_BUNDLE"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
[[ "$identifier" == "$EXPECTED_IDENTIFIER" ]] || { echo 'Unexpected built bundle identifier' >&2; exit 1; }
/usr/bin/codesign -d --entitlements :- "$APP_BUNDLE" >"$LOG_DIR/entitlements-$VARIANT.plist" 2>"$LOG_DIR/signature-$VARIANT.log"
get_task_allow="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$LOG_DIR/entitlements-$VARIANT.plist" 2>/dev/null || true)"
if [[ "$PROFILE" == 1 ]]; then
    [[ "$get_task_allow" == true ]] || { echo 'Profiling build is missing get-task-allow' >&2; exit 1; }
elif [[ "$CONFIGURATION" == Release && "$get_task_allow" == true ]]; then
    echo 'Release must not include get-task-allow' >&2
    exit 1
fi
echo "Built $APP_BUNDLE"
case "$MODE" in
    --build) exit 0 ;;
    --debug) exec /usr/bin/xcrun lldb -- "$APP_BINARY" ;;
esac
if [[ "${LEVISTICA_EPHEMERAL:-0}" == 1 ]]; then
    LEVISTICA_OPEN_ARGS=(-n --env LEVISTICA_EPHEMERAL=1)
    if [[ "$MALLOC_STACKS" == 1 ]]; then
        LEVISTICA_OPEN_ARGS+=(--env MallocStackLogging=lite)
    fi
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
        python3 "$ROOT_DIR/script/check-app-processes.py" --only "$VARIANT"
        for pid in $(/usr/bin/pgrep -x Levistica || true); do
            [[ "$(/bin/ps -p "$pid" -o comm= || true)" == "$APP_BINARY" ]] && { echo "Running PID $pid (process check only)"; exit 0; }
        done
        echo 'The built application did not stay running.' >&2; exit 1 ;;
    --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "Levistica"' ;;
    --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.fomalhaut16.Levistica"' ;;
esac
