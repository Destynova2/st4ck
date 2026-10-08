"""Version mismatch must stop container provisioning before any mutation."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

SCRIPT = Path(__file__).resolve().parents[1] / "local-docker-up.sh"


class LocalDockerTests(unittest.TestCase):
    def test_deferred_cni_stops_only_its_readiness_process(self):
        version = yaml.safe_load((SCRIPT.parents[1] / "contexts/_defaults.yaml").read_text())["talos_version"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = {
                "talosctl": '#!/bin/sh\ncase "$*" in\n'
                            '"version --client --short") printf "Talos %s\\n" "$PIN";;\n'
                            '"config contexts") printf "CURRENT NAME\\n"; '
                            'if [ -f "$FAKE_ROOT/pid" ]; then echo "* unused"; fi;;\n'
                            '"cluster create docker"*) echo $$ > "$FAKE_ROOT/pid"; exec /bin/sleep 60;;\n'
                            '*"kubeconfig"*) printf "server: https://10.5.0.2:6443\\n" > "$KUBECONFIG_OUT";;\n'
                            '*"read /proc/1/mountinfo") echo "1 0 0:1 / /run rw - tmpfs tmpfs rw";;\n'
                            '*) exit 1;;\nesac\n',
                "podman": '#!/bin/sh\nif [ -f "$FAKE_ROOT/pid" ]; then echo "127.0.0.1:12345"; else exit 1; fi\n',
                "kubectl": '#!/bin/sh\necho node/unused\n',
                "helm": '#!/bin/sh\nexit 1\n',
                "sleep": '#!/bin/sh\nexec /bin/sleep 0.02\n',
            }
            for name, body in scripts.items():
                path = root / name
                path.write_text(body)
                path.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", TALOSCTL=str(root / "talosctl"),
                       PIN=version, FAKE_ROOT=str(root), DOCKER_HOST="unix:///unused", WORKERS="0",
                       SKIP_CILIUM="1", KUBECONFIG_OUT=str(root / "kubeconfig"), TALOSCONFIG=str(root / "talosconfig"))
            try:
                result = subprocess.run(["bash", str(SCRIPT), "unused"], env=env,
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("SKIP_CILIUM=1", result.stdout)
                with self.assertRaises(ProcessLookupError):
                    os.kill(int((root / "pid").read_text()), 0)
            finally:
                if (root / "pid").exists():
                    try:
                        os.kill(int((root / "pid").read_text()), 15)
                    except ProcessLookupError:
                        pass

    def test_creation_error_is_not_hidden_by_background_readiness(self):
        version = yaml.safe_load((SCRIPT.parents[1] / "contexts/_defaults.yaml").read_text())["talos_version"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = root / "talosctl"
            cli.write_text('#!/bin/sh\ncase "$*" in\n'
                           '"version --client --short") printf "Talos %s\\n" "$PIN";;\n'
                           '"config contexts") printf "CURRENT NAME\\n";;\n'
                           '"cluster create docker"*) printf "%s\\n" "$*" > "$ARGS"; '
                           'echo "creation-test-failure" >&2; exit 42;;\n'
                           '*) exit 1;;\nesac\n')
            cli.chmod(0o755)
            for name in ("helm", "kubectl", "podman"):
                stub = root / name
                stub.write_text('#!/bin/sh\nexit 1\n')
                stub.chmod(0o755)
            sleep = root / "sleep"
            sleep.write_text('#!/bin/sh\nexec /bin/sleep 0.02\n')
            sleep.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", TALOSCTL=str(cli),
                       PIN=version, ARGS=str(root / "args"), DOCKER_HOST="unix:///unused",
                       KUBECONFIG_OUT=str(root / "kubeconfig"), TALOSCONFIG=str(root / "talosconfig"))
            result = subprocess.run(["bash", str(SCRIPT), "unused"], env=env,
                                    capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("creation-test-failure", result.stderr)
            self.assertNotIn("--wait", (root / "args").read_text())

    def test_container_mount_guard(self):
        guard = SCRIPT.with_name("check-talos-container-mounts.sh")
        cases = (
            ("1 0 0:1 / /run/secrets ro,nosuid - tmpfs tmpfs rw\n", 0, False),
            ("1 0 0:1 / /run/secrets rw,nosuid - tmpfs tmpfs rw\n", 0, True),
            ("1 0 0:1 / /run rw,nosuid - tmpfs tmpfs rw\n", 0, True),
            ("", 1, False),
        )
        with tempfile.TemporaryDirectory() as directory:
            cli = Path(directory) / "talosctl"
            cli.write_text('#!/bin/sh\nprintf "%s" "$MOUNTINFO"\nexit "$READ_STATUS"\n')
            cli.chmod(0o755)
            for mountinfo, status, succeeds in cases:
                with self.subTest(mountinfo=mountinfo, status=status):
                    env = dict(os.environ, TALOSCTL=str(cli), MOUNTINFO=mountinfo, READ_STATUS=str(status))
                    result = subprocess.run(["bash", str(guard), "isolated", "10.5.0.2"],
                                            env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode == 0, succeeds)

    def test_wrong_cli_version_fails_before_runtime_or_context_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = root / "talosctl"
            cli.write_text('#!/bin/sh\n'
                           'if [ "$*" = "version --client --short" ]; then\n'
                           '  printf "Client:\\nTalos v99.0.0\\n"\n'
                           'else touch "$MUTATED"; exit 1; fi\n')
            cli.chmod(0o755)
            for name in ("helm", "kubectl", "podman"):
                stub = root / name
                stub.write_text('#!/bin/sh\ntouch "$MUTATED"\nexit 1\n')
                stub.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       TALOSCTL=str(cli), MUTATED=str(root / "mutated"))
            result = subprocess.run(["bash", str(SCRIPT), "unused"], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("container provisioning requires talosctl", result.stderr)
            self.assertFalse((root / "mutated").exists())


if __name__ == "__main__":
    unittest.main()
