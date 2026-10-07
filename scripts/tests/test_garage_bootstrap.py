"""Exercise bootstrap retries and credential repair with a simulated kubectl."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

SCRIPT = Path(__file__).resolve().parents[2] / "stacks/storage/flux-bootstrap/bootstrap.sh"
FAKE_KUBECTL = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as out:
    out.write(json.dumps(args) + "\n")
if args[0] == "apply":
    obj = json.load(sys.stdin)
    assert obj["metadata"]["namespace"] == "storage"
    assert obj["stringData"]
    sys.exit(0)
if "wait" in args:
    sys.exit(0)
args = args[args.index("/garage") + 1:]
if args == ["status"]:
    role = "NO ROLE" if os.environ.get("NEW_LAYOUT") == "1" else "HEALTHY"
    print("\n".join(str(i) * 16 + " " + role for i in range(1, 4)))
elif args == ["layout", "show"]:
    print("Current cluster layout version: " + os.environ.get("LAYOUT_VERSION", "0"))
elif args[:2] == ["key", "info"] and "--show-secret" in args:
    print("Key ID: GK" + "a" * 24)
    print("Secret key: " + ("hidden" if os.environ.get("BAD_KEY") else "b" * 64))
'''


class GarageBootstrapTests(unittest.TestCase):
    def test_rendered_role_can_create_and_patch_only_target_secrets(self):
        documents = list(yaml.safe_load_all((SCRIPT.parent / "job.yaml").read_text()))
        role = next(d for d in documents if d["kind"] == "Role" and d["metadata"]["namespace"] == "storage")
        rules = [r for r in role["rules"] if "secrets" in r["resources"] and "" in r["apiGroups"]]
        # Kubernetes cannot constrain collection-level create by resourceNames.
        self.assertTrue(any("create" in r["verbs"] and not r.get("resourceNames") for r in rules))
        patches = [r for r in rules if "patch" in r["verbs"]]
        self.assertEqual(len(patches), 1)
        self.assertEqual(set(patches[0]["resourceNames"]),
                         {"velero-s3-credentials", "zot-s3-credentials", "cnpg-s3-credentials"})
        self.assertFalse(any("delete" in r["verbs"] or "*" in r["verbs"] for r in rules))
        binding = next(d for d in documents if d["kind"] == "RoleBinding" and d["metadata"]["namespace"] == "storage")
        self.assertEqual(binding["roleRef"]["name"], role["metadata"]["name"])
        self.assertIn({"kind": "ServiceAccount", "name": "garage-bootstrap", "namespace": "storage"}, binding["subjects"])

    def run_bootstrap(self, **extra):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            fake = path / "kubectl"
            fake.write_text(FAKE_KUBECTL)
            fake.chmod(0o755)
            calls = path / "calls"
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", CALLS=str(calls), **extra)
            result = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=10)
            return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_existing_layout_repairs_secrets_without_reassigning(self):
        for _ in range(2):
            result, calls = self.run_bootstrap()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(sum(c[0] == "apply" for c in calls), 3)
            self.assertFalse(any("assign" in c for c in calls))
            self.assertNotIn("b" * 64, result.stdout + result.stderr)

    def test_initial_layout_is_applied_before_secrets(self):
        result, calls = self.run_bootstrap(NEW_LAYOUT="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum("assign" in c for c in calls), 3)
        self.assertTrue(any(c[-3:] == ["apply", "--version", "1"] for c in calls))

    def test_changed_topology_requires_review(self):
        result, calls = self.run_bootstrap(NEW_LAYOUT="1", LAYOUT_VERSION="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("assign" in c for c in calls))

    def test_hidden_or_invalid_key_never_becomes_a_secret(self):
        result, calls = self.run_bootstrap(BAD_KEY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == "apply" for c in calls))


if __name__ == "__main__":
    unittest.main()
