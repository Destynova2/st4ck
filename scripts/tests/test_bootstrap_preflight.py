"""Bootstrap replacement regressions. Every Podman call is mocked."""

import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/bootstrap-preflight.py"
SPEC = importlib.util.spec_from_file_location("bootstrap_preflight", HELPER)
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)
KEY = b"a" * 32


def state_fixture(serial=2, lineage="original-lineage"):
    resources = []

    def add(kind, name, attributes):
        resources.append(dict(mode="managed", type=kind, name=name,
                              instances=[dict(attributes=attributes)]))

    root_key = "-----BEGIN PRIVATE KEY-----\nroot\n-----END PRIVATE KEY-----\n"
    root_cert = "-----BEGIN CERTIFICATE-----\nroot\n-----END CERTIFICATE-----\n"
    add("tls_private_key", "root_ca", dict(private_key_pem=root_key))
    add("tls_self_signed_cert", "root_ca", dict(private_key_pem=root_key, cert_pem=root_cert))
    exports = {"root-ca.pem": root_cert.encode()}
    for name in ("infra", "app"):
        key = root_key.replace("root", name)
        cert = root_cert.replace("root", name)
        add("tls_private_key", name + "_ca", dict(private_key_pem=key))
        add("tls_cert_request", name + "_ca", dict(private_key_pem=key, cert_request_pem=name))
        add("tls_locally_signed_cert", name + "_ca",
            dict(cert_pem=cert, cert_request_pem=name, ca_private_key_pem=root_key, ca_cert_pem=root_cert))
        exports[name + "-ca.pem"] = cert.encode()
        exports[name + "-ca-key.pem"] = key.encode()
        exports[name + "-ca-chain.pem"] = (cert + root_cert).encode()
    return dict(version=4, lineage=lineage, serial=serial, resources=resources), exports


def archive_bytes(files):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w") as archive:
        for name, value in files.items():
            info = tarfile.TarInfo("./" + name)
            info.size = len(value)
            archive.addfile(info, io.BytesIO(value))
    return stream.getvalue()


class FakePodman:
    """Strict fake: unknown commands fail instead of reaching a real engine."""

    def __init__(self):
        state, exports = state_fixture()
        self.raw = json.dumps(state).encode()
        self.volumes = {"platform-bao-data": {}, "platform-kms-output": exports}
        self.legacy = {"terraform.tfstate": self.raw}
        self.persistent_mount = False
        self.pod = self.setup = self.bao = True
        self.secret = True
        self.running = True
        self.mounted_key = KEY
        self.calls = []
        self.fail = None
        self.corrupt_import = False
        self.help = b"--build --replace --log-driver"
        self.ports = {"8000/tcp": [{"HostIp": "", "HostPort": "18000"}]}

    def __call__(self, command, **kwargs):
        assert command[0] == "podman", command
        args = tuple(command[1:])
        self.calls.append(args)
        code, out = 0, b""
        if args == self.fail:
            code = 125
        elif len(args) == 3 and args[1] == "exists":
            present = {"pod": self.pod, "container": self.setup if args[2].endswith("tofu-setup") else self.bao,
                       "volume": args[2] in self.volumes, "secret": self.secret}[args[0]]
            code = 0 if present else 1
        elif args == ("container", "inspect", "platform-tofu-setup"):
            mounts = [dict(Destination="/kms-output", Name="platform-kms-output")]
            if self.persistent_mount:
                mounts.append(dict(Destination="/var/lib/tofu", Name="platform-tofu-state"))
            out = json.dumps([dict(Mounts=mounts, State=dict(Status="running" if self.running else "exited"))]).encode()
        elif args == ("pod", "inspect", "platform"):
            out = json.dumps([dict(InfraConfig=dict(PortBindings=self.ports))]).encode()
        elif args == ("cp", "platform-bao:/bao/seal/unseal.key", "-"):
            out = archive_bytes({"unseal.key": self.mounted_key})
        elif args == ("cp", "platform-tofu-setup:/tmp/tofu-work/.", "-"):
            out = archive_bytes(self.legacy)
        elif args[:2] == ("volume", "export"):
            out = archive_bytes(self.volumes[args[2]])
        elif args[:2] == ("volume", "create"):
            self.volumes[args[2]] = {}
        elif args[:2] == ("volume", "import"):
            with tarfile.open(fileobj=io.BytesIO(kwargs["input"])) as archive:
                for member in archive:
                    assert member.mode == 0o600
                    self.volumes[args[2]][member.name] = archive.extractfile(member).read()
            if self.corrupt_import:
                self.volumes[args[2]]["terraform.tfstate"] = b"broken"
        elif args == ("kube", "play", "--help"):
            out = self.help
        elif args == ("secret", "ls", "--format", "json"):
            # Podman 5.8 renders this as a Go template, not a JSON formatter.
            out = b"json\n" if self.secret else b""
        elif args == ("pod", "rm", "-f", "platform"):
            self.pod = False
        elif args[:2] == ("kube", "play"):
            assert Path(args[-1]).is_file()
            assert Path(args[-1]).stat().st_mode & 0o777 == 0o600
        elif args in (("pause", "platform-tofu-setup"), ("unpause", "platform-tofu-setup"),
                      ("secret", "rm", "platform-secrets")):
            pass
        else:
            raise AssertionError(f"Unexpected command: {command}")
        stdout = kwargs.get("stdout")
        if hasattr(stdout, "write"):
            stdout.write(out)
            out = None
        return subprocess.CompletedProcess(command, code, out, b"hidden engine diagnostic")


class BootstrapPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.manifest = self.directory / "pod.yaml"
        self.manifest.write_text(yaml.safe_dump(dict(kind="Pod", spec=dict(containers=[dict(
            name="woodpecker", ports=[dict(containerPort=8000, hostPort=18000)])]))))
        self.manifest.chmod(0o600)
        self.retained = self.directory / "unseal.key"
        self.engine = FakePodman()
        self.guard = preflight.Preflight(self.directory)
        self.mock = patch.object(preflight.subprocess, "run", self.engine)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def run_guard(self, replace=True):
        self.guard.guard(KEY, self.retained, replace, self.manifest)

    def assert_not_destroyed(self):
        self.assertNotIn(("pod", "rm", "-f", "platform"), self.engine.calls)
        self.assertNotIn(("secret", "rm", "platform-secrets"), self.engine.calls)
        self.assertFalse(any(c[:2] == ("kube", "play") and c[-1] != "--help" for c in self.engine.calls))

    def test_legacy_migrated_and_verified_before_deletion(self):
        self.engine.legacy["terraform.tfstate.backup"] = self.engine.raw
        self.run_guard()
        self.assertEqual(self.engine.volumes["platform-tofu-state"], self.engine.legacy)
        self.assertLess(self.engine.calls.index(("volume", "import", "platform-tofu-state", "-")),
                        self.engine.calls.index(("pod", "rm", "-f", "platform")))
        self.assertLess(self.engine.calls.index(("volume", "export", "platform-tofu-state")),
                        self.engine.calls.index(("pod", "rm", "-f", "platform")))
        self.assertEqual(self.retained.read_bytes(), KEY)
        self.assertEqual(self.retained.stat().st_mode & 0o777, 0o400)

    def test_check_only_migrates_without_deleting_and_resumes(self):
        self.run_guard(replace=False)
        self.assert_not_destroyed()
        self.assertIn("platform-tofu-state", self.engine.volumes)
        self.assertEqual(self.engine.calls[-1], ("unpause", "platform-tofu-setup"))

    def test_stopped_legacy_container_can_be_migrated(self):
        self.engine.running = False
        self.run_guard()
        self.assertNotIn(("pause", "platform-tofu-setup"), self.engine.calls)

    def test_valid_persistent_state_is_never_overwritten(self):
        self.engine.persistent_mount = True
        self.engine.volumes["platform-tofu-state"] = {"terraform.tfstate": self.engine.raw}
        self.run_guard()
        self.assertNotIn(("volume", "import", "platform-tofu-state", "-"), self.engine.calls)
        self.assertNotIn(("cp", "platform-tofu-setup:/tmp/tofu-work/.", "-"), self.engine.calls)

    def test_identical_legacy_and_persistent_states_are_preserved(self):
        self.engine.volumes["platform-tofu-state"] = dict(self.engine.legacy)
        self.run_guard()
        self.assertNotIn(("volume", "import", "platform-tofu-state", "-"), self.engine.calls)

    def test_divergent_persistent_state_refuses_even_same_lineage(self):
        state, _ = state_fixture(serial=1)
        self.engine.volumes["platform-tofu-state"] = {"terraform.tfstate": json.dumps(state).encode()}
        with self.assertRaisesRegex(preflight.Refused, "diverge"):
            self.run_guard()
        self.assert_not_destroyed()

    def test_lost_legacy_state_refuses_before_deletion(self):
        self.engine.legacy = {}
        with self.assertRaisesRegex(preflight.Refused, "without readable state"):
            self.run_guard()
        self.assert_not_destroyed()
        self.assertEqual(self.engine.calls[-1], ("unpause", "platform-tofu-setup"))

    def test_pki_without_any_setup_container_or_state_refuses(self):
        self.engine.setup = False
        with self.assertRaisesRegex(preflight.Refused, "Existing PKI"):
            self.run_guard()
        self.assert_not_destroyed()

    def test_wrong_ca_certificate_or_key_refuses(self):
        for name in ("root-ca.pem", "infra-ca.pem", "app-ca-key.pem"):
            with self.subTest(name=name):
                original = self.engine.volumes["platform-kms-output"][name]
                self.engine.volumes["platform-kms-output"][name] = b"different identity"
                with self.assertRaisesRegex(preflight.Refused, "does not match"):
                    self.run_guard()
                self.engine.volumes["platform-kms-output"][name] = original
                self.assert_not_destroyed()

    def test_invalid_state_refuses(self):
        for raw in (b"", b"not json", b"{}", b'[]', b'{"version":4,"lineage":"x","serial":0,"resources":[]}'):
            with self.subTest(raw=raw):
                self.engine.legacy["terraform.tfstate"] = raw
                with self.assertRaises(preflight.Refused):
                    self.run_guard()
                self.assert_not_destroyed()

    def test_tainted_pki_refuses(self):
        state = json.loads(self.engine.raw)
        state["resources"][0]["instances"][0]["status"] = "tainted"
        self.engine.legacy["terraform.tfstate"] = json.dumps(state).encode()
        with self.assertRaisesRegex(preflight.Refused, "tainted"):
            self.run_guard()
        self.assert_not_destroyed()

    def test_locked_state_refuses_and_resumes(self):
        self.engine.legacy[".terraform.tfstate.lock.info"] = b"lock"
        with self.assertRaisesRegex(preflight.Refused, "locked"):
            self.run_guard()
        self.assert_not_destroyed()
        self.assertEqual(self.engine.calls[-1], ("unpause", "platform-tofu-setup"))

    def test_mounted_key_disagreement_refuses_even_without_pki(self):
        self.engine.volumes["platform-kms-output"] = {}
        self.engine.mounted_key = b"b" * 32
        with self.assertRaisesRegex(preflight.Refused, "mounted"):
            self.run_guard()
        self.assert_not_destroyed()

    def test_existing_raft_without_key_proof_refuses(self):
        self.engine.bao = False
        with self.assertRaisesRegex(preflight.Refused, "provable seal"):
            self.run_guard()
        self.assert_not_destroyed()

    def test_transport_error_is_not_absence(self):
        self.engine.fail = ("pod", "exists", "platform")
        with self.assertRaisesRegex(preflight.Refused, "125"):
            self.run_guard()
        self.assertEqual(len(self.engine.calls), 1)

    def test_failed_export_import_or_verification_never_deletes(self):
        for failure in (("cp", "platform-tofu-setup:/tmp/tofu-work/.", "-"),
                        ("volume", "export", "platform-kms-output"),
                        ("volume", "import", "platform-tofu-state", "-")):
            with self.subTest(failure=failure):
                self.engine.fail = failure
                with self.assertRaises(preflight.Refused):
                    self.run_guard()
                self.assert_not_destroyed()

    def test_corrupt_readback_never_deletes(self):
        self.engine.corrupt_import = True
        with self.assertRaisesRegex(preflight.Refused, "read-back"):
            self.run_guard()
        self.assert_not_destroyed()

    def test_backup_from_another_lineage_is_not_imported(self):
        state, _ = state_fixture(lineage="wrong-lineage")
        self.engine.legacy["terraform.tfstate.backup"] = json.dumps(state).encode()
        with self.assertRaisesRegex(preflight.Refused, "Invalid legacy state backup"):
            self.run_guard()
        self.assert_not_destroyed()
        self.assertNotIn(("volume", "import", "platform-tofu-state", "-"), self.engine.calls)

    def test_pause_and_capability_failures_never_delete(self):
        for failure in (("pause", "platform-tofu-setup"), ("kube", "play", "--help"),
                        ("secret", "exists", "platform-secrets")):
            with self.subTest(failure=failure):
                self.engine.fail = failure
                with self.assertRaises(preflight.Refused):
                    self.run_guard()
                self.assert_not_destroyed()

    def test_podman_5_8_literal_secret_format_is_never_json_decoded(self):
        listing = self.engine(["podman", "secret", "ls", "--format", "json"])
        self.assertEqual(listing.stdout, b"json\n")
        self.engine.calls.clear()
        self.run_guard()
        self.assertNotIn(("secret", "ls", "--format", "json"), self.engine.calls)
        self.assertLess(self.engine.calls.index(("secret", "exists", "platform-secrets")),
                        self.engine.calls.index(("pod", "rm", "-f", "platform")))
        self.assertLess(self.engine.calls.index(("pod", "rm", "-f", "platform")),
                        self.engine.calls.index(("secret", "rm", "platform-secrets")))

    def test_absent_secret_does_not_block_play_or_trigger_secret_removal(self):
        self.engine.secret = False
        self.run_guard()
        self.assertIn(("secret", "exists", "platform-secrets"), self.engine.calls)
        self.assertNotIn(("secret", "rm", "platform-secrets"), self.engine.calls)
        self.assertIn(("kube", "play", "--build=false", "--log-driver=k8s-file", str(self.manifest)), self.engine.calls)

    def test_stopped_persistent_setup_passes_without_starting_or_pausing(self):
        self.engine.running = False
        self.engine.persistent_mount = True
        self.engine.volumes["platform-tofu-state"] = {"terraform.tfstate": self.engine.raw}
        self.run_guard(replace=False)
        self.assert_not_destroyed()
        self.assertNotIn(("pause", "platform-tofu-setup"), self.engine.calls)
        self.assertNotIn(("unpause", "platform-tofu-setup"), self.engine.calls)
        self.assertNotIn(("cp", "platform-tofu-setup:/tmp/tofu-work/.", "-"), self.engine.calls)

    def test_failed_pod_deletion_does_not_remove_secret_or_play(self):
        self.engine.fail = ("pod", "rm", "-f", "platform")
        with self.assertRaises(preflight.Refused):
            self.run_guard()
        self.assertNotIn(("secret", "rm", "platform-secrets"), self.engine.calls)
        self.assertNotIn(("kube", "play", "--build=false", "--log-driver=k8s-file", str(self.manifest)), self.engine.calls)

    def test_archive_symlink_is_not_accepted_as_state(self):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            item = tarfile.TarInfo("terraform.tfstate")
            item.type, item.linkname = tarfile.SYMTYPE, "/etc/passwd"
            archive.addfile(item)

        def run_archive(*args, stdout):
            stdout.write(stream.getvalue())

        with patch.object(self.guard, "run", run_archive):
            with self.assertRaisesRegex(preflight.Refused, "Unsafe"):
                self.guard.archive("volume", "export", "test", select=preflight.state_file)

    def test_podman_remote_client_omits_build_flag(self):
        self.engine.help = b"--replace --log-driver"
        self.run_guard()
        self.assertEqual(self.engine.calls[-1], ("kube", "play", "--log-driver=k8s-file", str(self.manifest)))

    def test_missing_log_driver_capability_refuses_before_deletion(self):
        self.engine.help = b"--build"
        with self.assertRaisesRegex(preflight.Refused, "log-driver"):
            self.run_guard()
        self.assert_not_destroyed()

    def test_changed_port_address_protocol_or_target_refuses_before_pause(self):
        for ports in ({"8000/tcp": [{"HostIp": "", "HostPort": "8000"}]},
                      {"8000/tcp": [{"HostIp": "127.0.0.1", "HostPort": "18000"}]},
                      {"8000/udp": [{"HostIp": "", "HostPort": "18000"}]},
                      {"9000/tcp": [{"HostIp": "", "HostPort": "18000"}]}, {}):
            with self.subTest(ports=ports):
                self.engine.ports = ports
                with self.assertRaisesRegex(preflight.Refused, "port bindings changed"):
                    self.run_guard()
                self.assert_not_destroyed()
                self.assertNotIn(("pause", "platform-tofu-setup"), self.engine.calls)

    def test_unknown_inspect_ports_fail_closed(self):
        self.engine.ports = ["not a bindings object"]
        with self.assertRaises(preflight.Refused):
            self.run_guard()
        self.assert_not_destroyed()

    def test_explicit_ipv4_wildcard_matches_default(self):
        self.engine.ports["8000/tcp"][0]["HostIp"] = "0.0.0.0"
        self.run_guard()

    def test_readonly_and_stopped_paths_also_refuse_port_changes(self):
        self.engine.running = False
        self.engine.ports = {}
        with self.assertRaisesRegex(preflight.Refused, "port bindings changed"):
            self.run_guard(replace=False)
        self.assert_not_destroyed()

    def test_fresh_bootstrap(self):
        self.engine.pod = self.engine.bao = self.engine.setup = False
        self.engine.volumes = {}
        self.run_guard()
        self.assertNotIn(("pod", "rm", "-f", "platform"), self.engine.calls)
        self.assertEqual(self.retained.read_bytes(), KEY)


class BootstrapManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        variables = dict(vault_backend_image="example.invalid/backend:test", source_dir="/srv/test",
                         podman_socket_path="/run/podman/podman.sock", p_kms=8200, p_kms_cluster=8201,
                         p_vb=8080, p_gitea_http=3000, p_gitea_ssh=2222, p_wp_http=8000, p_wp_grpc=9000)
        expression = 'jsonencode(templatefile(%s, %s))' % (
            json.dumps(str(ROOT / "bootstrap/platform-pod.yaml")), json.dumps(variables))
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(["tofu", "console"], cwd=directory, input=expression + "\n",
                                    text=True, capture_output=True, check=True, timeout=30)
        cls.pod_yaml = json.loads(json.loads(result.stdout))
        cls.configmap = yaml.safe_dump(dict(apiVersion="v1", kind="ConfigMap", metadata=dict(name="bao-seal-key"),
                                           binaryData={"unseal.key": base64.b64encode(KEY).decode()}))

    def test_real_template_seal_and_persistence(self):
        raw = self.configmap + "\n---\n" + self.pod_yaml
        self.assertEqual(preflight.manifest_key(raw, replacing=True), KEY)

    def test_old_template_allowed_for_migration_but_not_replacement(self):
        docs = list(yaml.safe_load_all(self.configmap + "\n---\n" + self.pod_yaml))
        pod = next(d for d in docs if d["kind"] == "Pod")
        setup = next(c for c in pod["spec"]["containers"] if c["name"] == "tofu-setup")
        setup["volumeMounts"] = [m for m in setup["volumeMounts"] if m["mountPath"] != "/var/lib/tofu"]
        raw = yaml.safe_dump_all(docs)
        self.assertEqual(preflight.manifest_key(raw), KEY)
        with self.assertRaises(preflight.Refused):
            preflight.manifest_key(raw, replacing=True)

    def test_duplicate_or_missing_seal_refuses(self):
        for raw in (self.pod_yaml, self.configmap + "\n---\n" + self.configmap + "\n---\n" + self.pod_yaml):
            with self.assertRaises(preflight.Refused):
                preflight.manifest_key(raw)

    def test_short_or_invalid_base64_key_refuses(self):
        for value in ("%%%invalid", base64.b64encode(KEY[:-1]).decode()):
            raw = self.configmap.replace(base64.b64encode(KEY).decode(), value) + "\n---\n" + self.pod_yaml
            with self.assertRaises(preflight.Refused):
                preflight.manifest_key(raw)

    def test_local_and_remote_replacement_contracts(self):
        local = (ROOT / "bootstrap/main.tf").read_text()
        remote = (ROOT / "envs/scaleway/ci/main.tf").read_text()
        launch = (ROOT / "envs/scaleway/ci/launch.sh").read_text()
        self.assertIn('bootstrap-preflight.py" --replace --manifest', local)
        self.assertNotIn('when    = destroy', local)
        self.assertNotIn('podman pod rm', local)
        self.assertNotIn('podman pod rm', launch)
        for source in (local, remote):
            self.assertIn('prevent_destroy = true', source)
            self.assertIn('local.setup_source_sha', source)
        self.assertIn('destination = "/opt/woodpecker/bootstrap-preflight.py"', remote)
        self.assertNotIn('source      = "${path.module}/../../../bootstrap/"', remote)

    def test_remote_launcher_refuses_retained_key_mismatch_before_any_engine_call(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "configmap.yaml").write_text(self.configmap)
            (work / "secrets.yaml").write_text(yaml.safe_dump(dict(
                apiVersion="v1", kind="Secret", metadata=dict(name="platform-secrets"), stringData=dict(CI_PASSWORD="test"))))
            (work / "platform-pod.yaml").write_text(self.pod_yaml)
            (work / "unseal.key.bin").write_bytes(KEY)
            (work / "unseal.key").write_bytes(b"b" * 32)
            (work / "pod-with-secrets.yaml").write_text("previous canonical manifest")
            shutil.copy(HELPER, work / HELPER.name)
            (work / "podman").write_text('#!/bin/sh\necho unexpected >> "$BOOTSTRAP_WORKDIR/engine-called"\nexit 99\n')
            (work / "podman").chmod(0o700)
            result = subprocess.run(["bash", str(ROOT / "envs/scaleway/ci/launch.sh")],
                                    env=dict(os.environ, BOOTSTRAP_WORKDIR=str(work),
                                             PATH=str(work) + os.pathsep + os.environ["PATH"]),
                                    text=True, capture_output=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("retained seal key", result.stderr)
            self.assertFalse((work / "engine-called").exists())
            self.assertEqual((work / "pod-with-secrets.yaml").read_text(), "previous canonical manifest")
            for name in ("configmap.yaml", "secrets.yaml", "pod-with-secrets.yaml", "unseal.key.bin"):
                self.assertEqual((work / name).stat().st_mode & 0o777, 0o600)
            self.assertEqual(work.stat().st_mode & 0o777, 0o700)

    def test_uploaded_binary_must_match_configmap_before_any_engine_call(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "platform.yaml"
            manifest.write_text(self.configmap + "\n---\n" + self.pod_yaml)
            key = Path(directory) / "uploaded.bin"
            key.write_bytes(b"b" * 32)
            with patch.object(sys, "argv", [str(HELPER), "--manifest", str(manifest), "--uploaded-key", str(key)]), \
                    patch.object(preflight.subprocess, "run") as runner:
                old_umask = os.umask(0o077)
                try:
                    with self.assertRaisesRegex(preflight.Refused, "differs from seal ConfigMap"):
                        preflight.main()
                finally:
                    os.umask(old_umask)
                runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
