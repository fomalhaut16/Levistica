#!/usr/bin/env python3
"""Print bounded failure details from xcresulttool's test summary, without attachments."""
import json
import pathlib
import sys
import unicodedata

MAX_FAILURES = 5
MAX_DETAIL = 1500


def clean(value, limit):
    if not isinstance(value, str):
        return 'unknown'
    # Treat result content as text, never terminal control sequences.
    value = ''.join(' ' if unicodedata.category(char).startswith('C') else char for char in value)
    value = ' '.join(value.split())
    return value if len(value) <= limit else value[:limit] + ' [truncated]'


def failure_report(summary):
    if not isinstance(summary, dict):
        raise ValueError('Expected a test summary object')
    failures = summary.get('testFailures', [])
    if not isinstance(failures, list) or any(not isinstance(item, dict) for item in failures):
        raise ValueError('Expected a list of test failures')
    counts = []
    for key in ('passedTests', 'failedTests', 'totalTestCount'):
        value = summary.get(key)
        counts.append(str(value) if type(value) is int and value >= 0 else 'unknown')
    lines = [f'Test result counts: {counts[0]} passed, {counts[1]} failed, {counts[2]} total.']
    for failure in failures[:MAX_FAILURES]:
        target = clean(failure.get('targetName'), 200)
        name = clean(failure.get('testIdentifierString') or failure.get('testName'), 400)
        detail = clean(failure.get('failureText'), MAX_DETAIL)
        lines.append(f'FAIL {target}/{name}: {detail}')
    if not failures:
        lines.append('No per-test failure details recorded; inspect xcodebuild.log for build or runner failures.')
    if len(failures) > MAX_FAILURES:
        lines.append(f'{len(failures) - MAX_FAILURES} more failure records in the local test summary/result bundle.')
    return '\n'.join(lines)


def main():
    if len(sys.argv) != 2:
        raise ValueError('Usage: report-test-failures.py test-summary.json')
    summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
    print(failure_report(summary))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        print(f'Cannot read test failure summary: {clean(str(error), 300)}', file=sys.stderr)
        sys.exit(1)
