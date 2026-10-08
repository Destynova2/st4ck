"""Render the real pod template without providers, state, or infrastructure."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


class BootstrapTemplateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        variables = dict(vault_backend_image="example.invalid/backend:test",
                         source_dir="/srv/test", podman_socket_path="/run/podman/podman.sock",
                         p_kms=8200, p_kms_cluster=8201, p_vb=8080,
                         p_gitea_http=3000, p_gitea_ssh=2222, p_wp_http=8000, p_wp_grpc=9000)
        expression = 'jsonencode(templatefile(%s, %s))' % (
            json.dumps(str(ROOT / "bootstrap/platform-pod.yaml")), json.dumps(variables))
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["tofu", "console"], cwd=directory,
                                    input=expression + "\n", capture_output=True, text=True, check=True)
        cls.docs = list(yaml.safe_load_all(json.loads(json.loads(result.stdout))))
        cls.pod = next(doc for doc in cls.docs if doc["kind"] == "Pod")
        cls.containers = {c["name"]: c for c in cls.pod["spec"]["containers"]}

    def test_agent_secret_available_before_setup(self):
        for name in ("woodpecker-agent", "woodpecker-server"):
            env = {v["name"]: v for v in self.containers[name]["env"]}
            self.assertEqual(env["WOODPECKER_AGENT_SECRET"]["valueFrom"]["secretKeyRef"]["key"],
                             "CI_AGENT_SECRET")
            self.assertNotIn("WOODPECKER_AGENT_SECRET_FILE", env)

    def test_agent_health_port_does_not_collide(self):
        env = {v["name"]: v for v in self.containers["woodpecker-agent"]["env"]}
        self.assertEqual(env["WOODPECKER_HEALTHCHECK_ADDR"]["value"], "127.0.0.1:3001")

    def test_webhook_uses_shared_pod_port_not_host_published_port(self):
        env = {v["name"]: v for v in self.containers["woodpecker-server"]["env"]}
        self.assertEqual(env["WOODPECKER_EXPERT_WEBHOOK_HOST"]["value"], "http://127.0.0.1:8000")
        self.assertIn("valueFrom", env["WOODPECKER_HOST"])

    def test_backend_is_a_socket_not_an_empty_volume(self):
        volumes = {v["name"]: v for v in self.pod["spec"]["volumes"]}
        self.assertEqual(volumes["podman-sock"]["hostPath"],
                         {"path": "/run/podman/podman.sock", "type": "Socket"})

    def test_matchbox_assets_directory_exists(self):
        mounts = {m["mountPath"]: m["name"] for m in self.containers["matchbox"]["volumeMounts"]}
        volumes = {v["name"] for v in self.pod["spec"]["volumes"]}
        self.assertIn(mounts["/var/lib/matchbox/assets"], volumes)

    def test_matchbox_probe_uses_a_tool_present_in_the_image(self):
        probe = self.containers["matchbox"]["livenessProbe"]
        self.assertNotIn("httpGet", probe)
        self.assertEqual(probe["exec"]["command"],
                         ["wget", "-q", "-T", "3", "-O", "/dev/null", "http://127.0.0.1:8090/"])
        self.assertGreater(probe["timeoutSeconds"], 3)

    def test_setup_cannot_report_success_after_failure(self):
        self.assertTrue(self.containers["tofu-setup"]["args"][0].startswith("set -eu\n"))

    def test_setup_state_survives_container_recreation(self):
        mounts = {m["mountPath"]: m["name"] for m in self.containers["tofu-setup"]["volumeMounts"]}
        volumes = {v["name"]: v for v in self.pod["spec"]["volumes"]}
        self.assertEqual(volumes[mounts["/var/lib/tofu"]]["persistentVolumeClaim"]["claimName"],
                         "platform-tofu-state")
        script = self.containers["tofu-setup"]["args"][0]
        self.assertIn("cd /var/lib/tofu", script)
        self.assertLess(script.index("existing PKI without setup state"), script.index("tofu init"))
        self.assertNotIn("eval tofu", script)

    def test_persistent_workdir_does_not_keep_deleted_configuration(self):
        script = self.containers["tofu-setup"]["args"][0]
        self.assertIn("for config in ./*.tf ./*.tf.json", script)
        self.assertLess(script.index("rm --"), script.index("cp /source/bootstrap/tofu/"))
        self.assertNotIn("rm terraform.tfstate", script)


if __name__ == "__main__":
    unittest.main()
