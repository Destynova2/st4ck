import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import yaml


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


backup = load("backup", "bootstrap-backup.py")
recover = load("recover", "bootstrap-recover-kms.py")
reset = load("reset", "bootstrap-reset.py")


def archive(path, files, mode="w"):
    with tarfile.open(path, mode) as tar:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            tar.addfile(member, io.BytesIO(data))


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "kms-output").mkdir()
        for name in backup.EXPORTS:
            (self.root / "kms-output" / name).write_text("fixture:" + name)
        seal = b"k" * 32
        encoded = base64.b64encode(seal).decode()
        (self.root / "seal.key").write_bytes(seal)
        resources = [{"mode": "managed", "type": "random_bytes", "name": "seal_key",
                      "instances": [{"attributes": {"base64": encoded}}]}]
        self.state("outer.tfstate", resources)
        resources = []
        for name in ("root", "infra", "app"):
            resources.extend([{"mode": "managed", "type": kind, "name": name + "_ca", "instances": [{"attributes": attrs}]}
                              for kind, attrs in (
                ("tls_self_signed_cert" if name == "root" else "tls_locally_signed_cert", {"cert_pem": "fixture:" + name + "-ca.pem"}),
                ("tls_private_key", {"private_key_pem": "fixture:" + name + "-ca-key.pem"}))])
        self.state("setup.tfstate", resources)
        self.docs = [{"kind": "ConfigMap", "metadata": {"name": "bao-seal-key"}, "binaryData": {"unseal.key": encoded}},
                     {"kind": "Pod", "metadata": {"name": "platform"}, "spec": {"containers": [{
                         "name": "bao", "volumeMounts": [{"name": "data"}], "env": []}], "volumes": [{
                             "name": "data", "persistentVolumeClaim": {"claimName": "platform-bao-data"}}]}}]
        (self.root / "platform.yaml").write_text(yaml.safe_dump_all(self.docs))
        archive(self.root / "setup-source.tar", {"./pki.tf": b"# fixture"})
        files = {"meta.json": b"{}", "state.bin": b"snapshot"}
        files["SHA256SUMS"] = "".join(hashlib.sha256(v).hexdigest() + "  " + k + "\n" for k, v in files.items()).encode()
        archive(self.root / "raft.snap", files, "w:gz")

    def state(self, name, resources):
        (self.root / name).write_text(json.dumps({"version": 4, "lineage": name, "resources": resources}))

    def test_complete_consistent_material(self):
        self.assertEqual(backup.validate_material(self.root)["outer_lineage"], "outer.tfstate")

    def test_wrong_seal_fails(self):
        (self.root / "seal.key").write_bytes(b"x" * 32)
        with self.assertRaisesRegex(ValueError, "static seal"):
            backup.validate_material(self.root)

    def test_nonempty_but_empty_state_fails(self):
        self.state("setup.tfstate", [])
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            backup.validate_material(self.root)

    def test_other_root_ca_fails(self):
        (self.root / "kms-output/root-ca.pem").write_text("another CA")
        with self.assertRaisesRegex(ValueError, "root CA"):
            backup.validate_material(self.root)

    def test_snapshot_corruption_fails(self):
        archive(self.root / "raft.snap", {"meta.json": b"{}", "state.bin": b"bad",
                "SHA256SUMS": b"bad  state.bin\n"}, "w:gz")
        with self.assertRaisesRegex(ValueError, "checksum"):
            backup.snapshot_valid(self.root / "raft.snap")

    def test_missing_snapshot_checksum_entries_fails(self):
        archive(self.root / "raft.snap", {"meta.json": b"{}", "state.bin": b"bad", "SHA256SUMS": b""}, "w:gz")
        with self.assertRaises(ValueError):
            backup.snapshot_valid(self.root / "raft.snap")

    def test_path_traversal_in_backup_manifest_fails(self):
        sums = {"../escape": "bad", **dict.fromkeys(backup.REQUIRED, "bad")}
        (self.root / "backup.json").write_text(json.dumps({"format": 1, "sha256": sums}))
        with self.assertRaisesRegex(ValueError, "Unsafe backup path"):
            backup.verify(self.root)

    def test_nonloopback_http_rejected_before_auth(self):
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            backup.api("http://public.example", "sys/health", "private")

    def test_recovery_never_runs_setup_or_other_writers(self):
        self.docs[-1]["spec"]["containers"].append({"name": "tofu-setup"})
        result = recover.recovery_manifest(self.docs, "restore-test", 48200)
        pod = result[-1]
        self.assertEqual([c["name"] for c in pod["spec"]["containers"]], ["bao"])
        self.assertEqual(pod["spec"]["volumes"][0]["persistentVolumeClaim"]["claimName"], "restore-test-bao-data")
        self.assertEqual(result[0]["metadata"]["name"], "restore-test-bao-seal-key")
        self.assertEqual(self.docs[0]["metadata"]["name"], "bao-seal-key")

    def test_recovery_requires_explicit_podman_target(self):
        with patch.dict("os.environ", {}, clear=True), patch("sys.argv", ["recover", str(self.root), "--name", "test",
                "--port", "48200", "--output", str(self.root / "out"), "--confirm-new-resources"]):
            with self.assertRaises(SystemExit), patch.object(recover.backup, "command") as command:
                recover.main()
            command.assert_not_called()

    def test_recovery_rejects_wrong_forwarded_http_endpoint(self):
        health = {"cluster_id": "new-kms", "initialized": True, "sealed": False}
        with patch.object(recover.backup, "api", return_value=json.dumps(health)), \
                patch.object(recover.backup, "command", return_value=json.dumps({"cluster_id": "other-kms"})) as command:
            with self.assertRaisesRegex(ValueError, "does not match"):
                recover.verify_endpoint_identity("http://127.0.0.1:48200", "restore-test-bao")
            command.assert_called_once_with("podman", "exec", "restore-test-bao", "bao", "status",
                                            "-format=json", "-address=http://127.0.0.1:8200")
        with patch.object(recover.backup, "api", return_value=json.dumps(health)), \
                patch.object(recover.backup, "command", return_value=json.dumps(health)):
            recover.verify_endpoint_identity("http://127.0.0.1:48200", "restore-test-bao")

    def test_reset_selects_only_manifest_volumes(self):
        self.assertEqual(reset.volume_names(self.docs), ["platform-bao-data"])
        self.docs[-1]["spec"]["volumes"][0]["persistentVolumeClaim"]["claimName"] = "other-project-data"
        with self.assertRaises(ValueError):
            reset.volume_names(self.docs)

    def test_legacy_rotation_targets_have_no_destructive_commands(self):
        make = (Path(__file__).resolve().parents[2] / "Makefile").read_text()
        section = make.split("rotate-bao-seal-key rotate-openbao-seal-key rotate-root-ca rotate-sub-ca:", 1)[1].split("# ─── HIGH", 1)[0]
        self.assertIn("exit 1", section)
        for forbidden in ("state rm", "volume rm", "delete pvc"):
            self.assertNotIn(forbidden, section)


if __name__ == "__main__":
    unittest.main()
