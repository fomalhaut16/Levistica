#!/usr/bin/env python3
"""Print bounded failure details from xcresulttool's test summary, without attachments."""
import argparse
import json
import pathlib
import re
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


def failure_classification(summary):
    # Validate the same structure as the human-readable report. Persist no
    # failure text, identifiers, device metadata, or attachments here.
    failure_report(summary)
    counts = {key: value if type(value) is int and value >= 0 else None
              for key in ('passedTests', 'failedTests', 'totalTestCount', 'skippedTests')
              for value in [summary.get(key)]}
    initialization_timeout = False
    ordinary_failure = False
    for failure in summary.get('testFailures', []):
        identifier = failure.get('testIdentifierString', '')
        runner = (failure.get('targetName') == 'LevisticaUITests'
                  and isinstance(identifier, str)
                  and re.fullmatch(r'LevisticaUITests-Runner \([0-9]+\) encountered an error', identifier))
        text = failure.get('failureText', '')
        if runner and isinstance(text, str):
            text = text.casefold()
            initialization_timeout |= ('test runner failed to initialize for ui testing' in text
                                       and 'timed out while enabling automation mode' in text)
        elif failure.get('targetName') in ('LevisticaTests', 'LevisticaUITests'):
            ordinary_failure = True
    if initialization_timeout and ordinary_failure:
        classification = 'mixed_runner_and_test_failure'
    elif initialization_timeout:
        classification = 'ui_automation_initialization_timeout'
    elif ordinary_failure:
        classification = 'test_failure'
    else:
        classification = 'unclassified_failure'
    return {'classification': classification, 'testCounts': counts,
            'appBehaviorVerdict': 'not_determined', 'successfulExecutionConfirmed': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('summary', type=pathlib.Path)
    parser.add_argument('--classification-json', type=pathlib.Path)
    args = parser.parse_args()
    summary = json.loads(args.summary.read_text())
    print(failure_report(summary))
    if args.classification_json is not None:
        result = failure_classification(summary)
        temporary = args.classification_json.with_name(args.classification_json.name + '.partial')
        temporary.write_text(json.dumps(result, indent=2) + '\n')
        temporary.chmod(0o600)
        temporary.replace(args.classification_json)
        print('Failure classification: ' + result['classification'])


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        print(f'Cannot read test failure summary: {clean(str(error), 300)}', file=sys.stderr)
        sys.exit(1)
