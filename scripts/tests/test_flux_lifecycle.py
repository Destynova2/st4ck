"""Exercise ownership handoff and ordered teardown without a Kubernetes API."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
FAKE_KUBECTL = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as out:
    out.write(json.dumps(args) + "\n")
mode = os.environ["MODE"]
if mode == "offline":
    sys.exit(1)
if "get" in args:
    kind = args[args.index("get") + 1]
    if mode == "absent" and kind not in {"leases", "deployments,pods"}:
        sys.exit(0)
    if kind == "deployments,pods":
        items = []
        if mode == "active-provider":
            items = [{"kind": "Deployment", "metadata": {"name": "karpenter-scaleway"}, "spec": {"replicas": 2}}]
        elif mode == "provider-template":
            items = [{"kind": "Deployment", "metadata": {"name": "legacy"}, "spec": {"replicas": 2, "template": {"metadata": {"labels": {"app.kubernetes.io/instance": "autoscaling-karpenter-scaleway"}}}}}]
        elif mode == "custom-release":
            items = [{"kind": "Deployment", "metadata": {"name": "custom", "labels": {"app.kubernetes.io/name": "karpenter-scaleway"}}, "spec": {"replicas": 1}}]
        elif mode == "provider-stopping":
            items = [{"kind": "Deployment", "metadata": {"name": "karpenter-scaleway"}, "spec": {"replicas": 0}, "status": {"replicas": 1}}]
        elif mode == "provider-pod":
            items = [{"kind": "Pod", "metadata": {"name": "provider-abc", "labels": {"app.kubernetes.io/instance": "karpenter-scaleway"}}, "status": {"phase": "Running"}}]
        elif mode == "unrelated-controller":
            items = [{"kind": "Deployment", "metadata": {"name": "another-project"}, "spec": {"replicas": 2}}]
        print(json.dumps({"items": items}))
    elif kind == "helmreleases":
        items = [{"metadata": {"name": "vpa"}, "spec": {}}]
        if mode == "provider-release":
            items.append({"metadata": {"name": "custom"}, "spec": {"chart": {"spec": {"chart": "./karpenter-provider-scaleway/charts/karpenter-scaleway"}}}})
        if mode == "provider-release-suspended":
            items.append({"metadata": {"name": "karpenter-scaleway"}, "spec": {"suspend": True}})
        print(json.dumps({"items": items}))
    elif kind == "kustomizations":
        names = ["management", "autoscaling"]
        if mode == "optional-graph":
            names.append("native-provider")
        print(json.dumps({"items": [{"metadata": {"name": n}} for n in names]}))
    elif kind == "leases":
        print(json.dumps({"items": [{"metadata": {"name": "orphan"}}] if mode == "orphan-reservation" else []}))
    elif kind == "nodeclaims":
        print(json.dumps({"items": [{"metadata": {"name": "live"}}] if mode == "live-nodeclaims" else []}))
    elif kind == "helmrelease":
        metadata = {"finalizers": ["finalizers.fluxcd.io"]}
        conditions = []
        if mode == "unknown-finalizer":
            metadata["finalizers"].append("example.org/protect")
        if mode == "deleting":
            metadata["deletionTimestamp"] = "2026-09-23T00:00:00Z"
        if mode == "reconciling":
            conditions = [{"type": "Reconciling", "status": "True"}]
        print(json.dumps({"metadata": metadata, "status": {"conditions": conditions}}))
    else:
        print(kind + "/" + args[args.index("get") + 2])
if "delete" in args and mode == "delete-fails":
    sys.exit(1)
'''


class FluxLifecycleTests(unittest.TestCase):
    def run_script(self, script, mode="healthy", *args):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            fake = path / "kubectl"
            fake.write_text(FAKE_KUBECTL)
            fake.chmod(0o755)
            calls = path / "calls"
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}",
                       KUBECONFIG="unused", CALLS=str(calls), MODE=mode)
            result = subprocess.run(["bash", str(SCRIPTS / script), *args],
                                    env=env, capture_output=True, text=True, timeout=10)
            return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_migration_defaults_to_read_only(self):
        result, calls = self.run_script("flux-migrate-ownership.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all("get" in args for args in calls))

    def test_prepare_orphans_only_bootstrap_helmrelease_crs(self):
        result, calls = self.run_script("flux-migrate-ownership.sh", "healthy", "--prepare")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(calls[0][-1]), {"spec": {"suspend": True, "prune": False}})
        deletes = [args for args in calls if "delete" in args]
        self.assertEqual(len(deletes), 4)
        self.assertTrue(all(args[args.index("delete") + 1] == "helmrelease" for args in deletes))

    def test_prepare_rejects_active_or_foreign_finalizers(self):
        for mode in ("reconciling", "unknown-finalizer", "deleting"):
            with self.subTest(mode=mode):
                result, calls = self.run_script("flux-migrate-ownership.sh", mode, "--prepare")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any("delete" in args or '"metadata"' in args[-1] for args in calls))

    def test_down_waits_for_resources_and_deletes_leaves_first(self):
        result, calls = self.run_script("flux-down.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        deletes = [args[args.index("delete") + 2] for args in calls if "delete" in args]
        self.assertLess(deletes.index("identity-database"), deletes.index("cnpg-operator"))
        self.assertLess(deletes.index("identity-backup-credentials"), deletes.index("storage-secrets"))
        self.assertLess(deletes.index("storage-backup"), deletes.index("storage-garage"))
        self.assertLess(deletes.index("autoscaling"), deletes.index("monitoring-vm-stack"))
        self.assertEqual(deletes[-1], "management")
        for index, args in enumerate(calls):
            if "delete" in args:
                self.assertEqual(json.loads(calls[index - 1][-1])["spec"]["deletionPolicy"], "WaitForTermination")

    def test_down_stops_when_first_delete_fails(self):
        result, calls = self.run_script("flux-down.sh", "delete-fails")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sum("delete" in args for args in calls), 1)

    def test_down_refuses_to_remove_live_capacity_controller(self):
        result, calls = self.run_script("flux-down.sh", "live-nodeclaims")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all("get" in args for args in calls))

    def test_down_refuses_orphan_reservations_without_nodeclaims(self):
        result, calls = self.run_script("flux-down.sh", "orphan-reservation", "--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reservations", result.stderr)
        self.assertTrue(all("get" in args for args in calls))

    def test_missing_flux_is_not_confused_with_api_failure(self):
        result, _ = self.run_script("flux-down.sh", "absent")
        self.assertEqual(result.returncode, 0)
        result, _ = self.run_script("flux-down.sh", "offline")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
