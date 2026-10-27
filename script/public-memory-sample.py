#!/usr/bin/env python3
"""One provisional Measurement footprint, finalized only after its UI trial succeeds."""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import time

ROOT = Path(__file__).resolve().parent.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'script' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


m = load('public_memory_metrics', 'measure-memory.py')
observer = load('public_memory_observer', 'observe-memory.py')


def require_context(context):
    if (context.get('available') is not True or context.get('powerSource') != 'ac'
            or type(context.get('memoryPressureLevel')) is not int or context['memoryPressureLevel'] != 1):
        raise ValueError('Requires known AC power and normal memory pressure')


class Sampler:
    def __init__(self, pid, read_attribution, read_context, read_values, clock=time.monotonic,
                 *, role_for=None, content_role='WebContent'):
        if content_role not in ('WebContent', 'Renderer') or (role_for is not None and not callable(role_for)):
            raise ValueError('Expected an explicit page-process role provider')
        self.pid = pid
        self.read_attribution = read_attribution
        self.read_context = read_context
        self.read_values = read_values
        self.clock = clock
        self.role_for = role_for or (lambda pid, root, snapshot: m.role(pid, root, snapshot['services']))
        self.content_role = content_role
        self.baseline = None
        self.root_identity = None
        self.confirmed_exits = []
        self.stable_since = None
        self.last_check = None
        self.last_context = None
        self.checks = 0
        self.changes = 0
        self.attempts = 0
        self.sample = None

    def tick(self, force=False, deadline=None, *, allow_confirmed_exits=True):
        if not force and self.last_check is not None and self.clock() - self.last_check < 5:
            return
        deadline = min(self.clock() + 3, deadline) if deadline is not None else self.clock() + 3
        context = self.read_context(deadline)
        self.last_context = context
        require_context(context)
        try:
            current = self.read_attribution(deadline)
        except m.ConfirmedExitedChromeDescendants as error:
            if (self.content_role != 'Renderer' or not allow_confirmed_exits or self.attempts
                    or not error.pids or self.pid in error.pids
                    or self.clock() > deadline or len(self.confirmed_exits) >= 64):
                raise
            self.confirmed_exits.append({'pids': list(error.pids), 'atMonotonic': self.clock()})
            self.baseline = None
            self.stable_since = None
            self.last_check = self.clock()
            self.changes += 1
            return
        if self.pid not in current['identities']:
            raise ValueError('Missing root attribution')
        if self.root_identity is not None and current['identities'][self.pid] != self.root_identity:
            raise ValueError('Root identity changed')
        if self.baseline is None:
            self.stable_since = self.clock()
        else:
            if current['identities'][self.pid] != self.baseline['identities'][self.pid]:
                raise ValueError('Root identity changed')
            if (self.clock() - self.last_check > 10
                    or not m.attribution_change(self.baseline, current)[0]):
                self.stable_since = self.clock()
                self.changes += 1
        if self.clock() > deadline:
            raise TimeoutError('Attribution check exceeded deadline')
        if self.root_identity is None:
            self.root_identity = dict(current['identities'][self.pid])
        self.baseline = current
        self.last_check = self.clock()
        self.checks += 1

    def capture(self):
        if self.attempts or self.sample is not None:
            raise ValueError('Only one capture is permitted')
        deadline = self.clock() + 3
        self.tick(force=True, deadline=deadline, allow_confirmed_exits=False)
        stable = self.clock() - self.stable_since
        if stable < 60:
            raise ValueError('Attribution has not been stable for sixty seconds')
        before = self.baseline
        context_before = self.read_context(deadline)
        require_context(context_before)
        pids = sorted(before['identities'])
        if not any(self.role_for(pid, self.pid, before) == self.content_role for pid in pids):
            raise ValueError('Required page-process role is missing: ' + self.content_role)
        started = self.clock()
        self.attempts += 1
        document = self.read_values(pids, deadline)
        values, missing = m.metrics(document, pids)
        after = self.read_attribution(deadline)
        context_after = self.read_context(deadline)
        require_context(context_after)
        if (missing or document.get('errors') or not m.attribution_change(before, after)[0]
                or self.clock() > deadline):
            raise ValueError('Incomplete, changed or overdue footprint')
        self.sample = {'valid': False, 'capturedMonotonic': started, 'completedMonotonic': self.clock(),
                       'recordedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       'stableAttributionSeconds': stable, 'attributionChecks': self.checks,
                       'attributionChanges': self.changes,
                       'systemBefore': context_before, 'systemAfter': context_after,
                       'processes': [{'pid': pid, 'role': self.role_for(pid, self.pid, before),
                                      **before['identities'][pid], 'physicalFootprintBytes': values[pid]}
                                     for pid in pids],
                       'sumAttributedPhysicalFootprintsBytes': sum(values.values())}

    def finish(self):
        if self.sample is None:
            raise ValueError('No provisional footprint')
        old = self.baseline
        self.tick(force=True, allow_confirmed_exits=False)
        if not m.attribution_change(old, self.baseline)[0]:
            raise ValueError('Attribution changed after capture')


