"""Offline regression checks for ownership handoff; never contacts Kubernetes."""

import importlib.util
import json
from pathlib import Path
import re
import subprocess
import unittest
from unittest.mock import patch
from urllib.parse import unquote

import yaml

TESTS = Path(__file__).resolve().parent / "tests" / "test_flux_lifecycle.py"
SPEC = importlib.util.spec_from_file_location("flux_lifecycle", TESTS)
LIFECYCLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LIFECYCLE)
ROOT = TESTS.parents[2]
DOCS = [
    "README.md", "AGENTS.md", "docs/how-to/scaleway-autoscaling.md",
    "docs/adr/043-flux-platform-ownership.md", "docs/adr/044-scaleway-vm-metal-rules.md",
    "docs/design/002-karpenter-scaleway-em.md", "karpenter-provider-scaleway/README.md",
]


class HandoffConcurrencyTests(unittest.TestCase):
    def test_changed_release_is_not_orphaned(self):
        # Model another controller writing a finalizer/status after the last GET.
        fake = LIFECYCLE.FAKE_KUBECTL.replace(
            'metadata = {"finalizers": ["finalizers.fluxcd.io"]}',
            'metadata = {"uid": "original", "resourceVersion": "10", '
            '"finalizers": ["finalizers.fluxcd.io"]}',
        ) + r'''
if "patch" in args and "helmrelease" in args:
    payload = json.loads(args[args.index("-p") + 1])
    if isinstance(payload, list) and any(
        op.get("op") == "test" and op.get("path") == "/metadata/resourceVersion"
        for op in payload
    ):
        print("Conflict: resourceVersion is now 11", file=sys.stderr)
        sys.exit(1)
'''
        with patch.object(LIFECYCLE, "FAKE_KUBECTL", fake):
            result, calls = LIFECYCLE.FluxLifecycleTests().run_script(
                "flux-migrate-ownership.sh", "healthy", "--prepare"
            )
        self.assertNotEqual(result.returncode, 0, "a stale read must not permit orphaning")
        self.assertFalse(any("delete" in args for args in calls))
        payload = json.loads(calls[-1][-1])
        self.assertIn({"op": "test", "path": "/metadata/resourceVersion", "value": "10"}, payload)
        self.assertIn({"op": "test", "path": "/metadata/uid", "value": "original"}, payload)


