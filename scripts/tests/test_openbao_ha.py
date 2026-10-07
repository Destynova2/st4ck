"""Ready pods must agree on one Raft leader without destructive recovery."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-openbao-ha.sh"
FAKE_KUBECTL = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as out:
    out.write(json.dumps(args) + "\n")
assert "exec" in args and args[-1] == "sys/leader"
pod = args[args.index("exec") + 1]
ordinal = int(pod.rsplit("-", 1)[1])
mode = os.environ["MODE"]
if mode == "api-error":
    sys.exit(1)
if mode == "malformed":
    print("not json")
    sys.exit(0)
state = {
    "ha_enabled": True,
    "leader_address": "https://openbao-" + str(ordinal if mode == "split" else 1) + ":8200",
    "is_self": mode == "split" or ordinal == 1,
}
if mode == "no-leader":
    state["leader_address"] = ""
if mode == "two-active":
    state["is_self"] = ordinal != 0
print(json.dumps({"data": state} if mode == "wrapped" else state))
'''


class OpenBaoHATests(unittest.TestCase):
    def run_check(self, mode):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            for name, content in (("kubectl", FAKE_KUBECTL), ("sleep", "#!/bin/sh\nexit 0\n")):
                command = path / name
                command.write_text(content)
                command.chmod(0o755)
            calls = path / "calls"
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}",
                       KUBECONFIG="unused", CALLS=str(calls), MODE=mode)
            result = subprocess.run(["bash", str(SCRIPT), "openbao-app"],
                                    env=env, capture_output=True, text=True, timeout=15)
            operations = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertTrue(all("exec" in args and "delete" not in args for args in operations))
            return result

    def test_shared_leader_can_be_pod_one(self):
        for mode in ("healthy", "wrapped"):
            with self.subTest(mode=mode):
                result = self.run_check(mode)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_unhealthy_clusters_fail_without_deleting_data(self):
        for mode in ("split", "no-leader", "two-active", "api-error", "malformed"):
            with self.subTest(mode=mode):
                result = self.run_check(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("PVCs have been preserved", result.stderr)


if __name__ == "__main__":
    unittest.main()
