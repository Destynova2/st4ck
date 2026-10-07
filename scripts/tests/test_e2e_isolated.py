"""Safety/regression tests. No real runtime, cluster, cloud, or Git commit."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("e2e", ROOT / "scripts/e2e-isolated.py")
e2e = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(e2e)
READY = "Platform: 56 expected objects, 0 failures, 0 explicit exemptions\n"


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.config = dict(run_dir=str(self.base / "fresh"), context="e2e-unit-test",
            podman_connection="dedicated", subnet="10.59.0.0/24", ports=dict(
                kms=43820, kms_cluster=43821, vb=43808, gitea_http=43300,
                gitea_ssh=2222, wp_http=43800, wp_grpc=43900))

    def test_fresh_explicit_config_is_required(self):
        self.assertEqual(e2e.validate_config(self.config), self.config)
        for name in e2e.REQUIRED:
            bad = dict(self.config)
            del bad[name]
            with self.subTest(name=name), self.assertRaises(ValueError):
                e2e.validate_config(bad)

    def test_no_existing_directory_even_empty(self):
        (self.base / "fresh").mkdir()
        with self.assertRaisesRegex(ValueError, "NOT exist"):
            e2e.validate_config(self.config)

    def test_no_source_descendant_or_symlink(self):
        (self.base / "linked").symlink_to(self.base, target_is_directory=True)
        for path in (ROOT / "fresh-e2e", self.base / "linked" / "run", self.base / "a b"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                e2e.validate_config(dict(self.config, run_dir=str(path)))

    def test_context_subnet_and_timeouts_are_bounded(self):
        for field, value in (("context", "dev-docker-local"), ("context", "e2e-x;rm"),
                             ("subnet", "10.244.0.0/24"), ("subnet", "127.0.0.0/24"),
                             ("subnet", "8.8.8.0/24"), ("subnet", "10.0.0.0/8"),
                             ("subnet", "192.0.2.0/24"), ("subnet", "::/24"),
                             ("timeout_minutes", 0), ("metrics_timeout_minutes", True),
                             ("reuse", True), ("allow_unready", ["security/kubescape"])):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                e2e.validate_config(dict(self.config, **{field: value}))

    def test_ports_are_distinct_and_valid(self):
        for key, value in (("vb", 2222), ("kms", "43820"), ("kms", 0)):
            bad = copy.deepcopy(self.config)
            bad["ports"][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                e2e.validate_config(bad)

    def test_ssh_port_propagates_from_bootstrap_to_flux_and_keyscan(self):
        config = copy.deepcopy(self.config)
        config["ports"]["gitea_ssh"] = 32222
        e2e.validate_config(config)
        run = e2e.Run(config)
        run.env = {}
        run.password = "unit-only"
        run.revision = "a" * 40
        run.command = Mock(side_effect=[
            subprocess.CompletedProcess([], 0, "[127.0.0.1]:32222 ssh-ed25519 AAAAtest\n"),
            subprocess.CompletedProcess([], 0, run.revision + "\trefs/heads/main\n")])
        run.stack = Mock()
        run.read_gitea_keys()
        run.flux()
        args = run.command.call_args_list[0].args[0]
        self.assertEqual(args[args.index("-p") + 1], "32222")
        self.assertEqual(run.stack.call_args.args[1]["gitea_external_port"], 32222)
        self.assertIn("ed25519,rsa", args)

    def test_gitea_rsa_ed25519_or_both_are_accepted_without_algorithm_overrides(self):
        rsa = "[127.0.0.1]:2222 ssh-rsa AAAAtest"
        ed25519 = "[127.0.0.1]:2222 ssh-ed25519 AAAAtest"
        for lines in (rsa, ed25519, rsa + "\n" + ed25519):
            with self.subTest(lines=lines):
                result = e2e.gitea_host_keys("# SSH-2.0-Go\n" + lines, 2222)
                self.assertEqual(len(result.splitlines()), len(lines.splitlines()))
                self.assertTrue(all(line.startswith("gitea.flux-system.svc.cluster.local ")
                                    for line in result.splitlines()))

    def test_gitea_missing_malformed_foreign_host_or_unexpected_key_is_rejected(self):
        for output in ("", "# SSH-2.0-Go\n", "[127.0.0.1]:2222 ssh-rsa !!bad!!",
                       "[127.0.0.1]:22 ssh-rsa AAAAtest", "[prod]:2222 ssh-rsa AAAAtest",
                       "[127.0.0.1]:2222 ssh-dss AAAAtest", "SSH connection failed"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                e2e.gitea_host_keys(output, 2222)

    def test_only_nondefault_local_existing_socket(self):
        path = self.base / "podman.sock"
        is_socket = patch.object(Path, "is_socket", autospec=True, side_effect=lambda p: p == path)
        is_socket.start()
        self.addCleanup(is_socket.stop)
        dedicated = dict(Name="dedicated", URI=f"unix://{path}", Default=False)
        self.assertEqual(e2e.dedicated_socket([dedicated], "dedicated"), path)
        cases = [[dict(dedicated, Default=True)], [dict(dedicated, URI="ssh://root@host/socket")],
                 [dict(dedicated, URI="tcp://127.0.0.1:9000")],
                 [dict(dedicated, URI=f"unix://{self.base}/missing")], [],
                 [dedicated, dict(dedicated, Name="default", Default=True)]]
        for items in cases:
            with self.subTest(items=items), self.assertRaises(ValueError):
                e2e.dedicated_socket(items, "dedicated")

    def test_no_inherited_credentials_or_config(self):
        with patch.dict(os.environ, {"TF_CLI_ARGS_apply": "-destroy", "KUBECONFIG": "/prod",
                                    "CONTAINER_CONNECTION": "default", "SCW_SECRET_KEY": "secret"}):
            env = e2e.isolated_env(self.base, self.base / "socket", "/usr/bin")
        self.assertEqual(env["KUBECONFIG"], str(self.base / "kubeconfig"))
        self.assertEqual(env["CONTAINER_HOST"], env["DOCKER_HOST"])
        self.assertNotIn("TF_CLI_ARGS_apply", env)
        self.assertNotIn("CONTAINER_CONNECTION", env)
        self.assertNotIn("SCW_SECRET_KEY", env)
        self.assertEqual(env["HOME"], str(self.base / "home"))

    def preflight_responses(self, args, *, env, **kwargs):
        if args[:4] == ["podman", "system", "connection", "list"]:
            payload = [dict(Name="dedicated", URI=f"unix://{self.base}/socket", Default=False)]
        elif args[:2] == ["podman", "info"]:
            payload = dict(host=dict(security=dict(rootless=False), memTotal=32 * 1024**3, cpus=8))
        elif args[:3] == ["podman", "network", "ls"]:
            payload = [dict(name="podman")]
        elif args[0] == "talosctl":
            version = yaml.safe_load((ROOT / "contexts/_defaults.yaml").read_text())["talos_version"]
            return subprocess.CompletedProcess(args, 0, "Talos " + version + "\n")
        else:
            payload = None
        if args[0] == "podman" and args[1] != "system":
            self.assertEqual(env["CONTAINER_HOST"], f"unix://{self.base}/socket")
            self.assertNotEqual(env["HOME"], str(Path.home()))
            self.assertNotIn("TF_CLI_ARGS", env)
        return subprocess.CompletedProcess(args, 0, json.dumps(payload) if payload is not None else "")

    def test_readonly_preflight_never_creates_run_or_uses_default_engine(self):
        run = e2e.Run(self.config)
        with patch.object(e2e.shutil, "which", return_value="/tools/ok"), \
             patch.object(Path, "is_socket", return_value=True), \
             patch.object(e2e.socket, "socket"), \
             patch.object(e2e, "execute", side_effect=self.preflight_responses) as command:
            run.preflight()
        self.assertFalse(run.base.exists())
        for call in command.call_args_list:
            self.assertNotIn("apply", call.args[0])
            self.assertNotIn("create", call.args[0])

    def test_preflight_nonempty_engine_or_api_failure_aborts_before_mutation(self):
        for failure in ("occupied", "api-error", "secret"):
            run = e2e.Run(self.config)
            def response(args, **kwargs):
                target = ["podman", "secret", "ls", "-q"] if failure == "secret" else ["podman", "ps", "-aq"]
                if args == target:
                    return subprocess.CompletedProcess(args, int(failure == "api-error"), "occupied")
                return self.preflight_responses(args, **kwargs)
            with self.subTest(failure=failure), \
                 patch.object(e2e.shutil, "which", return_value="/tools/ok"), \
                 patch.object(Path, "is_socket", return_value=True), \
                 patch.object(e2e, "execute", side_effect=response), \
                 self.assertRaises((ValueError, RuntimeError)):
                run.preflight()
            self.assertFalse(run.base.exists())

    def test_bootstrap_rechecks_secrets_before_any_apply(self):
        run = e2e.Run(self.config)
        run.tofu = Mock()
        run.command = Mock(side_effect=lambda args, **kwargs: subprocess.CompletedProcess(
            args, 0, "old-secret" if args[1] == "secret" else ""))
        with self.assertRaisesRegex(ValueError, "no longer empty"):
            run.bootstrap()
        run.tofu.assert_called_once_with("bootstrap", "init")

    def test_flux_refuses_mismatched_snapshot_before_api_mutation(self):
        run = e2e.Run(self.config)
        run.env = {}
        run.password = "unit-only"
        run.revision = "a" * 40
        run.command = Mock(return_value=subprocess.CompletedProcess([], 0, "b" * 40 + "\trefs/heads/main\n"))
        run.stack = Mock()
        with self.assertRaisesRegex(RuntimeError, "exact snapshot"):
            run.flux()
        run.stack.assert_not_called()

    def test_snapshot_excludes_state_secrets_and_overrides(self):
        for name in ("stacks/pki/terraform.tfstate", "stacks/pki/terraform.tfstate.backup",
                     "stacks/pki/_local_backend_override.tf", "bootstrap/secret.auto.tfvars.json",
                     "kms-output/approle-secret-id.txt", ".env", ".terraform/providers/plugin",
                     ".git/config", "kubeconfig", "nested/infra-ca-key.pem", "orca.yaml", ".orca.json",
                     ".orca/config.json", "nested/.orca-cache/state"):
            with self.subTest(name=name):
                self.assertFalse(e2e.snapshot_file(name))
        for name in ("bootstrap/main.tf", "scripts/e2e-isolated.py", "stacks/pki/.terraform.lock.hcl"):
            self.assertTrue(e2e.snapshot_file(name))
        with self.assertRaises(ValueError):
            e2e.snapshot_file("../terraform.tfstate")

    def test_prepare_refuses_existing_run_without_any_command(self):
        run = e2e.Run(self.config)
        run.base.mkdir()
        run.command = Mock()
        with self.assertRaises(FileExistsError):
            run.prepare()
        run.command.assert_not_called()

    def test_prepare_copies_dirty_source_but_not_its_states(self):
        source = self.base / "source"
        source.mkdir()
        (source / "new.py").write_text("dirty = True\n")
        (source / "terraform.tfstate").write_text("original state")
        (source / "scripts").mkdir()
        (source / "scripts/e2e-python.sh").write_text((ROOT / "scripts/e2e-python.sh").read_text())
        run = e2e.Run(self.config, source)
        run.env = e2e.isolated_env(run.base, self.base / "socket", os.environ["PATH"])
        def command(args, **kwargs):
            if args[1] == "ls-files":
                return subprocess.CompletedProcess(args, 0, "new.py\0deleted.py\0terraform.tfstate\0")
            self.assertNotEqual(kwargs.get("cwd", run.repo), source)
            return subprocess.CompletedProcess(args, 0, "a" * 40 + "\n")
        run.command = Mock(side_effect=command)
        run.prepare()
        self.assertEqual((run.repo / "new.py").read_text(), "dirty = True\n")
        self.assertFalse((run.repo / "terraform.tfstate").exists())
        self.assertEqual((source / "terraform.tfstate").read_text(), "original state")
        self.assertEqual((source / "new.py").read_text(), "dirty = True\n")
        self.assertTrue((run.base / "bin/python3").is_file())
        self.assertTrue(run.env["PATH"].startswith(str(run.base / "bin")))

    def test_python_dependency_is_checked_with_private_home_before_creation(self):
        run = e2e.Run(self.config)
        def response(args, **kwargs):
            if args[0] == sys.executable:
                self.assertNotEqual(kwargs["env"]["HOME"], str(Path.home()))
                self.assertEqual(kwargs["env"]["E2E_PYTHON"], sys.executable)
                return subprocess.CompletedProcess(args, 1, "No module named yaml")
            return self.preflight_responses(args, **kwargs)
        with patch.object(e2e.shutil, "which", return_value="/tools/ok"), \
             patch.object(Path, "is_socket", return_value=True), \
             patch.object(e2e, "execute", side_effect=response), \
             self.assertRaisesRegex(ValueError, "E2E_PYTHON"):
            run.preflight()
        self.assertFalse(run.base.exists())

    def test_lima_identity_mounts_memory_and_empty_mounts_file_are_mandatory(self):
        instance = "st4ck-review-unit"
        target = (Path.home() / ".lima" / instance / "sock/podman.sock").resolve()
        machine = dict(name=instance, status="Running", dir=str(target.parent.parent),
                       memory=32 * 1024**3, cpus=8,
                       config=dict(mounts=[dict(location=str(self.base),
                                               mountPoint=str(self.base), writable=True)]))
        for failure in (None, "socket", "stopped", "memory", "mount", "mount-file", "missing-mode"):
            run = e2e.Run(dict(self.config, lima_instance=instance))
            if failure == "missing-mode":
                del run.config["lima_instance"]
            def response(args, **kwargs):
                if args[:2] == ["limactl", "list"]:
                    data = copy.deepcopy(machine)
                    if failure == "stopped":
                        data["status"] = "Stopped"
                    if failure == "memory":
                        data["memory"] = 28 * 1024**3
                    if failure == "mount":
                        data["config"]["mounts"][0]["writable"] = False
                    return subprocess.CompletedProcess(args, 0, json.dumps(data))
                if args[:2] == ["limactl", "shell"]:
                    return subprocess.CompletedProcess(args, int(failure == "mount-file"), "")
                return self.preflight_responses(args, **kwargs)
            with self.subTest(failure=failure), \
                 patch.object(e2e.shutil, "which", return_value="/tools/ok"), \
                 patch.object(e2e, "dedicated_socket", return_value=target if failure != "socket" else self.base), \
                 patch.object(e2e.socket, "socket"), \
                 patch.object(e2e, "execute", side_effect=response) as command:
                # The generic response fixture also asserts its own socket identity.
                original = self.preflight_responses
                def socket_response(args, **kwargs):
                    if args[0] == "podman" and args[1] != "system":
                        kwargs["env"] = dict(kwargs["env"], CONTAINER_HOST=f"unix://{self.base}/socket")
                    return original(args, **kwargs)
                with patch.object(self, "preflight_responses", side_effect=socket_response):
                    if failure:
                        with self.assertRaises((ValueError, RuntimeError)):
                            run.preflight()
                    else:
                        run.preflight()
                        self.assertEqual(run.env["LIMA_HOME"], str(target.parents[2]))
                        tests = [c.args[0] for c in command.call_args_list if c.args[0][:2] == ["limactl", "shell"]]
                        self.assertEqual(len(tests), 2)
                        self.assertIn("-f", tests[0])
                        self.assertIn("-s", tests[1])
            self.assertFalse(run.base.exists())

    def test_engine_memory_and_rootful_bounds(self):
        for ram, cpus, rootless in ((27, 8, False), (32, 7, False), (32, 8, True)):
            run = e2e.Run(self.config)
            def response(args, **kwargs):
                if args[:2] == ["podman", "info"]:
                    data = dict(host=dict(memTotal=ram * 1024**3, cpus=cpus, security=dict(rootless=rootless)))
                    return subprocess.CompletedProcess(args, 0, json.dumps(data))
                return self.preflight_responses(args, **kwargs)
            with self.subTest(ram=ram, cpus=cpus, rootless=rootless), \
                 patch.object(e2e.shutil, "which", return_value="/tools/ok"), \
                 patch.object(Path, "is_socket", return_value=True), \
                 patch.object(e2e, "execute", side_effect=response), self.assertRaises(ValueError):
                run.preflight()
            self.assertFalse(run.base.exists())

    def test_stack_backend_is_namespaced_approle_not_local_override(self):
        run = e2e.Run(self.config)
        run.command = Mock()
        run.init_stack("pki")
        args = run.command.call_args.args[0]
        self.assertIn("-backend-config=address=http://127.0.0.1:43808/state/e2e/e2e-unit-test/pki", args)
        self.assertFalse(any("password=" in arg or "username=" in arg for arg in args))
        self.assertNotIn("-reconfigure", args)

    def test_pki_uses_maintained_two_phase_wrapper(self):
        run = e2e.Run(self.config)
        run.base.mkdir()
        run.command = Mock()
        run.tofu("stacks/pki", "apply", {"kubeconfig_path": "/private/run/kubeconfig"})
        args = run.command.call_args.args[0]
        self.assertEqual(args[:4], ["bash", "scripts/apply-pki.sh", "tofu", "-chdir=stacks/pki"])

    def test_sequence_is_current_day1_then_flux_then_verification(self):
        run = e2e.Run(self.config)
        run.base.mkdir()
        run.revision = "a" * 40
        parent = Mock()
        for name in ("prepare", "bootstrap", "read_gitea_keys", "cluster", "stack", "flux", "verify"):
            method = Mock()
            setattr(run, name, method)
            parent.attach_mock(method, name)
        run.run()
        names = [call[0] for call in parent.mock_calls]
        self.assertEqual(names, ["prepare", "bootstrap", "read_gitea_keys", "cluster"] +
                         ["stack"] * 6 + ["flux", "verify"])
        self.assertEqual([c.args[0] for c in run.stack.call_args_list],
                         ["pki", "monitoring", "identity", "security", "storage", "autoscaling"])

    def verifier(self, ready=READY, ready_code=0, metrics_code=0):
        run = e2e.Run(self.config)
        run.env = e2e.isolated_env(self.base, self.base / "socket", "/usr/bin")
        run.revision = "a" * 40
        def command(args, **kwargs):
            if "scripts/verify-platform-ready.py" in args:
                return subprocess.CompletedProcess(args, ready_code, ready)
            return subprocess.CompletedProcess(args, metrics_code, "")
        run.command = Mock(side_effect=command)
        node = {"status": {"conditions": [{"type": "Ready", "status": "True"}]}}
        pod = {"status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}}
        run.kubectl = Mock(side_effect=[subprocess.CompletedProcess([], 0, json.dumps({"items": [node] * 4})),
                                       subprocess.CompletedProcess([], 0, json.dumps({"items": [pod]}))])
        return run

    def test_strict_verifier_uses_snapshot_revision_and_no_exemptions_then_metrics(self):
        run = self.verifier()
        run.verify()
        args = [call.args[0] for call in run.command.call_args_list]
        self.assertEqual([a[1] for a in args], ["scripts/verify-platform-ready.py",
            "scripts/verify-metrics.py", "scripts/verify-platform-ready.py"])
        self.assertEqual(args[0][-2:], ["--revision", run.revision])
        self.assertNotIn("--allow-unready", args[0])
        self.assertIn(run.env["KUBECONFIG"], args[1])
        self.assertIn(run.context, args[1])

    def test_api_failures_empty_inventory_and_exemptions_never_pass(self):
        for output, code in (("", 1), (READY, 1), ("", 0),
                             (READY.replace("56", "0"), 0), (READY.replace("0 explicit", "1 explicit"), 0)):
            run = self.verifier(output, code)
            with self.subTest(output=output, code=code), patch.object(e2e.time, "monotonic", side_effect=[0, 9999]):
                with self.assertRaisesRegex(RuntimeError, "Timeout"):
                    run.verify()
            self.assertEqual(run.command.call_count, 1)

    def test_metrics_failure_is_fatal_after_bounded_retry(self):
        run = self.verifier(metrics_code=1)
        with patch.object(e2e.time, "monotonic", side_effect=[0, 0, 9999]):
            with self.assertRaisesRegex(RuntimeError, "functional metrics"):
                run.verify()
        run.kubectl.assert_not_called()

    def test_regression_during_metrics_warmup_is_fatal(self):
        run = self.verifier()
        run.command.side_effect = [subprocess.CompletedProcess([], 0, READY),
                                   subprocess.CompletedProcess([], 0, "PASS metrics"),
                                   subprocess.CompletedProcess([], 1, "FAIL API")]
        with self.assertRaisesRegex(RuntimeError, "regressed"):
            run.verify()

    def test_final_pod_api_failure_or_empty_list_never_passes(self):
        for response in (RuntimeError("API failure"), subprocess.CompletedProcess([], 0, '{"items": []}')):
            run = self.verifier()
            node = dict(status=dict(conditions=[dict(type="Ready", status="True")]))
            run.kubectl.side_effect = [subprocess.CompletedProcess([], 0, json.dumps(dict(items=[node] * 4))),
                                      response]
            with self.assertRaises(RuntimeError):
                run.verify()

    def test_probe_can_warm_up_but_must_eventually_pass(self):
        run = e2e.Run(self.config)
        probe = Mock(side_effect=[False, True])
        with patch.object(e2e.time, "monotonic", side_effect=[0, 1, 2]), patch.object(e2e.time, "sleep"):
            run.wait(probe, 60, "warming")
        self.assertEqual(probe.call_count, 2)

    def test_failed_phase_cannot_write_success_artifact(self):
        run = e2e.Run(self.config)
        run.base.mkdir()
        run.prepare = Mock()
        run.bootstrap = Mock(side_effect=RuntimeError("API failed"))
        with self.assertRaises(RuntimeError):
            run.run()
        self.assertFalse((run.base / "result.json").exists())

    def test_host_key_failure_precedes_talos_creation(self):
        run = e2e.Run(self.config)
        run.prepare = Mock()
        run.bootstrap = Mock()
        run.read_gitea_keys = Mock(side_effect=ValueError("No host keys"))
        run.cluster = Mock()
        with self.assertRaisesRegex(ValueError, "No host keys"):
            run.run()
        run.cluster.assert_not_called()
        self.assertFalse(run.base.exists())


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.manifest = self.base / "bootstrap/.preflight-test/platform-pod.yaml"
        self.manifest.parent.mkdir(parents=True)
        self.manifest.write_text("kind: Pod\n")
        self.env = dict(PATH=os.environ["PATH"], E2E_REAL_PODMAN="/bin/echo",
                        E2E_LIMACTL="/bin/echo", E2E_LIMA_INSTANCE="st4ck-unit-test",
                        E2E_PODMAN_SOCKET="unix:///dedicated/socket", E2E_RUN_DIR=str(self.base),
                        LIMA_HOME="/dedicated/lima", CONTAINER_HOST="unix:///dedicated/socket",
                        DOCKER_HOST="unix:///dedicated/socket")

    def wrapper(self, *args, env=None):
        return subprocess.run(["bash", str(ROOT / "scripts/e2e-podman.sh"), *args],
                              env=env or self.env, text=True, capture_output=True, timeout=5)

    def test_kube_play_stays_inside_exact_vm_with_portable_pod_logs(self):
        for verb in (("kube", "play"), ("play", "kube")):
            result = self.wrapper(*verb, "--build=false", "--log-driver=k8s-file", str(self.manifest))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.startswith("shell --workdir=/ st4ck-unit-test sudo -n"))
            self.assertIn("podman --remote=false kube play --build=false --log-driver=k8s-file", result.stdout)
            self.assertNotIn("--start", result.stdout)
        help_result = self.wrapper("kube", "play", "--help")
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("podman --remote=false kube play --help", help_result.stdout)

    def test_remote_commands_always_pin_socket(self):
        result = self.wrapper("logs", "platform-tofu-setup")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "--url unix:///dedicated/socket logs platform-tofu-setup")

    def test_changed_socket_unexpected_options_and_outside_manifests_fail_closed(self):
        changed = dict(self.env, CONTAINER_HOST="unix:///default/socket")
        self.assertNotEqual(self.wrapper("ps", env=changed).returncode, 0)
        link = self.manifest.parent / "linked"
        link.symlink_to(self.manifest.parent, target_is_directory=True)
        for args in (("--down", str(self.manifest)), ("--replace", str(self.manifest)),
                     ("--log-driver=journald", str(self.manifest)), ("--help", str(self.manifest)),
                     (str(self.manifest), str(self.manifest)), ("/prod/platform-pod.yaml",), (),
                     (str(link / "platform-pod.yaml"),),
                     (str(self.manifest.parent / "../.preflight-test/platform-pod.yaml"),)):
            with self.subTest(args=args):
                result = self.wrapper("kube", "play", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_python_wrapper_uses_exact_checked_interpreter(self):
        result = subprocess.run(["bash", str(ROOT / "scripts/e2e-python.sh"), "-c", "import yaml"],
                                env=dict(self.env, E2E_PYTHON="/bin/echo"), text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "-c import yaml")

    def test_execute_logs_are_incremental_and_timeout_keeps_partial_evidence(self):
        log = self.base / "command.log"
        command = [sys.executable, "-c", "print('first', flush=True)"]
        first = e2e.execute(command, cwd=ROOT, env=os.environ, log_path=log, timeout=5)
        second = e2e.execute([sys.executable, "-c", "print('second', flush=True)"],
                             cwd=ROOT, env=os.environ, log_path=log, timeout=5)
        self.assertEqual(first.stdout, "first\n")
        self.assertEqual(second.stdout, "second\n")
        with self.assertRaises(subprocess.TimeoutExpired):
            e2e.execute([sys.executable, "-c", "import time; print('waiting', flush=True); time.sleep(30)"],
                        cwd=ROOT, env=os.environ, log_path=log, timeout=0.5)
        self.assertEqual(log.read_text(), "first\nsecond\nwaiting\n")


class WiringTests(unittest.TestCase):
    def test_ci_supplies_same_pinned_native_tofu_to_python_tests(self):
        config = yaml.safe_load((ROOT / ".woodpecker.yml").read_text())
        steps = {step["name"]: step for step in config["steps"]}
        self.assertEqual(steps["prepare-tofu"]["image"], steps["test-tftest"]["image"])
        self.assertRegex(steps["prepare-tofu"]["image"], r":\d+\.\d+\.\d+$")
        self.assertIn("prepare-tofu", steps["verify-gitops"]["depends_on"])
        commands = steps["verify-gitops"]["commands"]
        export = commands.index('export PATH="$PWD/.ci-tools:$PATH"')
        self.assertLess(export, commands.index("python3 -m unittest discover -s scripts/tests"))
        self.assertIn('test "$(cat .ci-tools/tofu.arch)" = "$(uname -m)"', commands)
        self.assertIn("bootstrap \\", steps["test-tftest"]["commands"][0])
        self.assertIn("bootstrap/tofu \\", steps["test-tftest"]["commands"][0])
        self.assertIn("modules/em-talos-bootstrap/modules/karpenter-config \\",
                      steps["test-tftest"]["commands"][0])
        self.assertIn("python3 scripts/flux-review_test.py", commands)
        self.assertIn("-name '*.tf'", steps["validate"]["commands"][0])
        self.assertNotIn("-name main.tf", steps["validate"]["commands"][0])

    def test_legacy_wrappers_cannot_push_cleanup_or_skip(self):
        for name in ("e2e-local.sh", "e2e-nightly.sh"):
            text = (ROOT / "scripts" / name).read_text()
            for forbidden in ("rm -", "make ", "git push", "vault-backend-token", "|| true", "ALLOWLIST"):
                self.assertNotIn(forbidden, text)
        self.assertFalse((ROOT / "scripts/e2e-local-flux.yaml").exists())

    def test_unconfigured_legacy_entrypoint_fails_before_any_runtime(self):
        env = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"]}
        for name in ("e2e-local.sh", "e2e-nightly.sh"):
            result = subprocess.run(["bash", str(ROOT / "scripts" / name)], env=env,
                                    text=True, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("E2E_CONFIG", result.stderr)


if __name__ == "__main__":
    unittest.main()
