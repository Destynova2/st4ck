"""The harness may delete only the cluster it successfully created."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "karpenter-provider-scaleway/hack/kwok-e2e/run.sh"
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as out:
    out.write(json.dumps(args) + "\n")
if args == ["get", "clusters"] and os.environ["MODE"] == "exists":
    print("chosen")
if args[:2] == ["create", "cluster"] and os.environ["MODE"] == "create-fails":
    sys.exit(1)
'''


class KWOKCleanupTests(unittest.TestCase):
    def run_harness(self, mode, keep=False):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            # Isolate both generated artifacts and tool discovery from the host.
            script = path / "module/hack/kwok-e2e/run.sh"
            script.parent.mkdir(parents=True)
            shutil.copyfile(SCRIPT, script)
            bin_dir = path / "bin"
            bin_dir.mkdir()
            for name in ("dirname", "mkdir", "tail", "grep", "tr", "python3"):
                (bin_dir / name).symlink_to(shutil.which(name))
            commands = {"kwokctl": FAKE, "kwok": "#!/bin/sh\nexit 0\n",
                        "kubectl": "#!/bin/sh\nexit 0\n", "curl": "#!/bin/sh\nexit 0\n",
                        "uuidgen": "#!/bin/sh\necho 00000000-1111-2222-3333-444444444444\n"}
            if mode != "preflight":
                commands["go"] = "#!/bin/sh\nexit 0\n"
            for name, content in commands.items():
                tool = bin_dir / name
                tool.write_text(content)
                tool.chmod(0o755)
            calls = path / "calls"
            env = dict(os.environ, PATH=str(bin_dir), HOME=tmp, CALLS=str(calls),
                       MODE=mode, KWOK_RUNTIME="binary", KEEP="1" if keep else "0")
            env.pop("KWOK_CLUSTER", None)
            if mode != "generated":
                env["KWOK_CLUSTER"] = "chosen"
            result = subprocess.run([shutil.which("bash"), str(script)], env=env,
                                    capture_output=True, text=True, timeout=5)
            operations = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
            return result, operations

    def test_preflight_failure_does_not_touch_clusters(self):
        result, calls = self.run_harness("preflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_existing_cluster_is_not_adopted_or_deleted(self):
        result, calls = self.run_harness("exists")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [["get", "clusters"]])

    def test_failed_create_is_never_deleted(self):
        result, calls = self.run_harness("create-fails")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == "delete" for c in calls))

    def test_later_failure_deletes_only_our_unique_cluster(self):
        result, calls = self.run_harness("generated")
        self.assertNotEqual(result.returncode, 0)  # Missing simulated kubeconfig.
        create = next(c for c in calls if c[0] == "create")
        delete = next(c for c in calls if c[0] == "delete")
        self.assertTrue(create[3].startswith("karpenter-em-e2e-"))
        self.assertEqual(create[3], delete[3])
        kubeconfig = create[create.index("--kubeconfig") + 1]
        self.assertIn("/module/hack/kwok-e2e/.artifacts/karpenter-em-e2e-", kubeconfig)
        self.assertNotIn("/.kube/config", kubeconfig)
        self.assertEqual(delete[delete.index("--kubeconfig") + 1], kubeconfig)

    def test_keep_preserves_owned_cluster(self):
        result, calls = self.run_harness("generated", keep=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any(c[0] == "create" for c in calls))
        self.assertFalse(any(c[0] == "delete" for c in calls))


if __name__ == "__main__":
    unittest.main()
