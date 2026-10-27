import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('failure_report', pathlib.Path(__file__).parents[1] / 'report-test-failures.py')
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class TestFailureReportTests(unittest.TestCase):
    def runner_timeout(self):
        return {'targetName': 'LevisticaUITests',
                'testIdentifierString': 'LevisticaUITests-Runner (123) encountered an error',
                'failureText': 'The test runner failed to initialize for UI testing. '
                               '(Underlying Error: Timed out while enabling automation mode.)'}

    def test_runner_timeout_is_infrastructure_without_a_product_verdict(self):
        result = report.failure_classification({'passedTests': 0, 'failedTests': 1,
            'totalTestCount': 1, 'testFailures': [self.runner_timeout()]})
        self.assertEqual(result['classification'], 'ui_automation_initialization_timeout')
        self.assertEqual(result['appBehaviorVerdict'], 'not_determined')
        self.assertFalse(result['successfulExecutionConfirmed'])

    def test_matching_words_in_an_ordinary_assertion_do_not_hide_the_test_failure(self):
        failure = {**self.runner_timeout(), 'testIdentifierString': 'ReportTests/quotedMessage()'}
        result = report.failure_classification({'testFailures': [failure]})
        self.assertEqual(result['classification'], 'test_failure')

    def test_mixed_runner_and_test_failures_preserve_both_categories(self):
        result = report.failure_classification({'testFailures': [self.runner_timeout(),
            {'targetName': 'LevisticaTests', 'testIdentifierString': 'Tests/check()', 'failureText': 'assertion'}]})
        self.assertEqual(result['classification'], 'mixed_runner_and_test_failure')

    def test_machine_report_never_copies_private_metadata_or_invalid_counts(self):
        result = report.failure_classification({'passedTests': True, 'failedTests': -1,
            'totalTestCount': '1', 'testFailures': [self.runner_timeout()],
            'devicesAndConfigurations': ['private'], 'environment': 'private', 'attachments': ['private']})
        self.assertTrue(all(value is None for value in result['testCounts'].values()))
        self.assertNotIn('private', json.dumps(result))
        self.assertNotIn('failureText', json.dumps(result))

    def test_cli_writes_only_the_bounded_classification_record(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            (path / 'summary.json').write_text(json.dumps({'testFailures': [self.runner_timeout()]}))
            subprocess.run([sys.executable, str(pathlib.Path(report.__file__)), str(path / 'summary.json'),
                            '--classification-json', str(path / 'classification.json')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=5)
            result = json.loads((path / 'classification.json').read_text())
            self.assertEqual(result['classification'], 'ui_automation_initialization_timeout')
            self.assertEqual((path / 'classification.json').stat().st_mode & 0o777, 0o600)
            self.assertFalse((path / 'classification.json.partial').exists())

    def test_assertion_and_identifier_are_visible_without_other_result_data(self):
        text = report.failure_report({
            'passedTests': 135, 'failedTests': 1, 'totalTestCount': 136,
            'testFailures': [{'targetName': 'LevisticaTests',
                              'testIdentifierString': 'InputTests/releasesController()',
                              'failureText': 'Expectation failed: controller == nil'}],
            'environment': 'must not be printed', 'attachments': ['must not be printed'],
        })
        self.assertIn('135 passed, 1 failed, 136 total', text)
        self.assertIn('FAIL LevisticaTests/InputTests/releasesController(): Expectation failed: controller == nil', text)
        self.assertNotIn('must not be printed', text)

    def test_failure_details_survive_missing_or_invalid_counts(self):
        text = report.failure_report({'passedTests': True, 'failedTests': -1, 'totalTestCount': '2',
                                     'testFailures': [{'testName': 'sample()', 'failureText': 'failed'}]})
        self.assertIn('unknown passed, unknown failed, unknown total', text)
        self.assertIn('/sample(): failed', text)

    def test_missing_failure_records_do_not_claim_success(self):
        text = report.failure_report({})
        self.assertIn('No per-test failure details recorded', text)
        self.assertNotIn('success', text)

    def test_malformed_summary_and_failure_records_are_rejected(self):
        for summary in ([], None, {'testFailures': 'wrong'}, {'testFailures': [None]}):
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                report.failure_report(summary)

    def test_terminal_controls_and_line_breaks_cannot_forge_output_lines(self):
        text = report.failure_report({'testFailures': [{'targetName': 'target\r\nFORGED',
            'testName': 'case\x1b[2J', 'failureText': 'detail\n\x00\u202eend'}]})
        self.assertEqual(len(text.splitlines()), 2)
        for control in ('\r', '\x1b', '\x00', '\u202e'):
            self.assertNotIn(control, text)

    def test_large_failure_lists_and_details_are_bounded(self):
        text = report.failure_report({'testFailures': [
            {'testName': 'case' * 1000, 'failureText': 'x' * 10000} for _ in range(100)]})
        self.assertEqual(text.count('FAIL '), 5)
        self.assertIn('95 more failure records', text)
        self.assertIn('[truncated]', text)
        self.assertLess(len(text), 11000)


if __name__ == '__main__':
    unittest.main()