class TeardownDisarmTests(unittest.TestCase):
    def test_empty_handles_do_not_authorize_an_active_allocator(self):
        # Claims/Leases would both be empty: an armed controller can create a
        # new reservation immediately after that snapshot, so refuse first.
        for mode in ("active-provider", "provider-template", "custom-release", "provider-stopping", "provider-pod", "provider-release", "optional-graph"):
            for option in ((), ("--check",)):
                with self.subTest(mode=mode, option=option):
                    result, calls = LIFECYCLE.FluxLifecycleTests().run_script("flux-down.sh", mode, *option)
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertTrue(all("get" in args for args in calls), calls)

    def test_other_projects_are_not_scaled_or_blocked_as_native_provider(self):
        for mode in ("unrelated-controller", "provider-release-suspended"):
            with self.subTest(mode=mode):
                result, calls = LIFECYCLE.FluxLifecycleTests().run_script("flux-down.sh", mode, "--check")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(all("get" in args for args in calls))

    def test_new_reservation_after_root_suspend_blocks_first_delete(self):
        fake = LIFECYCLE.FAKE_KUBECTL.replace(
            'if kind == "deployments,pods":',
            '''if kind == "leases" and any("patch" in json.loads(line) for line in open(os.environ["CALLS"])):
        print(json.dumps({"items": [{"metadata": {"name": "new-reservation"}}]}))
        sys.exit(0)
    if kind == "deployments,pods":''',
        )
        with patch.object(LIFECYCLE, "FAKE_KUBECTL", fake):
            result, calls = LIFECYCLE.FluxLifecycleTests().run_script("flux-down.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("delete" in args for args in calls))

    def test_missing_inventory_is_not_empty_inventory(self):
        fake = LIFECYCLE.FAKE_KUBECTL.replace(
            'elif kind == "leases":',
            'elif kind == "leases":\n        print("{}")\n        sys.exit(0)',
        )
        with patch.object(LIFECYCLE, "FAKE_KUBECTL", fake):
            result, calls = LIFECYCLE.FluxLifecycleTests().run_script("flux-down.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all("get" in args for args in calls))


class DocumentationContractTests(unittest.TestCase):
    def test_local_markdown_links_and_anchors_exist(self):
        for name in DOCS:
            source = ROOT / name
            for link in re.findall(r"\[[^\]]*\]\(([^)]+)\)", source.read_text()):
                if "://" in link or link.startswith("mailto:"):
                    continue
                path, _, anchor = unquote(link).partition("#")
                target = source.parent / path if path else source
                with self.subTest(source=name, link=link):
                    self.assertTrue(target.exists(), f"missing target: {target}")
                    if anchor and target.is_file():
                        headings = re.findall(r"^#+\s+(.+)$", target.read_text(), re.MULTILINE)
                        slugs = {re.sub(r"[^\w\s-]", "", h.lower()).replace(" ", "-") for h in headings}
                        self.assertIn(anchor, slugs)

    def test_maintained_teardown_covers_dependency_order(self):
        spec = importlib.util.spec_from_file_location("gitops", ROOT / "scripts/verify-gitops.py")
        gitops = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gitops)
        _, _, children = gitops.load_graph()
        script = (ROOT / "scripts/flux-down.sh").read_text()
        order = re.search(r"base_children=\((.*?)\)", script, re.DOTALL).group(1).split()
        self.assertEqual(set(order), set(children))
        for name, doc in children.items():
            for dependency in doc["spec"].get("dependsOn", []):
                self.assertLess(order.index(name), order.index(dependency["name"]), name)

    def test_adapter_port_matches_owned_adr(self):
        values = yaml.safe_load((ROOT / "stacks/autoscaling/flux/values-prometheus-adapter.yaml").read_text())
        adr = (ROOT / "docs/adr/044-scaleway-vm-metal-rules.md").read_text()
        self.assertIn(f"vmsingle-vm:{values['prometheus']['port']}", adr)

    def test_em_status_does_not_advertise_stopped_as_available(self):
        crd = yaml.safe_load((ROOT / "karpenter-provider-scaleway/config/crd/karpenter.scaleway.st4ck.io_scalewayemnodeclasses.yaml").read_text())
        version = crd["spec"]["versions"][0]
        fields = version["schema"]["openAPIV3Schema"]["properties"]["status"]["properties"]
        self.assertNotIn("available", fields)
        self.assertIn("including reserved", fields["stopped"]["description"])
        self.assertIn(".status.stopped", [c["jsonPath"] for c in version["additionalPrinterColumns"]])

    def test_custom_chart_release_keeps_native_teardown_identity(self):
        rendered = subprocess.run([
            "helm", "template", "review-custom-name",
            str(ROOT / "karpenter-provider-scaleway/charts/karpenter-scaleway"),
            "--namespace", "autoscaling", "--set",
            "controller.enabled=true,image.repository=example.invalid/provider,image.tag=test,"
            "clusterID=test,talosClusterName=test,credentialsSecret=scaleway,bootstrapSecrets[0]=worker",
        ], text=True, capture_output=True, check=True)
        deployment = next(d for d in yaml.safe_load_all(rendered.stdout) if d and d["kind"] == "Deployment")
        for metadata in (deployment["metadata"], deployment["spec"]["template"]["metadata"]):
            self.assertEqual(metadata["labels"]["app.kubernetes.io/name"], "karpenter-scaleway")
            self.assertEqual(metadata["labels"]["app.kubernetes.io/instance"], "review-custom-name")


def load_tests(loader, tests, pattern):
    tests.addTests(loader.loadTestsFromTestCase(LIFECYCLE.FluxLifecycleTests))
    return tests


if __name__ == "__main__":
    unittest.main()
