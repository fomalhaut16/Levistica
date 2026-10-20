#!/usr/bin/env python3
"""Read-only, local-only footprint snapshots for Release Levistica or isolated Chrome.

Attribution verifies PID-domain XPC; Chrome also verifies descendants and its isolated Crashpad.
launchctl's human-readable format is not a stable API: parsing fails closed.
Raw launchctl output can contain environment values and is never saved or printed.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import re
import statistics
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / ".local/DerivedData/Build/Products/Release/Levistica.app"
BINARY = APP / "Contents/MacOS/Levistica"


def run(args, timeout=30):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=timeout,
                                   env={**os.environ, "LC_ALL": "C"})


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


def identities(pids):
    text = run(["/bin/ps", "-p", ",".join(map(str, pids)), "-o", "pid=,lstart=,comm="])
    result = {}
    for line in text.splitlines():
        fields = line.strip().split(None, 6)
        if len(fields) != 7:
            raise ValueError("Unrecognized ps identity row")
        result[int(fields[0])] = {"started": " ".join(fields[1:6]), "executable": fields[6]}
    if set(result) != set(pids):
        raise ValueError("A process exited while identities were read")
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


def snapshot(pid, app=APP, binary=BINARY, chrome_profile=None):
    creator = "Google Chrome" if chrome_profile else "Levistica"
    services = parse_domain(run(["/bin/launchctl", "print", f"pid/{pid}"]), pid, app, creator)
    for service in services:
        text = run(["/bin/launchctl", "print", f"pid/{pid}/{service['service']}"])
        if not re.search(rf"^\tdomain = pid/{pid}(?:\s|$)", text, re.M):
            raise ValueError("Service is outside the app's PID domain")
        actual = re.search(r"^\tpid = (\d+)$", text, re.M)
        if not actual or int(actual[1]) != service["pid"]:
            raise ValueError("Service PID changed during attribution")
    process_ids = sorted({pid, *(s["pid"] for s in services)})
    exited = set()
    if chrome_profile:
        root_args = run(["/bin/ps", "-p", str(pid), "-o", "args="])
        if not has_path_argument(root_args, "--user-data-dir=", chrome_profile):
            raise ValueError("Chrome root does not use the isolated profile")
        rows = []
        detached = []
        for line in run(["/bin/ps", "-axo", "pid=,ppid=,stat=,comm="]).splitlines():
            fields = line.strip().split(None, 3)
            if len(fields) != 4:
                raise ValueError("Unrecognized process table")
            child, parent = map(int, fields[:2])
            rows.append((child, parent, fields[2]))
            if not fields[2].startswith("Z") and fields[3].startswith(str(app) + "/") and fields[3].endswith("/chrome_crashpad_handler"):
                args = run(["/bin/ps", "-p", str(child), "-o", "args="])
                if has_path_argument(args, "--database=", chrome_profile / "Crashpad"):
                    detached.append(child)
        children, exited = live_descendants(rows, pid)
        child_identity = identities(sorted(children))
        unexpected = [item["executable"] for item in child_identity.values()
                      if not item["executable"].startswith(str(app) + "/")]
        if unexpected:
            raise ValueError("Unexpected Chrome descendant executable: " + repr(unexpected))
        process_ids = sorted(set(process_ids) | children | set(detached))
    identity = identities(process_ids)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ready-file", type=pathlib.Path, help="Optional synthetic fixture state; wait 60s after readiness")
    parser.add_argument("--browser", choices=["levistica", "chrome"], default="levistica")
    parser.add_argument("--chrome-profile", type=pathlib.Path)
    parser.add_argument("--label", required=True, help="Non-private state label, never a URL")
    parser.add_argument("--loaded-pages", type=int, required=True)
    parser.add_argument("--total-tabs", type=int, help="Total tab count, including unloaded tabs; omit if unknown")
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--interval", type=float, default=5)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", args.label):
        parser.error("Use a short lowercase label without URLs or private data")
    if not 0 <= args.loaded_pages <= 1000:
        parser.error("loaded-pages must be 0..1000")
    if args.total_tabs is not None and not max(1, args.loaded_pages) <= args.total_tabs <= 1000:
        parser.error("total-tabs must be 1..1000 and at least loaded-pages")
    if not 1 <= args.samples <= 10 or not 0 <= args.interval <= 60:
        parser.error("samples must be 1..10; interval must be 0..60 seconds")
    app, binary, profile = APP, BINARY, None
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
    fixture = None
    if args.ready_file:
        fixture = json.loads(args.ready_file.read_text())
        ready = fixture.get("ready_monotonic")
        viewport = fixture.get("viewport", {})
        if not ready or viewport.get("sections") != 240 or viewport.get("visibility") != "visible":
            parser.error("Fixture must report a complete, visible document")
        remaining = ready + 60 - time.monotonic()
        if remaining > 0:
            print(f"Waiting {remaining:.1f}s after fixture readiness", flush=True)
            time.sleep(remaining)
    pid = find_app(binary, profile)
    output_parent = ROOT / ".local/artifacts/memory"
    output_parent.mkdir(parents=True, exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix=args.label + ".", dir=output_parent))
    record = {
        "schema": 1, "label": args.label, "fixture": fixture, "loaded_pages": args.loaded_pages, "total_tabs": args.total_tabs,
        "browser": args.browser, "pid": pid, "source_head_at_sampling": run(["git", "rev-parse", "HEAD"]).strip(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "worktree_dirty": bool(run(["git", "status", "--porcelain", "--untracked-files=no"]).strip()),
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
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    record["bundle"] = {key: info.get(key) for key in (
        "CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString",
        "DTXcodeBuild", "DTSDKName", "LSMinimumSystemVersion")}
    record["power_source"] = run(["/usr/bin/pmset", "-g", "batt"]).splitlines()[0]
    record["system_before"] = {
        "swap": run(["/usr/sbin/sysctl", "vm.swapusage"]).strip(),
        "memory_pressure_level": run(["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).strip(),
        "vm_stat": run(["/usr/bin/vm_stat"]),
    }
    for index in range(args.samples):
        sample = {"time_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "valid": False}
        try:
            if args.ready_file and json.loads(args.ready_file.read_text()) != fixture:
                raise ValueError("Fixture changed after readiness")
            before = snapshot(pid, app, binary, profile)
            pids = sorted(before["identities"])
            raw = output / f"footprint-{index + 1}.json"
            # The standard tool accepts explicit positional PID lists. Never query all processes.
            run(["/usr/bin/footprint", "-f", "bytes", "-j", str(raw), *map(str, pids)])
            document = json.loads(raw.read_text())
            values, missing = metrics(document, pids)
            after = snapshot(pid, app, binary, profile)
            if args.ready_file and json.loads(args.ready_file.read_text()) != fixture:
                raise ValueError("Fixture changed during measurement")
            sample["exited_descendant_pids"] = before["exited_descendant_pids"]
            sample["identity_stable"] = before == after
            sample["missing_pids"] = missing
            sample["tool_errors"] = document.get("errors", [])
            sample["tool_warnings"] = document.get("warnings", [])
            sample["processes"] = [
                {"pid": p, "role": ("Chrome-child-or-helper" if profile and p != pid else role(p, pid, before["services"])), **before["identities"][p],
                 "services": [s["service"] for s in before["services"] if s["pid"] == p],
                 "physical_footprint_bytes": values.get(p)} for p in pids
            ]
            sample["valid"] = before == after and not missing and not sample["tool_errors"]
            sample["sum_attributed_physical_footprints_bytes"] = sum(values.values()) if sample["valid"] else None
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            # Error classes and fixed diagnostics only: never dump a subprocess's environment.
            sample["error"] = str(error) if isinstance(error, ValueError) else type(error).__name__
        record["samples"].append(sample)
        (output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
        print(f"Sample {index + 1}: valid={sample['valid']}", flush=True)
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
