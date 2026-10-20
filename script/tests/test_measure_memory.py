import importlib.util
import pathlib
import unittest

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
