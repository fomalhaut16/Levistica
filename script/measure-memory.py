#!/usr/bin/env python3
"""Read-only, local-only footprints for Release/isolated Release Levistica or isolated Chrome.

Attribution verifies PID-domain XPC; Chrome also verifies descendants and its isolated Crashpad.
launchctl's human-readable format is not a stable API: parsing fails closed.
Raw launchctl output can contain environment values and is never saved or printed.
"""
import argparse
import ctypes
import datetime
import hashlib
import functools
import importlib.util
import json
import os
import pathlib
import plistlib
import re
import statistics
import sys
import subprocess
import tempfile
import time
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / ".local/DerivedData/Build/Products/Release/Levistica.app"
BINARY = APP / "Contents/MacOS/Levistica"


def run(args, timeout=30):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=timeout,
                                   env={**os.environ, "LC_ALL": "C"})


class PowerConditionError(ValueError):
    pass


def parse_power_source(text):
    first = text.splitlines()[0].strip() if isinstance(text, str) and text.splitlines() else ''
    return {"Now drawing from 'AC Power'": 'ac',
            "Now drawing from 'Battery Power'": 'battery'}.get(first, 'unknown')


def record_ac_power(observations, phase):
    try:
        source = parse_power_source(run(['/usr/bin/pmset', '-g', 'batt'], timeout=5))
    except (OSError, subprocess.SubprocessError):
        source = 'unknown'
    observations.append({'phase': phase, 'source': source,
                         'time_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()})
    if source != 'ac':
        raise PowerConditionError('AC power required; observed source: ' + source)


def parse_domain(text, pid, app, creator_name="Levistica"):
    if not text.startswith(f"pid/{pid} = {{\n"):
        raise ValueError("Unexpected PID domain")
    origin = re.search(r"^\toriginator = (.+)$", text, re.M)
    creator = re.search(rf"^\tcreator = {re.escape(creator_name)}\[(\d+)\]$", text, re.M)
    if not origin or pathlib.Path(origin[1]).resolve() != pathlib.Path(app).resolve():
        raise ValueError("Domain originator is not this checkout's app")
    if not creator or int(creator[1]) != pid:
        raise ValueError("Domain creator does not match the app PID")
    section = re.search(r"^\tservices = \{\n(.*?)^\t\}", text, re.M | re.S)
    if not section:
        raise ValueError("Missing services section; attribution unavailable")
    services = []
    for line in section[1].splitlines():
        if not line.strip():
            continue
        row = re.fullmatch(r"\s*(\d+)\s+\S+\s+([A-Za-z0-9_.-]+)\s*", line)
        if not row:
            raise ValueError("Unrecognized service row; attribution unavailable")
        if int(row[1]) > 0:
            services.append({"pid": int(row[1]), "service": row[2]})
    return services


@functools.lru_cache(maxsize=1)
def _pidpath_function():
    if sys.platform != "darwin":
        raise OSError("Kernel executable lookup requires macOS")
    function = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True).proc_pidpath
    function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    function.restype = ctypes.c_int
    return function


def process_executable_path(pid):
    """Read the public kernel path, never mutable argv[0] or ps display names."""
    if type(pid) is not int or pid <= 0:
        raise ValueError("Expected a positive process ID")
    buffer = ctypes.create_string_buffer(4096)  # PROC_PIDPATHINFO_MAXSIZE
    ctypes.set_errno(0)
    length = _pidpath_function()(pid, buffer, len(buffer))
    if length <= 0:
        raise OSError(ctypes.get_errno(), "Kernel executable lookup failed")
    path = buffer.value.decode("utf-8", errors="strict")
    if length >= len(buffer) or not pathlib.Path(path).is_absolute():
        raise ValueError("Invalid kernel executable path")
    return path


def identities(pids, query=None):
    query = run if query is None else query
    text = query(["/bin/ps", "-p", ",".join(map(str, pids)), "-o", "pid=,lstart="])
    result = {}
    for line in text.splitlines():
        fields = line.strip().split()
        if len(fields) != 6 or int(fields[0]) in result:
            raise ValueError("Unrecognized ps identity row")
        result[int(fields[0])] = {"started": " ".join(fields[1:6])}
    if set(result) != set(pids):
        raise ValueError("Process identity set changed; missing PIDs: " +
                         ",".join(map(str, sorted(set(pids) - set(result)))))
    for pid in result:
        result[pid]["executable"] = process_executable_path(pid)
    return result


def has_path_argument(text, flag, path):
    return re.search(r"(?<!\S)" + re.escape(flag + str(path)) + r"(?=\s|$)", text) is not None


def descendants(rows, root):
    """Follow explicit parent relationships; never include namesake processes."""
    result = {root}
    while True:
        expanded = result | {pid for pid, parent in rows if parent in result}
        if expanded == result:
            return result
        result = expanded


def live_descendants(rows, root):
    members = descendants([(pid, parent) for pid, parent, state in rows], root)
    exited = {pid for pid, parent, state in rows if state.startswith("Z") and pid in members}
    if root in exited:
        raise ValueError("Chrome root has exited")
    return members - exited, exited


def snapshot(pid, app=APP, binary=BINARY, chrome_profile=None, deadline=None):
    def query(args):
        if deadline is None:
            return run(args)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('Attribution deadline expired')
        return run(args, timeout=min(30, remaining))

    creator = "Google Chrome" if chrome_profile else "Levistica"
    services = parse_domain(query(["/bin/launchctl", "print", f"pid/{pid}"]), pid, app, creator)
    for service in services:
        text = query(["/bin/launchctl", "print", f"pid/{pid}/{service['service']}"])
        if not re.search(rf"^\tdomain = pid/{pid}(?:\s|$)", text, re.M):
            raise ValueError("Service is outside the app's PID domain")
        actual = re.search(r"^\tpid = (\d+)$", text, re.M)
        if not actual or int(actual[1]) != service["pid"]:
            raise ValueError("Service PID changed during attribution")
    process_ids = sorted({pid, *(s["pid"] for s in services)})
    exited = set()
    checked_identity = {}
    if chrome_profile:
        root_args = query(["/bin/ps", "-p", str(pid), "-o", "args="])
        if not has_path_argument(root_args, "--user-data-dir=", chrome_profile):
            raise ValueError("Chrome root does not use the isolated profile")
        rows = []
        detached = []
        for line in query(["/bin/ps", "-axo", "pid=,ppid=,stat=,ucomm="]).splitlines():
            fields = line.strip().split(None, 3)
            if len(fields) != 4:
                raise ValueError("Unrecognized process table")
            child, parent = map(int, fields[:2])
            rows.append((child, parent, fields[2]))
            if not fields[2].startswith("Z") and fields[3].startswith("chrome_crashpad"):
                uid = query(["/bin/ps", "-p", str(child), "-o", "uid="]).strip()
                if uid != str(os.getuid()):
                    continue
                candidate = identities([child], query=query)[child]
                path = pathlib.Path(candidate["executable"]).resolve()
                if not path.is_relative_to(app.resolve()) or path.name != "chrome_crashpad_handler":
                    continue
                args = query(["/bin/ps", "-p", str(child), "-o", "args="])
                if has_path_argument(args, "--database=", chrome_profile / "Crashpad"):
                    detached.append(child)
                    checked_identity[child] = candidate
        children, exited = live_descendants(rows, pid)
        child_identity = identities(sorted(children), query=query)
        unexpected = [item["executable"] for item in child_identity.values()
                      if not pathlib.Path(item["executable"]).resolve().is_relative_to(app.resolve())]
        if unexpected:
            raise ValueError("Unexpected Chrome descendant executable: " + repr(unexpected))
        checked_identity.update(child_identity)
        process_ids = sorted(set(process_ids) | children | set(detached))
    identity = identities(process_ids, query=query)
    if any(identity.get(child) != item for child, item in checked_identity.items()):
        raise ValueError("Chrome identity changed during attribution")
    if pathlib.Path(identity[pid]["executable"]).resolve() != binary.resolve():
        raise ValueError("PID no longer refers to this checkout's Release app")
    return {"services": sorted(services, key=lambda s: s["service"]), "identities": identity,
            "exited_descendant_pids": sorted(exited)}


def metrics(document, expected):
    if document.get("bytes per unit") != 1 or document.get("unit") not in ("byte", "bytes"):
        raise ValueError("Footprint JSON is not in bytes")
    values = {}
    for process in document.get("processes", []):
        pid = process.get("pid")
        if pid not in expected or pid in values:
            raise ValueError("Unexpected or duplicate PID in footprint JSON")
        value = process.get("auxiliary", {}).get("phys_footprint")
        values[pid] = value if type(value) is int and value >= 0 else None
    missing = sorted(pid for pid in expected if values.get(pid) is None)
    return values, missing


def find_app(binary=BINARY, chrome_profile=None):
    matches = []
    for row in run(["/bin/ps", "-axo", "pid=,comm="]).splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and fields[1] == str(binary):
            pid = int(fields[0])
            if chrome_profile and not has_path_argument(run(["/bin/ps", "-p", str(pid), "-o", "args="]), "--user-data-dir=", chrome_profile):
                continue
            matches.append(pid)
    if len(matches) != 1:
        raise ValueError("Start exactly one matching app (Release Levistica, or Chrome with the isolated profile)")
    return matches[0]


def role(pid, root_pid, services):
    if pid == root_pid:
        return "UI"
    names = [s["service"] for s in services if s["pid"] == pid]
    for name in names:
        for kind in ("WebContent", "Networking", "GPU"):
            if name.startswith("com.apple.WebKit." + kind):
                return kind
    return "owned-XPC-helper"


def attribution_change(before, after):
    """Only live membership/identity affects validity; retain exited changes separately."""
    old, new = before["identities"], after["identities"]
    old_services = {(s["pid"], s["service"]) for s in before["services"]}
    new_services = {(s["pid"], s["service"]) for s in after["services"]}
    change = {
        "live_added": sorted(new.keys() - old.keys()),
        "live_removed": sorted(old.keys() - new.keys()),
        "identity_changed": sorted(p for p in old.keys() & new.keys() if old[p] != new[p]),
        "services_added": sorted(new_services - old_services),
        "services_removed": sorted(old_services - new_services),
        "exited_added": sorted(set(after["exited_descendant_pids"]) - set(before["exited_descendant_pids"])),
        "exited_removed": sorted(set(before["exited_descendant_pids"]) - set(after["exited_descendant_pids"])),
    }
    stable = not any(change[key] for key in (
        "live_added", "live_removed", "identity_changed", "services_added", "services_removed"))
    return stable, change


def wait_for_stable_attribution(read_snapshot, check_conditions, root_pid, seconds, timeout,
                                evidence, interval=5, clock=None, sleep=None):
    """Require a continuous live-attribution window within one fixed deadline.

    read_snapshot receives the absolute deadline and must bound its I/O to it.
    Only successful child/service changes reset the window; failed verification
    or a changed root aborts. No footprint is taken or retried here.
    """
    if not (0 < seconds <= 120 and seconds <= timeout <= 300 and 0 < interval <= seconds):
        raise ValueError('Invalid attribution readiness bounds')
    clock = time.monotonic if clock is None else clock
    sleep = time.sleep if sleep is None else sleep
    started = clock()
    deadline = started + timeout
    evidence.update(status='waiting', checks=0, changes=[], required_seconds=seconds, timeout_seconds=timeout)
    baseline = None
    stable_since = started
    root_identity = None
    try:
        while True:
            check_conditions()
            current = read_snapshot(deadline)
            now = clock()
            evidence['checks'] += 1
            evidence['elapsed_seconds'] = now - started
            if now > deadline:
                raise TimeoutError('Attribution readiness exceeded its deadline')
            if baseline is None:
                root_identity = current['identities'].get(root_pid)
                if root_identity is None:
                    raise ValueError('Attribution readiness has no root identity')
                baseline = current
                stable_since = now
            else:
                if current['identities'].get(root_pid) != root_identity:
                    raise ValueError('Root identity changed during attribution readiness')
                stable, change = attribution_change(baseline, current)
                if not stable:
                    evidence['changes'].append({'elapsed_seconds': now - started, **change})
                    baseline = current
                    stable_since = now
            evidence['stable_seconds'] = now - stable_since
            if now - stable_since >= seconds:
                evidence['status'] = 'ready'
                return current
            if now >= deadline:
                raise TimeoutError('Attribution readiness did not stabilize before its deadline')
            sleep(min(interval, deadline - now, seconds - (now - stable_since)))
    except (ValueError, OSError, subprocess.SubprocessError):
        evidence['status'] = 'failed'
        evidence['elapsed_seconds'] = clock() - started
        raise


@functools.cache
def sleep_contract():
    spec = importlib.util.spec_from_file_location('sleep_contract', pathlib.Path(__file__).with_name('sleep-state.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_fixture(current, original=None, now=None):
    """Refuse stale/paused video while retaining the fixed-document contract."""
    # Only the original single-document fixture has no kind field. A new
    # workload must define its own checks rather than inherit that contract.
    if 'kind' in current and current['kind'] not in (
            'manual-sleep', 'manual-sleep-cycle', 'documents', 'cross-site-documents', 'video'):
        raise ValueError('Unsupported fixture kind')
    if current.get('kind') == 'manual-sleep':
        sleep_contract().check(current, original, check_fixture, now=now)
        return
    if current.get('kind') == 'manual-sleep-cycle':
        sleep_contract().check_cycle(current, original, check_fixture, now=now)
        return
    if current.get('kind') in ('documents', 'cross-site-documents'):
        now = time.monotonic() if now is None else now
        docs = current.get('documents', {})
        count = current.get('expected_tabs')
        allowed = (5, 20) if current['kind'] == 'cross-site-documents' else (5,)
        if type(count) is not int or count not in allowed:
            raise ValueError('Unsupported document count')
        keys = {str(i) for i in range(1, count + 1)}
        if set(docs) != keys or not current.get('ready_monotonic') or type(current.get('loads')) is not int or current['loads'] != count:
            raise ValueError('Every expected document must be visited and loaded once')
        if sum(d.get('visibility') == 'visible' for d in docs.values()) != 1:
            raise ValueError('Exactly one document must be visible')
        for d in docs.values():
            if d.get('seenVisible') is not True or d.get('complete') is not True or d.get('sections') != 240 or not 0 <= now - d.get('reported_monotonic', 0) <= 15:
                raise ValueError('A document is incomplete, unvisited, or no longer reporting')
        if current['kind'] == 'cross-site-documents':
            urls, origins = current.get('urls', {}), current.get('origins', {})
            hashes = current.get('document_hashes', {})
            streams = current.get('stream_connections', {})
            if (current.get('transport') != 'same-origin-sse-v1' or current.get('invalid_reason')
                    or not current.get('run_id') or set(urls) != keys or set(origins) != keys
                    or set(hashes) != keys or set(streams) != keys
                    or any(type(streams[key]) is not int or streams[key] != 1 for key in keys)
                    or docs[str(count)].get('visibility') != 'visible'
                    or len({(d.get('width'), d.get('height'), d.get('dpr')) for d in docs.values()}) != 1):
                raise ValueError('Cross-site document workload is incomplete or reconnected')
            ports = set()
            for key in keys:
                expected_host = f'document-{key}.localhost'
                parsed = urllib.parse.urlsplit(urls[key])
                ports.add(parsed.port)
                if (parsed.scheme != 'http' or parsed.hostname != expected_host or parsed.username is not None
                        or parsed.password is not None or not parsed.port or parsed.path != '/document/' + key
                        or parsed.query or parsed.fragment or origins[key] != f'http://{expected_host}:{parsed.port}'
                        or docs[key].get('origin') != origins[key]
                        or type(docs[key].get('pulse')) is not int or docs[key]['pulse'] <= 0
                        or not isinstance(hashes[key], str) or not re.fullmatch(r'[0-9a-f]{64}', hashes[key])):
                    raise ValueError('Document host, origin, hash, or pulse is invalid')
            if len(ports) != 1:
                raise ValueError('Cross-site documents must use the same loopback listener')
            if original is not None and any(current.get(key) != original.get(key) for key in (
                    'transport', 'run_id', 'urls', 'origins', 'stream_connections')):
                raise ValueError('Cross-site document identity changed')
            if original is not None and any(docs[key]['pulse'] < original['documents'][key]['pulse'] for key in keys):
                raise ValueError('Cross-site document pulse moved backwards')
        if original is not None:
            if any(current.get(k) != original.get(k) for k in ['kind', 'expected_tabs', 'document_hashes', 'loads', 'url', 'ready_monotonic']):
                raise ValueError('Document workload changed')
            for key, d in docs.items():
                if any(d.get(k) != original['documents'][key].get(k) for k in ['instance', 'width', 'height', 'dpr', 'visibility']):
                    raise ValueError('Document instance, viewport, or selection changed')
        return
    if current.get('kind') != 'video':
        if not current.get('ready_monotonic') or current.get('viewport', {}).get('sections') != 240 or current.get('viewport', {}).get('visibility') != 'visible':
            raise ValueError('Fixture must report a complete, visible document')
        if original is not None and current != original:
            raise ValueError('Fixture changed after readiness')
        return
    now = time.monotonic() if now is None else now
    fixed = ['kind', 'media_sha256', 'media_bytes', 'document_sha256', 'loads', 'url', 'ready_monotonic']
    if not current.get('ready_monotonic') or (original is not None and any(current.get(k) != original.get(k) for k in fixed)):
        raise ValueError('Video fixture changed or has not started')
    p = current.get('playback', {})
    if any(not 0 <= now - current.get(k, 0) <= 3 for k in ['last_report_monotonic', 'last_progress_monotonic']):
        raise ValueError('Video playback report is stale or has stopped progressing')
    if p.get('paused') is not False or p.get('ended') is not False or p.get('readyState', 0) < 2 or p.get('visibility') != 'visible' or p.get('muted') is not True or p.get('playbackRate') != 1 or (p.get('videoWidth'), p.get('videoHeight')) != (1280, 720):
        raise ValueError('Video is not visibly playing at the required dimensions and rate')
    if original is not None and any(p.get(k) != original['playback'].get(k) for k in ['width', 'height', 'dpr']):
        raise ValueError('Video viewport changed')


def validate_measurement_signing(info, entitlements):
    if (info.get('CFBundleIdentifier') != 'dev.fomalhaut16.Levistica.measurement'
            or entitlements.get('com.apple.security.get-task-allow') is True
            or entitlements.get('com.apple.security.app-sandbox') is not True):
        raise ValueError('Measurement requires the isolated bundle, Sandbox, and no debugger entitlement')


def validate_native_build_source(info, checkout_revision, worktree_dirty):
    revision = info.get('LevisticaSourceRevision')
    state = info.get('LevisticaSourceState')
    if (not isinstance(revision, str) or not re.fullmatch(r'[0-9a-f]{40}', revision)
            or revision != checkout_revision or state != 'clean' or worktree_dirty):
        raise ValueError('Native app source is unverified or differs from the clean checkout; rebuild with script/build_and_run.sh')
    return {'revision': revision, 'state': state}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ready-file", type=pathlib.Path, help="Optional synthetic fixture readiness state")
    parser.add_argument("--ready-delay", type=float, default=60, help="Minimum seconds after readiness (default: 60)")
    parser.add_argument('--sleep-baseline', type=pathlib.Path, help='Validated five-page lifecycle checkpoint')
    parser.add_argument('--sleep-cycle-checkpoint', type=pathlib.Path, help='Validated all-loaded history for sleep cycle 1..5')
    parser.add_argument('--sleeping-documents', default='', help='Empty or 1,2,3,4; requires sleep-baseline')
    parser.add_argument("--browser", choices=["levistica", "levistica-measurement", "chrome"], default="levistica")
    parser.add_argument("--chrome-profile", type=pathlib.Path)
    parser.add_argument("--label", required=True, help="Non-private state label, never a URL")
    parser.add_argument("--loaded-pages", type=int, required=True)
    parser.add_argument("--total-tabs", type=int, help="Total tab count, including unloaded tabs; omit if unknown")
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument('--require-ac-power', action='store_true',
                        help='Reject non-AC or unknown power at preparation and capture checkpoints')
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument('--stable-attribution-seconds', type=float, default=0,
                        help='Optional continuous PID/service stability window (1..120 seconds)')
    parser.add_argument('--attribution-timeout', type=float, default=90,
                        help='Fixed readiness deadline, including settling (up to 300 seconds)')
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", args.label):
        parser.error("Use a short lowercase label without URLs or private data")
    if not 0 <= args.loaded_pages <= 1000:
        parser.error("loaded-pages must be 0..1000")
    if args.total_tabs is not None and not max(1, args.loaded_pages) <= args.total_tabs <= 1000:
        parser.error("total-tabs must be 1..1000 and at least loaded-pages")
    if not 1 <= args.samples <= 10 or not 0 <= args.interval <= 60:
        parser.error("samples must be 1..10; interval must be 0..60 seconds")
    if not 0 <= args.ready_delay <= 600 or (not args.ready_file and args.ready_delay != 60):
        parser.error("ready-delay must be 0..600 seconds and requires ready-file")
    if not (args.stable_attribution_seconds == 0 or 1 <= args.stable_attribution_seconds <= 120):
        parser.error('stable-attribution-seconds must be 0 or 1..120')
    if args.stable_attribution_seconds:
        if (not args.ready_file or args.browser not in ('chrome', 'levistica-measurement')
                or not args.stable_attribution_seconds <= args.attribution_timeout <= 300):
            parser.error('Attribution readiness requires an isolated browser, ready-file, and a bounded timeout')
    elif args.attribution_timeout != 90:
        parser.error('attribution-timeout requires stable-attribution-seconds')
    power_preparation_checks = []
    if args.require_ac_power:
        try:
            record_ac_power(power_preparation_checks, 'preflight')
        except PowerConditionError as error:
            parser.error(str(error))
    if args.sleeping_documents and not args.sleep_baseline:
        parser.error('sleeping-documents requires sleep-baseline')
    sleeping = args.sleeping_documents.split(',') if args.sleeping_documents else []
    checkpoint = None
    if args.sleep_cycle_checkpoint:
        if (args.sleep_baseline or args.sleeping_documents or not args.ready_file
                or args.browser != 'levistica' or args.total_tabs != 5 or args.loaded_pages != 1
                or args.ready_delay != 120):
            parser.error('Sleep cycles require only a cycle checkpoint, Levistica, five tabs, one loaded page, and ready-delay 120')
        checkpoint = json.loads(args.sleep_cycle_checkpoint.read_text())
    if args.sleep_baseline:
        if (not args.ready_file or args.browser != 'levistica' or args.total_tabs != 5
                or sleeping not in ([], ['1', '2', '3', '4'])
                or args.loaded_pages != 5 - len(sleeping) or args.ready_delay != 120):
            parser.error('Manual sleep requires Levistica, five total tabs, matching loaded count, and ready-delay 120')
        checkpoint = json.loads(args.sleep_baseline.read_text())
    phase_started = time.monotonic()

    def read_fixture():
        state = json.loads(args.ready_file.read_text())
        if checkpoint is None:
            return state
        pressure = int(run(['/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level']).strip())
        if args.sleep_cycle_checkpoint:
            return {'kind': 'manual-sleep-cycle', 'ready_monotonic': phase_started,
                    'cycle_checkpoint': checkpoint, 'memory_pressure_level': pressure, 'workload': state}
        return {'kind': 'manual-sleep', 'ready_monotonic': phase_started,
                'sleep_checkpoint': checkpoint, 'sleeping_documents': sleeping,
                'memory_pressure_level': pressure, 'workload': state}
    app, binary, profile = APP, BINARY, None
    measurement_storage = None
    if args.browser == "chrome":
        if not args.chrome_profile:
            parser.error("Chrome requires an isolated --chrome-profile")
        profile = args.chrome_profile.resolve()
        if not profile.is_relative_to(ROOT / ".local") or not profile.is_dir():
            parser.error("The isolated Chrome profile must exist inside this checkout's .local")
        app = pathlib.Path("/Applications/Google Chrome.app")
        binary = app / "Contents/MacOS/Google Chrome"
    elif args.chrome_profile:
        parser.error("--chrome-profile requires --browser chrome")
    if args.browser == "levistica-measurement":
        if checkpoint is not None:
            parser.error("Measurement does not support the manual-sleep comparison")
        app = ROOT / '.local/MeasurementDerivedData/Build/Products/Release/Levistica.app'
        binary = app / 'Contents/MacOS/Levistica'
        run(['/usr/bin/codesign', '--verify', '--strict', str(app)])
        with (app / 'Contents/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        entitlements = plistlib.loads(run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)]).encode())
        validate_measurement_signing(info, entitlements)
        spec = importlib.util.spec_from_file_location('app_processes', ROOT / 'script/check-app-processes.py')
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        checked = guard.check_snapshot(guard.run_ps(['-axo', 'pid=,comm=']), ROOT,
                                       guard.describe_process, os.getuid(), only='Measurement')
        if checked != [find_app(binary)]:
            raise ValueError('Measurement app identity is unavailable')
        spec = importlib.util.spec_from_file_location('measurement_store', ROOT / 'script/measurement-store.py')
        stores = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(stores)
        measurement_storage = stores.selection(stores.runtime_flags(checked[0]))
    fixture = None
    sleep_guard_file = None
    sleep_observations = []
    if args.ready_file:
        fixture = read_fixture()
        ready = fixture.get("ready_monotonic")
        try:
            check_fixture(fixture)
        except ValueError as error:
            parser.error(str(error))
        remaining = ready + args.ready_delay - time.monotonic()
        if remaining > 0:
            print(f"Waiting {remaining:.1f}s after fixture readiness", flush=True)
            if checkpoint is not None:
                parent = ROOT / '.local/artifacts/memory'
                parent.mkdir(parents=True, exist_ok=True)
                sleep_guard_file = pathlib.Path(tempfile.mkdtemp(prefix=args.label + '.guard.', dir=parent)) / 'guard.json'
                print(f'Sleep phase guard: {sleep_guard_file}', flush=True)
            while (remaining := ready + args.ready_delay - time.monotonic()) > 0:
                if args.require_ac_power:
                    record_ac_power(power_preparation_checks, 'settling')
                if checkpoint is not None:
                    observed = read_fixture()
                    observation = {'monotonic': time.monotonic(), 'state': observed, 'valid': False}
                    try:
                        check_fixture(observed, fixture)
                        observation['valid'] = True
                    except ValueError as error:
                        observation['error'] = str(error)
                        raise
                    finally:
                        sleep_observations.append(observation)
                        sleep_guard_file.write_text(json.dumps(sleep_observations, indent=2) + '\n')
                time.sleep(min(remaining, 5 if checkpoint is not None or args.require_ac_power else 30))
    if args.require_ac_power:
        record_ac_power(power_preparation_checks, 'before_target_inspection')
    pid = find_app(binary, profile)
    output_parent = ROOT / ".local/artifacts/memory"
    output_parent.mkdir(parents=True, exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix=args.label + ".", dir=output_parent))
    record = {
        "schema": 2, "label": args.label,
        "ac_power_required": args.require_ac_power,
        "power_preparation_checks": power_preparation_checks,
        "aborted_for_power_condition": False,
        "attribution_readiness_seconds": args.stable_attribution_seconds,
        "attribution_readiness_timeout_seconds": args.attribution_timeout if args.stable_attribution_seconds else None, "fixture": fixture, "ready_delay_seconds": args.ready_delay if fixture else None,
        "sleep_guard_file": str(sleep_guard_file) if sleep_guard_file else None,
        "loaded_pages": args.loaded_pages, "total_tabs": args.total_tabs,
        "browser": args.browser, "storage_mode": measurement_storage["mode"] if measurement_storage else "launch configuration", "measurement_store_id": measurement_storage["storeID"] if measurement_storage else None, "pid": pid, "source_head_at_sampling": run(["git", "rev-parse", "HEAD"]).strip(),
        "measurement_metadata_persistent": measurement_storage["metadataPersistent"] if measurement_storage else False,
        "measurement_script_sha256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "worktree_dirty": bool(run(["git", "status", "--porcelain", "--untracked-files=normal"]).strip()),
        "os_version": run(["/usr/bin/sw_vers", "-productVersion"]).strip(),
        "os_build": run(["/usr/bin/sw_vers", "-buildVersion"]).strip(),
        "architecture": run(["/usr/bin/uname", "-m"]).strip(),
        "scope": "UI plus verified PID-domain XPC; Chrome also includes descendants and profile-matched Crashpad",
        "limits": ["Shared memory can be charged to multiple processes; sum is not exclusive RAM.",
                   "Shared system services outside this PID domain are excluded.",
                   "This snapshot tool alone does not establish comparison conditions or a performance target.",
                   "A single WKWebView can retain multiple WebContent processes, including cached or prewarmed pages."],
        "samples": [],
    }
    if args.require_ac_power:
        record['limits'].append('Power is checked at preparation, stability and capture boundaries; brief changes between checks can be missed.')
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    record["bundle"] = {key: info.get(key) for key in (
        "CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString",
        "DTXcodeBuild", "DTSDKName", "LSMinimumSystemVersion")}
    record['binary_build_source'] = (validate_native_build_source(
        info, record['source_head_at_sampling'], record['worktree_dirty']) if args.browser != 'chrome' else None)
    record["power_source"] = run(["/usr/bin/pmset", "-g", "batt"]).splitlines()[0]
    record["system_before"] = {
        "swap": run(["/usr/sbin/sysctl", "vm.swapusage"]).strip(),
        "memory_pressure_level": run(["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).strip(),
        "vm_stat": run(["/usr/bin/vm_stat"]),
    }
    for index in range(args.samples):
        sample = {"time_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "valid": False}
        if args.require_ac_power:
            sample['power_checks'] = []
        if fixture:
            sample["seconds_after_ready"] = time.monotonic() - fixture["ready_monotonic"]
        try:
            if args.ready_file:
                sample['fixture_before'] = read_fixture()
                check_fixture(sample['fixture_before'], fixture)
            readiness = None
            if args.stable_attribution_seconds:
                sample['attribution_readiness'] = {}
                def check_conditions():
                    check_fixture(read_fixture(), fixture)
                    if args.require_ac_power:
                        record_ac_power(sample['power_checks'], 'attribution_stability')
                readiness = wait_for_stable_attribution(
                    lambda deadline: snapshot(pid, app, binary, profile, deadline=deadline),
                    check_conditions, pid,
                    args.stable_attribution_seconds, args.attribution_timeout,
                    sample['attribution_readiness'], interval=min(5, args.stable_attribution_seconds))
            before = snapshot(pid, app, binary, profile)
            sample['attribution_before'] = before
            if readiness is not None and not attribution_change(readiness, before)[0]:
                raise ValueError('Attribution changed after the readiness window')
            if measurement_storage and measurement_storage['metadataPersistent']:
                sample['metadata_before'] = stores.metadata_snapshot(pid, measurement_storage['storeID'])
                if args.total_tabs is not None and sample['metadata_before']['tabCount'] != args.total_tabs:
                    raise ValueError('Saved tab count differs from the measurement condition')
            pids = sorted(before["identities"])
            raw = output / f"footprint-{index + 1}.json"
            if readiness is not None:
                sample['fixture_before'] = read_fixture()
                check_fixture(sample['fixture_before'], fixture)
            if args.require_ac_power:
                record_ac_power(sample['power_checks'], 'before_capture')
            sample['capture_started_time_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            if fixture:
                sample['capture_started_seconds_after_ready'] = time.monotonic() - fixture['ready_monotonic']
            # The standard tool accepts explicit positional PID lists. Never query all processes.
            run(["/usr/bin/footprint", "-f", "bytes", "-j", str(raw), *map(str, pids)])
            if args.require_ac_power:
                record_ac_power(sample['power_checks'], 'after_capture')
            document = json.loads(raw.read_text())
            values, missing = metrics(document, pids)
            after = snapshot(pid, app, binary, profile)
            if measurement_storage and measurement_storage['metadataPersistent']:
                sample['metadata_after'] = stores.metadata_snapshot(pid, measurement_storage['storeID'])
                if sample['metadata_before'] != sample['metadata_after']:
                    raise ValueError('Persistent measurement metadata changed during capture')
            sample["attribution_after"] = after
            if args.ready_file:
                sample['fixture_after'] = read_fixture()
                check_fixture(sample['fixture_after'], fixture)
            sample["exited_descendant_pids"] = before["exited_descendant_pids"]
            sample["identity_stable"], sample["attribution_change"] = attribution_change(before, after)
            sample["missing_pids"] = missing
            sample["tool_errors"] = document.get("errors", [])
            sample["tool_warnings"] = document.get("warnings", [])
            sample["processes"] = [
                {"pid": p, "role": ("Chrome-child-or-helper" if profile and p != pid else role(p, pid, before["services"])), **before["identities"][p],
                 "services": [s["service"] for s in before["services"] if s["pid"] == p],
                 "physical_footprint_bytes": values.get(p)} for p in pids
            ]
            sample["valid"] = sample["identity_stable"] and not missing and not sample["tool_errors"]
            sample["sum_attributed_physical_footprints_bytes"] = sum(values.values()) if sample["valid"] else None
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            # Error classes and fixed diagnostics only: never dump a subprocess's environment.
            sample["error"] = str(error) if isinstance(error, ValueError) else type(error).__name__
            if isinstance(error, PowerConditionError):
                record['aborted_for_power_condition'] = True
        if fixture:
            sample["completed_seconds_after_ready"] = time.monotonic() - fixture["ready_monotonic"]
        record["samples"].append(sample)
        (output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
        print(f"Sample {index + 1}: valid={sample['valid']}", flush=True)
        if record['aborted_for_power_condition']:
            break
        if index + 1 < args.samples:
            time.sleep(args.interval)
    valid = [s["sum_attributed_physical_footprints_bytes"] for s in record["samples"] if s["valid"]]
    record["valid_sample_count"] = len(valid)
    record["median_sum_attributed_bytes"] = statistics.median(valid) if valid else None
    record["range_sum_attributed_bytes"] = [min(valid), max(valid)] if valid else None
    (output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"Local evidence: {output / 'result.json'}")
    return 0 if len(valid) == args.samples else 1


if __name__ == "__main__":
    raise SystemExit(main())
