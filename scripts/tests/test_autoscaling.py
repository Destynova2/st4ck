from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
PROVIDER = ROOT / "karpenter-provider-scaleway"
CHART = PROVIDER / "charts/karpenter-scaleway"


class AutoscalingTests(unittest.TestCase):
    def render(self, *args, check=True):
        return subprocess.run(["helm", "template", "karpenter-scaleway", str(CHART),
                               "--namespace", "autoscaling", *args],
                              text=True, capture_output=True, check=check)

    def test_native_provider_is_inert_by_default(self):
        self.assertFalse(list(yaml.safe_load_all(self.render().stdout)))
        hr = yaml.safe_load((ROOT / "stacks/autoscaling/flux-provider/helmrelease.yaml").read_text())
        self.assertTrue(hr["spec"]["suspend"])
        root = (ROOT / "clusters/management/kustomization.yaml").read_text()
        self.assertNotIn("flux-provider", root)

    def test_enabling_without_credentials_or_image_fails(self):
        self.assertNotEqual(self.render("--set", "controller.enabled=true", check=False).returncode, 0)

    def test_enabled_controller_uses_stable_nodes_and_narrow_secret_access(self):
        docs = [d for d in yaml.safe_load_all(self.render("--set",
            "controller.enabled=true,image.repository=example.invalid/provider,image.tag=test,"
            "clusterID=test,talosClusterName=test,credentialsSecret=scaleway,bootstrapSecrets[0]=worker").stdout) if d]
        deploy = next(d for d in docs if d["kind"] == "Deployment")
        pod = deploy["spec"]["template"]["spec"]
        expression = pod["affinity"]["nodeAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"][0]["matchExpressions"][0]
        self.assertEqual(expression, {"key": "karpenter.sh/nodepool", "operator": "DoesNotExist"})
        secret_rules = [r for d in docs if d["kind"] in {"Role", "ClusterRole"}
                        for r in d["rules"] if "secrets" in r["resources"]]
        self.assertEqual(len(secret_rules), 1)
        self.assertEqual(secret_rules[0]["resourceNames"], ["worker"])
        self.assertEqual(secret_rules[0]["verbs"], ["get"])

    def test_provider_crds_match_chart_and_core_pin(self):
        for source in (PROVIDER / "config/crd").glob("*.yaml"):
            self.assertEqual(source.read_bytes(), (CHART / "crds" / source.name).read_bytes())
        version = yaml.safe_load((ROOT / "clusters/management/versions-configmap.yaml").read_text())["data"]["karpenter_version"]
        self.assertIn(f"sigs.k8s.io/karpenter v{version}", (PROVIDER / "go.mod").read_text())
        self.assertEqual(len(list((CHART / "crds").glob("*.yaml"))), 6)

    def test_metrics_apis_do_not_compete(self):
        values = yaml.safe_load((ROOT / "stacks/autoscaling/flux/values-prometheus-adapter.yaml").read_text())
        self.assertEqual(values["rules"]["external"], [])
        self.assertIn("resource", values["rules"])
        self.assertEqual(values["prometheus"]["url"], "http://vmsingle-vm.monitoring.svc")
        self.assertEqual(values["prometheus"]["path"], "")
        self.assertEqual(values["prometheus"]["port"], 8428)
        self.assertIn("http://vmsingle-vm.monitoring.svc:8428",
                      (ROOT / "stacks/autoscaling/variables.tf").read_text())

    def test_node_scrapes_supply_the_adapters_node_label(self):
        values = yaml.safe_load((ROOT / "stacks/monitoring/flux-vm/values-vm-stack.yaml").read_text())
        endpoints = values["prometheus-node-exporter"]["vmScrape"]["spec"]["endpoints"]
        self.assertTrue(any(r.get("target_label") == "node" and
                            r.get("source_labels") == ["__meta_kubernetes_pod_node_name"]
                            for e in endpoints for r in e.get("relabelConfigs", [])))


if __name__ == "__main__":
    unittest.main()
