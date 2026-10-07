import copy
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("metrics", Path(__file__).resolve().parents[1] / "verify-metrics.py")
metrics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metrics)


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 9, 27, tzinfo=timezone.utc)
        self.nodes = {"items": [{"metadata": {"name": "worker"}, "status": {
            "conditions": [{"type": "Ready", "status": "True"}]}}]}
        self.metric = {"metadata": {"name": "worker"}, "timestamp": self.now.isoformat(),
                       "usage": {"cpu": "0", "memory": "100Mi"}}
        self.nm = {"kind": "NodeMetricsList", "items": [self.metric]}
        self.pm = {"kind": "PodMetricsList", "items": [{"metadata": {"name": "app", "namespace": "default"},
                   "timestamp": self.now.isoformat(), "containers": [{"usage": self.metric["usage"].copy()}]}]}

    def check(self):
        return metrics.assess(self.nodes, self.nm, self.pm, self.now)

    def test_valid_zero_cpu(self):
        self.assertEqual(self.check(), [])

    def test_empty_or_missing_nodes_fail(self):
        self.nm["items"] = []
        self.assertTrue(self.check())
        self.nm["items"] = [dict(self.metric, metadata={"name": "unrelated"})]
        self.assertTrue(self.check())

    def test_empty_pods_fail(self):
        self.pm["items"] = []
        self.assertTrue(self.check())

    def test_missing_usage_and_stale_timestamp_fail(self):
        for mutation in ({"usage": {"cpu": "1m"}}, {"usage": {"cpu": "NaN", "memory": "1Gi"}},
                         {"timestamp": "2020-01-01T00:00:00Z"}, {"timestamp": "invalid"}):
            with self.subTest(mutation=mutation):
                self.nm["items"] = [dict(self.metric, **mutation)]
                self.assertTrue(self.check())

    def test_duplicates_fail(self):
        self.nm["items"].append(copy.deepcopy(self.metric))
        self.assertTrue(self.check())


if __name__ == "__main__":
    unittest.main()
