import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "platform_ready", Path(__file__).resolve().parents[1] / "verify-platform-ready.py")
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class PlatformReadyTests(unittest.TestCase):
    def fixture(self):
        objects = {
            "hr": {"kind": "HelmRelease", "metadata": {"name": "test", "namespace": "test"}},
            "child": {"kind": "Kustomization", "metadata": {"name": "child", "namespace": "flux-system"}},
        }
        keys = [("HelmRelease", "test", "test"),
                ("Kustomization", "flux-system", "child"),
                ("Kustomization", "flux-system", "management"),
                ("GitRepository", "flux-system", "management"),
                ("ExternalSecret", "flux-system", "flux-ssh-identity"),
                ("ClusterSecretStore", "", "openbao-infra")]
        keys.extend(("ClusterIssuer", "", name) for name in
                    ("internal-ca-bootstrap", "internal-ca", "cilium-issuer"))
        live = {key: {"metadata": {"generation": 2}, "status": {
            "observedGeneration": 2, "conditions": [{"type": "Ready", "status": "True"}],
            "lastAppliedRevision": "main@sha1:abc", "lastAttemptedRevision": "main@sha1:abc",
            "artifact": {"revision": "main@sha1:abc"}}} for key in keys}
        return objects, {"hr": "management", "child": "management"}, live

    def test_complete_fresh_inventory_passes(self):
        objects, owners, live = self.fixture()
        failures, exemptions, count = check.assess(objects, owners, live, "abc", set())
        self.assertEqual((failures, exemptions, count), ([], [], 9))

    def test_database_requires_all_instances_not_just_a_ready_operator(self):
        objects, owners, live = self.fixture()
        doc = {"kind": "Cluster", "metadata": {"name": "db", "namespace": "identity"},
               "spec": {"instances": 3}, "status": {"readyInstances": 1,
               "conditions": [{"type": "Ready", "status": "True"}]}}
        objects["db"] = doc
        live[("Cluster", "identity", "db")] = doc
        failures, _, _ = check.assess(objects, owners, live, "abc", set())
        self.assertTrue(any("database instances" in f for f in failures))
        doc["status"]["readyInstances"] = 3
        self.assertEqual(check.assess(objects, owners, live, "abc", set())[0], [])

    def test_old_child_revision_fails_even_with_an_unrelated_allowance(self):
        objects, owners, live = self.fixture()
        live[("Kustomization", "flux-system", "child")]["status"]["lastAppliedRevision"] = "old"
        failures, _, _ = check.assess(objects, owners, live, "abc", {"test/test"})
        self.assertTrue(any("child: wrong" in f for f in failures))

    def test_allowance_is_reported_and_does_not_hide_wrong_source(self):
        objects, owners, live = self.fixture()
        live[("HelmRelease", "test", "test")]["status"]["conditions"][0]["status"] = "False"
        live[("GitRepository", "flux-system", "management")]["status"]["artifact"]["revision"] = "old"
        failures, exemptions, _ = check.assess(objects, owners, live, "abc", {"test/test"})
        self.assertEqual(exemptions, ["HelmRelease/test/test"])
        self.assertTrue(any("source revision" in f for f in failures))

    def test_empty_expected_graph_is_not_success(self):
        with self.assertRaises(ValueError):
            check.assess({}, {}, {}, "abc", set())

    def test_empty_live_inventory_fails_even_with_allowance(self):
        doc = {"kind": "HelmRelease", "metadata": {"name": "test", "namespace": "test"}}
        failures, exemptions, _ = check.assess({"hr": doc}, {"hr": "management"}, {},
                                              "abc", {"test/test"})
        self.assertTrue(any("HelmRelease/test/test: missing" in f for f in failures))
        self.assertFalse(exemptions)

    def test_stale_generation_is_not_ready(self):
        obj = {"metadata": {"generation": 2}, "status": {"observedGeneration": 1,
               "conditions": [{"type": "Ready", "status": "True"}]}}
        self.assertFalse(check.ready(obj))
        obj["status"]["conditions"][0]["observedGeneration"] = 2
        self.assertTrue(check.ready(obj))

    def test_eso_secret_missing_is_not_success(self):
        obj = {"metadata": {}, "status": {"conditions": [
            {"type": "Ready", "status": "True", "reason": "SecretMissing"}]}}
        self.assertFalse(check.ready(obj))

    def test_revision_must_match_exactly(self):
        self.assertTrue(check.at_revision("main@sha1:abc", "abc"))
        self.assertFalse(check.at_revision("main@sha1:abcdef", "abc"))
        self.assertFalse(check.at_revision(None, "abc"))

    def test_unknown_allowance_fails(self):
        doc = {"kind": "HelmRelease", "metadata": {"name": "test", "namespace": "test"}}
        with self.assertRaises(ValueError):
            check.assess({"hr": doc}, {"hr": "management"}, {}, "abc", {"wrong/name"})


if __name__ == "__main__":
    unittest.main()
