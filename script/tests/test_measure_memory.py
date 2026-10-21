import importlib.util
import pathlib
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("measure_memory", pathlib.Path(__file__).parents[1] / "measure-memory.py")
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


class AttributionTests(unittest.TestCase):
    def domain(self):
        return '''pid/100 = {
\toriginator = /tmp/Levistica.app
\tcreator = Levistica[100]
\tservices = {
\t\t200 - com.apple.WebKit.WebContent.fixture
\t\t0 - com.apple.WebKit.GPU
\t\t201 - com.apple.audio.SandboxHelper
\t}
\tservice stubs = {
\t\t999 - com.apple.WebKit.WebContent.unrelated
\t}
}
'''

    def test_only_running_services_in_the_explicit_section_are_included(self):
        result = measure.parse_domain(self.domain(), 100, "/tmp/Levistica.app")
        self.assertEqual([x["pid"] for x in result], [200, 201])

    def test_wrong_creator_is_rejected(self):
        with self.assertRaises(ValueError):
            measure.parse_domain(self.domain().replace("Levistica[100]", "Levistica[101]"), 100, "/tmp/Levistica.app")

    def test_another_checkout_is_rejected(self):
        with self.assertRaises(ValueError):
            measure.parse_domain(self.domain(), 100, "/tmp/Other.app")

    def test_changed_output_format_is_rejected(self):
        with self.assertRaises(ValueError):
            measure.parse_domain(self.domain().replace("200 -", "unexpected 200 -"), 100, "/tmp/Levistica.app")

    def test_exited_chrome_children_are_explicitly_separated(self):
        rows = [(10, 1, "S"), (11, 10, "Z"), (12, 10, "S"), (20, 1, "S")]
        live, exited = measure.live_descendants(rows, 10)
        self.assertEqual(live, {10, 12})
        self.assertEqual(exited, {11})
        with self.assertRaises(ValueError):
            measure.live_descendants([(10, 1, "Z")], 10)

    def test_profile_argument_does_not_match_a_similar_directory(self):
        self.assertTrue(measure.has_path_argument("chrome --user-data-dir=/tmp/test --x", "--user-data-dir=", "/tmp/test"))
        self.assertFalse(measure.has_path_argument("chrome --user-data-dir=/tmp/test-other", "--user-data-dir=", "/tmp/test"))

    def test_exited_pid_reaping_does_not_invalidate_unchanged_live_attribution(self):
        before = {"identities": {10: {"started": "same", "executable": "/tmp/app"}},
                  "services": [], "exited_descendant_pids": [11]}
        after = {**before, "exited_descendant_pids": []}
        stable, change = measure.attribution_change(before, after)
        self.assertTrue(stable)
        self.assertEqual(change["exited_removed"], [11])

    def test_live_exit_addition_pid_reuse_and_service_change_are_invalid(self):
        before = {"identities": {10: {"started": "old", "executable": "/tmp/app"}},
                  "services": [], "exited_descendant_pids": []}
        for after in [
            {**before, "identities": {}},
            {**before, "identities": {**before["identities"], 11: {"started": "new"}}},
            {**before, "identities": {10: {"started": "new", "executable": "/tmp/app"}}},
            {**before, "services": [{"pid": 10, "service": "new-service"}]},
        ]:
            with self.subTest(after=after):
                self.assertFalse(measure.attribution_change(before, after)[0])

    def test_identity_race_reports_missing_pid_without_subprocess_output(self):
        with patch.object(measure, "run", return_value="10 Wed Oct 21 16:00:00 2026 /tmp/app\n"):
            with self.assertRaisesRegex(ValueError, "missing PIDs: 11$"):
                measure.identities([10, 11])

    def test_chrome_creator_must_match_the_explicit_browser(self):
        text = self.domain().replace("Levistica[100]", "Google Chrome[100]")
        self.assertEqual(len(measure.parse_domain(text, 100, "/tmp/Levistica.app", "Google Chrome")), 2)
        with self.assertRaises(ValueError):
            measure.parse_domain(text, 100, "/tmp/Levistica.app")

    def test_descendants_exclude_another_browser_and_do_not_duplicate(self):
        rows = [(10, 1), (11, 10), (12, 11), (20, 1), (21, 20), (22, 21)]
        self.assertEqual(measure.descendants(rows, 10), {10, 11, 12})

    def test_footprint_uses_the_physical_metric_not_category_total(self):
        values, missing = measure.metrics({"unit": "byte", "bytes per unit": 1, "processes": [
            {"pid": 100, "footprint": 80, "auxiliary": {"phys_footprint": 90}}
        ]}, [100])
        self.assertEqual(values, {100: 90})
        self.assertEqual(missing, [])

    def test_missing_metrics_are_unknown_not_zero(self):
        values, missing = measure.metrics({"unit": "byte", "bytes per unit": 1, "processes": [
            {"pid": 100, "footprint": 80}
        ]}, [100, 200])
        self.assertEqual(values, {100: None})
        self.assertEqual(missing, [100, 200])

    def test_wrong_units_are_rejected(self):
        with self.assertRaises(ValueError):
            measure.metrics({"unit": "page", "bytes per unit": 16384}, [100])

    def test_unrequested_processes_are_rejected(self):
        with self.assertRaises(ValueError):
            measure.metrics({"unit": "byte", "bytes per unit": 1, "processes": [{"pid": 200}]}, [100])


if __name__ == "__main__":
    unittest.main()
