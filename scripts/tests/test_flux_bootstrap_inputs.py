import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("flux_inputs", ROOT / "scripts/apply-flux-bootstrap.py")
flux = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(flux)


class FluxInputTests(unittest.TestCase):
    def test_local_does_not_consume_scaleway_outputs(self):
        password = 'special " $value \\ password'
        result = flux.inputs("local", {"admin_user": {"value": "talos"}, "admin_password": {"value": password}},
                             {"GITEA_CLUSTER_HOST": "192.168.122.1", "GITEA_PORT": "13300"})
        self.assertEqual(result["gitea_repo_owner"], "talos")
        self.assertEqual(result["gitea_admin_password"], password)
        self.assertEqual(result["gitea_api_url"], "http://127.0.0.1:13300")

    def test_local_requires_reachable_endpoint(self):
        for host in ("", "localhost", "127.0.0.1", "0.0.0.0", "::1"):
            with self.subTest(host=host), self.assertRaises(ValueError):
                flux.inputs("local", {"admin_user": {"value": "talos"}, "admin_password": {"value": "secret"}},
                            {"GITEA_CLUSTER_HOST": host})

    def test_scaleway_prefers_private_endpoint_and_configured_admin(self):
        values = dict(ci_vpc_ip="10.0.0.2", ci_ip="203.0.113.2", gitea_admin_user="custom",
                      gitea_admin_password="secret")
        result = flux.inputs("scaleway", {k: {"value": v} for k, v in values.items()}, {})
        self.assertEqual(result["gitea_external_host"], "10.0.0.2")
        self.assertEqual(result["gitea_repo_owner"], "custom")

    def test_ssh_port_matches_external_endpoint(self):
        outputs = {"admin_user": {"value": "talos"}, "admin_password": {"value": "secret"}}
        environment = {"GITEA_CLUSTER_HOST": "192.168.122.1", "GITEA_SSH_PORT": "42222"}
        self.assertEqual(flux.inputs("local", outputs, environment)["gitea_external_port"], "42222")
        source = (ROOT / "stacks/flux-bootstrap/main.tf").read_text()
        self.assertIn("target_port = var.gitea_external_port", source)
        self.assertIn("port     = var.gitea_external_port", source)
        for invalid in ("0", "65536", "ssh", "22.0", "-1"):
            with self.subTest(port=invalid), self.assertRaises(ValueError):
                flux.inputs("local", outputs, dict(environment, GITEA_SSH_PORT=invalid))

    def test_make_does_not_embed_admin_password_in_command_line(self):
        make = (ROOT / "Makefile").read_text()
        section = make.split("flux-bootstrap-apply:", 1)[1].split("# ─── oidc-register", 1)[0]
        self.assertNotIn("gitea_admin_password=", section)
        self.assertNotIn("destroy-noop", section)
        self.assertIn("--provider", section)


if __name__ == "__main__":
    unittest.main()
