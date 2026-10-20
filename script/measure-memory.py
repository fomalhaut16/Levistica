#!/usr/bin/env python3
"""Read-only, local-only footprint snapshots for this checkout's Release app.

Attribution uses `launchctl print pid/PID` services, not PPID or process-name guesses.
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


def parse_domain(text, pid, app):
    if not text.startswith(f"pid/{pid} = {{\n"):
        raise ValueError("Unexpected PID domain")
    origin = re.search(r"^\toriginator = (.+)$", text, re.M)
    creator = re.search(r"^\tcreator = Levistica\[(\d+)\]$", text, re.M)
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


def snapshot(pid):
    services = parse_domain(run(["/bin/launchctl", "print", f"pid/{pid}"]), pid, APP)
    for service in services:
        text = run(["/bin/launchctl", "print", f"pid/{pid}/{service['service']}"])
        if not re.search(rf"^\tdomain = pid/{pid}(?:\s|$)", text, re.M):
            raise ValueError("Service is outside the app's PID domain")
        actual = re.search(r"^\tpid = (\d+)$", text, re.M)
        if not actual or int(actual[1]) != service["pid"]:
            raise ValueError("Service PID changed during attribution")
    process_ids = sorted({pid, *(s["pid"] for s in services)})
    identity = identities(process_ids)
    if pathlib.Path(identity[pid]["executable"]).resolve() != BINARY.resolve():
        raise ValueError("PID no longer refers to this checkout's Release app")
    return {"services": sorted(services, key=lambda s: s["service"]), "identities": identity}


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


def find_app():
    matches = []
    for row in run(["/bin/ps", "-axo", "pid=,comm="]).splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and fields[1] == str(BINARY):
            matches.append(int(fields[0]))
    if len(matches) != 1:
        raise ValueError("Start exactly one Release app via CONFIGURATION=Release ./script/build_and_run.sh")
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
    parser.add_argument("--label", required=True, help="Non-private state label, never a URL")
    parser.add_argument("--loaded-pages", type=int, choices=[0, 1], required=True)
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--interval", type=float, default=5)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", args.label):
        parser.error("Use a short lowercase label without URLs or private data")
    if not 1 <= args.samples <= 10 or not 0 <= args.interval <= 60:
        parser.error("samples must be 1..10; interval must be 0..60 seconds")
    pid = find_app()
    output_parent = ROOT / ".local/artifacts/memory"
    output_parent.mkdir(parents=True, exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix=args.label + ".", dir=output_parent))
    record = {
        "schema": 1, "label": args.label, "loaded_pages": args.loaded_pages,
        "pid": pid, "source_head_at_sampling": run(["git", "rev-parse", "HEAD"]).strip(),
        "binary_sha256": hashlib.sha256(BINARY.read_bytes()).hexdigest(),
        "worktree_dirty": bool(run(["git", "status", "--porcelain", "--untracked-files=no"]).strip()),
        "os_version": run(["/usr/bin/sw_vers", "-productVersion"]).strip(),
        "os_build": run(["/usr/bin/sw_vers", "-buildVersion"]).strip(),
        "architecture": run(["/usr/bin/uname", "-m"]).strip(),
        "scope": "UI plus verified running XPC services in this app's PID domain",
        "limits": ["Shared memory can be charged to multiple processes; sum is not exclusive RAM.",
                   "Shared system services outside this PID domain are excluded.",
                   "This snapshot tool alone does not establish comparison conditions or a performance target.",
                   "A single WKWebView can retain multiple WebContent processes, including cached or prewarmed pages."],
        "samples": [],
    }
    with (APP / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    record["bundle"] = {key: info.get(key) for key in (
        "CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString",
        "DTXcodeBuild", "DTSDKName", "LSMinimumSystemVersion")}
    for index in range(args.samples):
        sample = {"time_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "valid": False}
        try:
            before = snapshot(pid)
            pids = sorted(before["identities"])
            raw = output / f"footprint-{index + 1}.json"
            # The standard tool accepts explicit positional PID lists. Never query all processes.
            run(["/usr/bin/footprint", "-f", "bytes", "-j", str(raw), *map(str, pids)])
            document = json.loads(raw.read_text())
            values, missing = metrics(document, pids)
            after = snapshot(pid)
            sample["identity_stable"] = before == after
            sample["missing_pids"] = missing
            sample["tool_errors"] = document.get("errors", [])
            sample["tool_warnings"] = document.get("warnings", [])
            sample["processes"] = [
                {"pid": p, "role": role(p, pid, before["services"]), **before["identities"][p],
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
