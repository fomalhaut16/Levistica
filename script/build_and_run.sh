#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEWPORT_PROBE="${LEVISTICA_VIEWPORT_PROBE:-0}"
case "$VIEWPORT_PROBE" in 0|1) ;; *) echo 'VIEWPORT_PROBE must be 0 or 1' >&2; exit 2;; esac
if [[ "$VIEWPORT_PROBE" == 1 ]]; then
    if [[ "${CONFIGURATION:-Debug}" != Release || "${LEVISTICA_EPHEMERAL:-0}" != 1 || "${LEVISTICA_MEASUREMENT:-0}" != 1 || "${LEVISTICA_PROFILE:-0}" != 0 || -n "${LEVISTICA_MEASUREMENT_STORE_ID:-}" || "${LEVISTICA_MEASUREMENT_PERSIST_METADATA:-0}" != 0 ]]; then
        echo 'VIEWPORT_PROBE requires nonpersistent isolated Release Measurement' >&2; exit 2
    fi
    case "${1:-run}" in run|--build|--verify) ;; *) echo 'VIEWPORT_PROBE supports only run, --build or --verify' >&2; exit 2;; esac
fi
# Run two existing isolated revisions against newly generated metadata only.
# This mode never builds or stops an app that was already running.
if [[ "${1:-}" == --rehearse-session-update ]]; then
    if [[ $# -lt 2 || $# -gt 3 || ( $# == 3 && "$3" != --recovered ) || "${CONFIGURATION:-Debug}" != Release || "${LEVISTICA_EPHEMERAL:-0}" != 1 || "${LEVISTICA_MEASUREMENT:-0}" != 1 || "${LEVISTICA_PROFILE:-0}" != 0 || "${LEVISTICA_MALLOC_STACKS:-0}" != 0 || -n "${LEVISTICA_MEASUREMENT_STORE_ID:-}" || -n "${LEVISTICA_SESSION_TEST_ID:-}" || "${LEVISTICA_MEASUREMENT_PERSIST_METADATA:-0}" != 0 || -n "${LEVISTICA_MEASUREMENT_CLEANUP_REQUEST+x}" ]]; then
        echo 'Session update rehearsal requires isolated Release Measurement without caller-supplied stores' >&2
        exit 2
    fi
    exec python3 "$ROOT_DIR/script/rehearse-session-update.py" "${@:2}"
fi
# Archive smoke checks do not rebuild or stop an existing app. The helper refuses
# any pre-existing Levistica and launches only the validated archive, ephemerally.
if [[ "${1:-}" == --verify-archive-local ]]; then
    if [[ $# != 2 || "${CONFIGURATION:-Debug}" != Release || "${LEVISTICA_EPHEMERAL:-0}" != 1 ]]; then
        echo 'Use CONFIGURATION=Release LEVISTICA_EPHEMERAL=1 with --verify-archive-local ARCHIVE' >&2
        exit 2
    fi
    exec python3 "$ROOT_DIR/script/verify-archive-startup.py" "$2"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
MODE="${1:-run}"
CONFIGURATION="${CONFIGURATION:-Debug}"
PROFILE="${LEVISTICA_PROFILE:-0}"
MEASUREMENT="${LEVISTICA_MEASUREMENT:-0}"
MALLOC_STACKS="${LEVISTICA_MALLOC_STACKS:-0}"
STORE_ID="${LEVISTICA_MEASUREMENT_STORE_ID:-}"
PERSIST_METADATA="${LEVISTICA_MEASUREMENT_PERSIST_METADATA-0}"
case "$PERSIST_METADATA" in 0|1) ;; *) echo 'MEASUREMENT_PERSIST_METADATA must be 0 or 1' >&2; exit 2;; esac
if [[ "$PERSIST_METADATA" == 1 && ( "$MEASUREMENT" != 1 || -z "$STORE_ID" ) ]]; then
    echo 'Persistent metadata requires Measurement and an owned store UUID' >&2; exit 2
fi
case "$MODE" in run|--build|--verify|--debug|--logs|--telemetry|--archive-local) ;; *) echo "usage: $0 [--build|--verify|--debug|--logs|--telemetry|--archive-local]" >&2; exit 2;; esac
case "$CONFIGURATION" in Debug|Release) ;; *) echo 'CONFIGURATION must be Debug or Release' >&2; exit 2;; esac
ARCHIVE_LOCAL=0
if [[ "$MODE" == --archive-local ]]; then
    if [[ "$CONFIGURATION" != Release || "$PROFILE" != 0 || "$MEASUREMENT" != 0 || "$MALLOC_STACKS" != 0 || "${LEVISTICA_EPHEMERAL:-0}" != 0 || -n "$STORE_ID" || "$PERSIST_METADATA" != 0 || -n "${LEVISTICA_SESSION_TEST_ID:-}" ]]; then
        echo 'Local archiving requires ordinary Release without test or diagnostic flags' >&2
        exit 2
    fi
    ARCHIVE_LOCAL=1