def create_sampler(record):
    app = Path(record['executable']).parents[2]
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    entitlements = plistlib.loads(m.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)]).encode())
    m.validate_measurement_signing(info, entitlements)
    stores = load('public_memory_stores', 'measurement-store.py')
    storage = stores.selection(stores.runtime_flags(record['pid']))
    if storage['storeID'] is not None or storage['metadataPersistent']:
        raise ValueError('This pilot requires the default nonpersistent Measurement store')
    helper, helper_source = observer.prepare_helper()
    def read_values(pids, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('No capture time remaining')
        return observer.decode_rusage(m.run([str(helper), *map(str, pids)], timeout=min(1, remaining)), pids)
    sampler = Sampler(record['pid'],
                      lambda deadline: m.snapshot(record['pid'], app, Path(record['executable']), deadline=deadline),
                      observer.system_context, read_values)
    sampler.provenance = {'method': 'proc_pid_rusage RUSAGE_INFO_V4 physical footprint',
                          'helperSourceSHA256': helper_source,
                          'binarySHA256': hashlib.sha256(Path(record['executable']).read_bytes()).hexdigest(),
                          'storage': storage, 'loadedPages': 4, 'totalTabs': 4,
                          'osVersion': m.run(['/usr/bin/sw_vers', '-productVersion']).strip(),
                          'osBuild': m.run(['/usr/bin/sw_vers', '-buildVersion']).strip(),
                          'architecture': m.run(['/usr/bin/uname', '-m']).strip(),
                          'bundle': {key: info.get(key) for key in
                                     ('CFBundleIdentifier', 'CFBundleVersion', 'DTXcodeBuild', 'DTSDKName')},
                          'scope': 'UI plus verified PID-domain services; shared memory may be counted more than once',
                          'limits': ['One isolated public-page pilot, not a browser comparison.',
                                     'Diagnostic UI and observation overhead are included.',
                                     'Five-second attribution checks do not observe every instant.',
                                     'Outside-domain shared services are excluded.']}
    sampler.tick(force=True)
    return sampler


def finalize(directory):
    result = json.loads((directory / 'public-handoff-result.json').read_text())
    summary = json.loads((directory / 'test-summary.json').read_text())
    workload = json.loads((directory / 'deadline-workload.json').read_text())
    counts = [summary.get(k) for k in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')]
    if (workload.get('samplePublicMemory') is not True or workload.get('dryRunPublicHandoff') is not False
            or result.get('success') is not True or result.get('failure') is not None
            or result.get('memorySamplesTaken') != 1 or len(result.get('records', [])) != 2
            or any(type(value) is not int for value in counts) or counts != [1, 1, 0, 0]):
        raise ValueError('The complete isolated UI trial and handoff must succeed')
    sample = result.get('provisionalMemorySample')
    records = result['records']
    handoff = load('public_memory_final_handoff', 'public-readiness-handoff.py')
    handoff.guard.validate(workload)
    handoff.guard.validate_lifetime(workload, 300)
    handoff.validate_snapshot(records[0]['snapshot'])
    handoff.validate_snapshot(records[1]['snapshot'], records[0]['snapshot'])
    if records[0]['snapshot']['pid'] != workload['pid']:
        raise ValueError('Workload and live observations refer to different processes')
    if (not isinstance(sample, dict) or sample.get('valid') is not False
            or not records[0]['receivedMonotonic'] <= sample['capturedMonotonic']
            <= sample['completedMonotonic'] <= records[1]['receivedMonotonic']
            or sample['stableAttributionSeconds'] < 60
            or result['sourceRevision'] != m.run(['git', 'rev-parse', 'HEAD']).strip()):
        raise ValueError('Capture is not bounded by the live observations and current source')
    require_context(sample['systemBefore'])
    require_context(sample['systemAfter'])
    rows = sample['processes']
    pids = [row['pid'] for row in rows]
    values = [row['physicalFootprintBytes'] for row in rows]
    if (len(pids) != len(set(pids)) or workload['pid'] not in pids
            or not any(row.get('role') == 'WebContent' for row in rows)
            or not any(row['pid'] == workload['pid'] and row.get('role') == 'UI' for row in rows)
            or any(type(value) is not int or not 0 <= value < 2 ** 64 for value in values)
            or sum(values) != sample['sumAttributedPhysicalFootprintsBytes']):
        raise ValueError('Invalid attributed footprint rows or total')
    output = {'valid': True, 'validForComparison': False, 'sourceRevision': result['sourceRevision'],
              'memorySamplesTaken': 1, 'provenance': result['memoryProvenance'],
              'sample': {**sample, 'valid': True}, 'liveObservations': records,
              'uiPassedTests': 1, 'backgroundDocumentsRetained': 3}
    path = directory / 'public-memory-result.json'
    path.write_text(json.dumps(output, indent=2) + '\n')
    path.chmod(0o600)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    finalize(parser.parse_args().directory)
