#!/usr/bin/env python3
"""Prepare and validate the opt-in five-document Profile XCTest workload."""
import argparse
import importlib.util
import json
import os
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('app_processes', ROOT / 'script/check-app-processes.py')
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)


def validate_state(state, completed=False):
    if (state.get('kind') != 'sleep-documents' or state.get('expected_tabs') != 5
            or state.get('transport') != 'same-origin-sse-lifecycle-v1'
            or state.get('invalid_reason')):
        raise ValueError('Not a valid five-document lifecycle fixture')
    expected = {str(n): 3 if completed and n < 5 else 1 if completed else 0 for n in range(1, 6)}
    if state.get('loads') != sum(expected.values()) or state.get('document_loads') != expected:
        raise ValueError('Unexpected document load counts; do not retry the workload automatically')
    if completed:
        documents = state.get('documents', {})
        if set(documents) != set(expected) or not all(
                d.get('complete') and d.get('seenVisible') and d.get('sections') == 240
                for d in documents.values()):
            raise ValueError('Some documents did not report readiness')
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'validate'])
    parser.add_argument('state', type=pathlib.Path)
    parser.add_argument('output', nargs='?', type=pathlib.Path)
    args = parser.parse_args()
    state = json.loads(args.state.read_text())
    counts = validate_state(state, completed=args.mode == 'validate')
    if args.mode == 'prepare':
        if args.output is None:
            parser.error('prepare requires an output file')
        snapshot = processes.run_ps(['-axo', 'pid=,comm='])
        if snapshot is None:
            raise ValueError('Process enumeration failed')
        pids = processes.check_snapshot(snapshot, ROOT, processes.describe_process, os.getuid(), only='Profile')
        if len(pids) != 1:
            raise ValueError('Exactly one verified Profile process is required')
        args.output.write_text(json.dumps({'pid': pids[0], 'executable': next(path for path, identifier in processes.known_apps(ROOT).items() if identifier.endswith('.profile')), 'urls': state['urls']}, indent=2) + '\n')
        args.output.chmod(0o600)
        print('Profile workload prepared for one verified process.')
    else:
        print(json.dumps({'completed': True, 'cycles': 2, 'sleeps': 8, 'resumes': 8,
                          'loads': sum(counts.values()), 'document_loads': counts}))


if __name__ == '__main__':
    main()
