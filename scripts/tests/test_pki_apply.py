"""Check the two-phase Helm handoff with no live Kubernetes or Tofu calls."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "apply-pki.sh"
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
tool = Path(sys.argv[0]).name
with open(os.environ["CALLS"], "a") as out:
    out.write(json.dumps([tool, *args]) + "\n")
mode = os.environ["MODE"]
if tool == "tofu":
    sys.exit(1 if mode == "apply-fails" else 0)
if mode == "offline":
    sys.exit(1)
if "exec" in args:
    pod = args[args.index("exec") + 1]
    ordinal = int(pod.rsplit("-", 1)[1])
    print(json.dumps({"ha_enabled": True, "is_self": ordinal == 0,
                      "leader_address": "leader" if mode != "split" else pod}))
elif "statefulset" in args:
    release = args[args.index("statefulset") + 1]
    count = {"healthy": 3, "resume": 3, "split": 3, "partial": 1, "unexpected": 2}.get(mode)
    if mode == "mixed" and release == "openbao-infra":
        count = 3
    if count is not None:
        print(json.dumps({"spec": {"replicas": count}}))
elif "pvc" in args:
    print(json.dumps({"items": [{}] if mode == "orphan-pvc" else []}))
else:
    sys.exit(2)
'''


class PKIApplyTests(unittest.TestCase):
    def run_apply(self, mode):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            for name, content in (("kubectl", FAKE), ("tofu", FAKE), ("sleep", "#!/bin/sh\nexit 0\n")):
                command = path / name
                command.write_text(content)
                command.chmod(0o755)
            calls = path / "calls"
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", MODE=mode,
                       KUBECONFIG="unused", CALLS=str(calls))
            result = subprocess.run(["bash", str(SCRIPT), "tofu", "apply", "-auto-approve"],
                                    env=env, capture_output=True, text=True, timeout=15)
            operations = [json.loads(line) for line in calls.read_text().splitlines()]
            return result, [args for args in operations if args[0] == "tofu"]

    def test_new_or_partial_bootstrap_persists_three_replicas(self):
        for mode in ("fresh", "partial"):
            with self.subTest(mode=mode):
                result, applies = self.run_apply(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(applies), 2)
                self.assertEqual(json.loads(applies[0][-1].split("=", 2)[-1]),
                                 ["openbao-infra", "openbao-app"])
                self.assertEqual(applies[-1][-1], "-var=openbao_bootstrap_releases=[]")

    def test_healthy_and_resumed_ha_never_bootstrap_again(self):
        for mode in ("healthy", "resume"):
            result, applies = self.run_apply(mode)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(applies), 1)
            self.assertEqual(applies[0][-1], "-var=openbao_bootstrap_releases=[]")

    def test_mixed_install_does_not_downscale_infra(self):
        result, applies = self.run_apply("mixed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(applies[0][-1].split("=", 2)[-1]), ["openbao-app"])

    def test_failed_bootstrap_does_not_continue(self):
        result, applies = self.run_apply("apply-fails")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(applies), 1)

    def test_unhealthy_or_unknown_state_never_applies(self):
        for mode in ("offline", "split", "orphan-pvc", "unexpected"):
            with self.subTest(mode=mode):
                result, applies = self.run_apply(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(applies, [])


if __name__ == "__main__":
    unittest.main()