fi
case "$PROFILE" in 0|1) ;; *) echo 'LEVISTICA_PROFILE must be 0 or 1' >&2; exit 2;; esac
if [[ "$PROFILE" == 1 && ( "$CONFIGURATION" != Release || "${LEVISTICA_EPHEMERAL:-0}" != 1 || -n "${LEVISTICA_SESSION_TEST_ID:-}" ) ]]; then
    echo 'PROFILE requires Release, EPHEMERAL=1, and no SESSION_TEST_ID' >&2
    exit 2
fi
case "$MEASUREMENT" in 0|1) ;; *) echo 'LEVISTICA_MEASUREMENT must be 0 or 1' >&2; exit 2;; esac
if [[ "$MEASUREMENT" == 1 && ( "$CONFIGURATION" != Release || "${LEVISTICA_EPHEMERAL:-0}" != 1 || "$PROFILE" != 0 || -n "${LEVISTICA_SESSION_TEST_ID:-}" || "$MALLOC_STACKS" != 0 ) ]]; then
    echo 'MEASUREMENT requires Release, EPHEMERAL=1, PROFILE=0, no SESSION_TEST_ID, and no stack logging' >&2
    exit 2
fi
case "$MALLOC_STACKS" in 0|1) ;; *) echo 'LEVISTICA_MALLOC_STACKS must be 0 or 1' >&2; exit 2;; esac
if [[ "$MALLOC_STACKS" == 1 && "$PROFILE" != 1 ]]; then
    echo 'MALLOC_STACKS requires the isolated Profile build' >&2; exit 2
fi
if [[ "${LEVISTICA_MEASUREMENT_CLEANUP_REQUEST+x}" == x ]]; then
    echo 'Measurement cleanup requests are not supported' >&2; exit 2
fi
if [[ "${LEVISTICA_MEASUREMENT_STORE_ID+x}" == x && -z "$STORE_ID" ]]; then
    echo 'MEASUREMENT_STORE_ID must be a nonzero owned UUID' >&2; exit 2
fi
if [[ -n "$STORE_ID" ]]; then
    if [[ "$MODE" == --debug ]]; then
        echo 'Persistent measurement does not support --debug' >&2; exit 2
    fi
    if [[ "$MEASUREMENT" != 1 ]]; then
        echo 'MEASUREMENT_STORE_ID requires the isolated Measurement build' >&2; exit 2
    fi
    if ! python3 "$ROOT_DIR/script/measurement-store.py" validate "$STORE_ID"; then exit 2; fi
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
if [[ "$MEASUREMENT" == 1 ]]; then
    DERIVED_DATA="$ROOT_DIR/.local/MeasurementDerivedData"
    VARIANT=Measurement
    EXPECTED_IDENTIFIER="dev.fomalhaut16.Levistica.measurement"
fi
if [[ "$ARCHIVE_LOCAL" == 1 ]]; then
    if [[ -L "$ROOT_DIR/.local" || -L "$ROOT_DIR/.local/archives" ]]; then
        echo 'Local archive directories must not be symbolic links' >&2; exit 2
    fi
    mkdir -p "$ROOT_DIR/.local/archives"
    ARCHIVE_CONTAINER="$(mktemp -d "$ROOT_DIR/.local/archives/local-XXXXXXXX")"
    DERIVED_DATA="$ARCHIVE_CONTAINER/DerivedData"
    ARCHIVE_PATH="$ARCHIVE_CONTAINER/Levistica.xcarchive"
    VARIANT=LocalArchive
fi
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/Levistica.app"
if [[ "$ARCHIVE_LOCAL" == 1 ]]; then
    APP_BUNDLE="$ARCHIVE_PATH/Products/Applications/Levistica.app"
fi
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Levistica"
BUILD_ARGS=(-project "$ROOT_DIR/Levistica.xcodeproj" -scheme Levistica
    -configuration "$CONFIGURATION" -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA")
LOG_DIR="$ROOT_DIR/.local/artifacts"
BUILD_ACTION=build
if [[ "$ARCHIVE_LOCAL" == 1 ]]; then
    BUILD_ACTION=archive
    BUILD_ARGS+=(-archivePath "$ARCHIVE_PATH" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
    LOG_DIR="$ARCHIVE_CONTAINER"
fi
# Discover by executable path first. A renamed process must not bypass the stop checks.
if [[ "$ARCHIVE_LOCAL" != 1 ]]; then
    if [[ "$MEASUREMENT" == 1 ]]; then
        python3 "$ROOT_DIR/script/check-app-processes.py" --only Measurement
    else
        python3 "$ROOT_DIR/script/check-app-processes.py"
    fi
fi
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

if [[ "$MEASUREMENT" == 1 ]]; then
    BUILD_ARGS+=(CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
        "PRODUCT_BUNDLE_IDENTIFIER=$EXPECTED_IDENTIFIER"
        SWIFT_ACTIVE_COMPILATION_CONDITIONS=LEVISTICA_MEASUREMENT)
fi

# Embed source identity before signing; a direct Xcode build stays unknown.
SOURCE_REVISION=unknown
SOURCE_STATE=unknown
repository_root="$(git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ "$repository_root" == "$ROOT_DIR" ]]; then
    candidate_revision="$(git -C "$ROOT_DIR" rev-parse --verify HEAD 2>/dev/null || true)"
    if [[ "$candidate_revision" =~ ^[0-9a-f]{40}$ ]]; then
        SOURCE_REVISION="$candidate_revision"
        if source_status="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal 2>/dev/null)"; then
            SOURCE_STATE=clean
            [[ -z "$source_status" ]] || SOURCE_STATE=modified
        fi
    fi
fi
BUILD_ARGS+=("LEVISTICA_SOURCE_REVISION=$SOURCE_REVISION" "LEVISTICA_SOURCE_STATE=$SOURCE_STATE")

# Stop only this checkout's development app, after matching its executable path.
if [[ "$ARCHIVE_LOCAL" != 1 ]]; then
    for pid in $(/usr/bin/pgrep -x Levistica || true); do
        actual="$(/bin/ps -p "$pid" -o comm= || true)"
        case "$actual" in
            "$ROOT_DIR/.local/DerivedData/Build/Products/Debug/Levistica.app/Contents/MacOS/Levistica") identifier_to_stop=dev.fomalhaut16.Levistica.debug ;;
            "$ROOT_DIR/.local/DerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica") identifier_to_stop=dev.fomalhaut16.Levistica ;;
            "$ROOT_DIR/.local/ProfileDerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica") identifier_to_stop=dev.fomalhaut16.Levistica.profile ;;
            "$ROOT_DIR/.local/MeasurementDerivedData/Build/Products/Release/Levistica.app/Contents/MacOS/Levistica") identifier_to_stop=dev.fomalhaut16.Levistica.measurement ;;
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
fi

if ! /usr/bin/xcodebuild "${BUILD_ARGS[@]}" "$BUILD_ACTION" >"$LOG_DIR/build-$VARIANT.log" 2>&1; then
    tail -n 70 "$LOG_DIR/build-$VARIANT.log" >&2
    exit 1
fi
/usr/bin/codesign --verify --strict "$APP_BUNDLE"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
[[ "$identifier" == "$EXPECTED_IDENTIFIER" ]] || { echo 'Unexpected built bundle identifier' >&2; exit 1; }
built_revision="$(/usr/libexec/PlistBuddy -c 'Print :LevisticaSourceRevision' "$APP_BUNDLE/Contents/Info.plist")"
built_source_state="$(/usr/libexec/PlistBuddy -c 'Print :LevisticaSourceState' "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$built_revision" != "$SOURCE_REVISION" || "$built_source_state" != "$SOURCE_STATE" ]]; then
    echo 'Built source identity does not match the build request' >&2
    exit 1
fi
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
    --archive-local)
        echo "Local archive: $ARCHIVE_PATH"
        echo 'Local validation only; Developer ID distribution and notarization are not performed.'
        exit 0 ;;
    --debug) exec /usr/bin/xcrun lldb -- "$APP_BINARY" ;;
esac
if [[ "${LEVISTICA_EPHEMERAL:-0}" == 1 ]]; then
    LEVISTICA_OPEN_ARGS=(-n --env LEVISTICA_EPHEMERAL=1)
    if [[ "$VIEWPORT_PROBE" == 1 ]]; then
        LEVISTICA_OPEN_ARGS+=(--env LEVISTICA_VIEWPORT_PROBE=1)
    fi
    if [[ -n "$STORE_ID" ]]; then
        LEVISTICA_OPEN_ARGS+=(--env "LEVISTICA_MEASUREMENT_STORE_ID=$STORE_ID")
    fi
    if [[ "$PERSIST_METADATA" == 1 ]]; then
        LEVISTICA_OPEN_ARGS+=(--env LEVISTICA_MEASUREMENT_PERSIST_METADATA=1)
    fi
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
