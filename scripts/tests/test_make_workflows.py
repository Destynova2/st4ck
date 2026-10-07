from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MakeWorkflowTests(unittest.TestCase):
    def dry_run(self, *args):
        return subprocess.check_output(["make", "-n", *args], cwd=ROOT, text=True, stderr=subprocess.STDOUT)

    def test_local_upgrade_uses_local_provider_and_kubeconfig(self):
        text = self.dry_run("upgrade", "PROVIDER=local", "GITEA_CLUSTER_HOST=192.168.122.1")
        self.assertIn("dev-local-host.yaml", text)
        self.assertIn("local-apply", text)
        self.assertIn("--provider \"local\"", text)
        self.assertIn(".kube/talos-local", text)
        self.assertNotIn("make scaleway-apply", text)
        self.assertNotIn("rm -rf \"$dir/.terraform", text)
        self.assertIn("dr-backup-kms", text)
        self.assertLess(text.index("local-apply"), text.index("local-kubeconfig"))

    def test_update_regenerates_and_detects_absent_pod(self):
        text = self.dry_run("bootstrap-update")
        self.assertIn("tofu -chdir=bootstrap apply", text)
        self.assertIn("-replace=terraform_data.platform_pod", text)
        self.assertIn("bootstrap-preflight.py", text)

    def test_stop_preserves_containers_and_reset_requires_confirmation_first(self):
        self.assertIn("podman pod stop platform", self.dry_run("bootstrap-stop"))
        text = self.dry_run("bootstrap-reset")
        self.assertLess(text.index("Requires BACKUP"), text.index("bootstrap-reset.py"))
        self.assertNotIn("podman volume ls", text)
        self.assertNotIn("podman pod stop", text)

    def test_teardown_does_not_kill_other_projects_forwarders(self):
        self.assertNotIn("pkill -f 'kubectl port-forward'", (ROOT / "Makefile").read_text())

    def test_remote_credentials_are_private_and_tunnel_stop_uses_control_socket(self):
        source = (ROOT / "Makefile").read_text()
        self.assertNotIn("ssh-keygen -R", source)
        self.assertNotIn("StrictHostKeyChecking=no", source)
        self.assertNotIn("CI_TUNNEL_PIDFILE", source)
        fetch = self.dry_run("scaleway-fetch-creds", "TF=echo")
        self.assertIn("umask 077", fetch)
        self.assertIn("chmod 0700", fetch)
        self.assertIn("chmod 0600", fetch)
        remote = self.dry_run("bootstrap-export-remote", "VB_HOST=example.invalid")
        self.assertIn("umask 077", remote)
        self.assertIn("chmod 0600", remote)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            ssh = path / "ssh"
            events = path / "events"
            ssh.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$EVENT_LOG"\nexit 0\n')
            ssh.chmod(0o700)
            result = subprocess.run(
                ["make", "scaleway-tunnel-stop", "CI_SSH_DIR=" + directory],
                cwd=ROOT, env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                                  EVENT_LOG=str(events)), text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            calls = events.read_text().splitlines()
            self.assertEqual(len(calls), 2)
            self.assertTrue(calls[0].endswith("-O check unused"))
            self.assertTrue(calls[1].endswith("-O exit unused"))

    def image_flow(self, marker):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            log = path / "events"
            tofu = path / "tofu"
            tofu.write_text("""#!/bin/sh
case " $* " in
  *" init "*) echo init >> "$EVENT_LOG" ;;
  *" output -json image_build "*) echo output >> "$EVENT_LOG"; printf '%s' "$BUILD_JSON" ;;
  *" -target=scaleway_instance_server.builder "*) sleep 0.1; echo build >> "$EVENT_LOG" ;;
  *" apply "*) echo import >> "$EVENT_LOG" ;;
  *) exit 8 ;;
esac
""")
            curl = path / "curl"
            curl.write_text("""#!/bin/sh
printf 'poll %s\\n' "$*" >> "$EVENT_LOG"
printf 200
""")
            tofu.chmod(0o700)
            curl.chmod(0o700)
            environment = dict(os.environ, PATH=str(path) + os.pathsep + os.environ["PATH"],
                               EVENT_LOG=str(log), BUILD_JSON=json.dumps(marker))
            result = subprocess.run(
                ["make", "-j8", "scaleway-image-apply", "TF=" + str(tofu),
                 "SCW_IMAGE_ENV=", "SCW_IMAGE_VARS=", "LOCAL_BACKEND="],
                cwd=ROOT, env=environment, text=True, capture_output=True, timeout=15)
            return result, log.read_text().splitlines()

    def test_image_build_poll_import_are_ordered_under_parallel_make(self):
        url = "https://example.invalid/build-fingerprint/builder-uuid/.upload-complete"
        result, events = self.image_flow({"marker_url": url})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(events[:3], ["init", "build", "output"])
        self.assertEqual(events[-1], "import")
        self.assertIn(url, events[3])
        self.assertIn("--connect-timeout 5 --max-time 10", events[3])

    def test_image_missing_marker_never_polls_or_imports(self):
        for marker in ({}, {"marker_url": "http://example.invalid/.upload-complete"}, {"marker_url": 3}):
            with self.subTest(marker=marker):
                result, events = self.image_flow(marker)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, ["init", "build", "output"])

    def test_retention_failure_prevents_image_destroy(self):
        for failure in ("read", "remove", "unchanged", ""):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                state = path / "state"
                state.write_text("scaleway_instance_image.talos\n")
                events = path / "events"
                tofu = path / "tofu"
                tofu.write_text("""#!/bin/sh
printf '%s\\n' "$*" >> "$EVENT_LOG"
case " $* " in
  *" init "*) exit 0 ;;
  *" state list "*) [ "$FAILURE" != read ] || exit 7; cat "$FAKE_STATE" ;;
  *" state rm "*) [ "$FAILURE" != remove ] || exit 8
    [ "$FAILURE" = unchanged ] || : > "$FAKE_STATE" ;;
  *" destroy "*) exit 0 ;;
  *) exit 9 ;;
esac
""")
                tofu.chmod(0o700)
                result = subprocess.run(
                    ["make", "scaleway-image-destroy", "TF=" + str(tofu),
                     "SCW_IMAGE_ENV=", "SCW_IMAGE_VARS=", "LOCAL_BACKEND="],
                    cwd=ROOT, env=dict(os.environ, EVENT_LOG=str(events), FAILURE=failure,
                                      FAKE_STATE=str(state)), text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode == 0, not failure, result.stdout + result.stderr)
                self.assertEqual(" destroy " in events.read_text(), not failure)

    def test_composite_order_and_failure_stop_with_parallel_make(self):
        flows = {
            "scaleway-up": ["scaleway-apply", "scaleway-wait", "scaleway-kubeconfig", "k8s-up", "scaleway-seed-iam"],
            "scaleway-down": ["k8s-down", "scaleway-destroy"],
            "scaleway-teardown": ["dr-verify-backup", "scaleway-down", "scaleway-teardown-vm"],
            "k8s-down": ["flux-bootstrap-destroy", "k8s-storage-destroy", "k8s-security-destroy",
                        "k8s-identity-destroy", "k8s-monitoring-destroy", "k8s-pki-destroy", "k8s-cni-destroy"],
        }
        source = (ROOT / "Makefile").read_text()
        for target, expected in flows.items():
            block = target + ":" + source.split("\n" + target + ":", 1)[1].split("\n\n", 1)[0]
            for fail in ("", expected[0]):
                with self.subTest(target=target, fail=fail), tempfile.TemporaryDirectory() as directory:
                    path = Path(directory)
                    events = path / "events"
                    child = path / "child-make"
                    child.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$EVENT_LOG"\n'
                                     '[ "$1" != "$FAIL_STAGE" ]\n')
                    child.chmod(0o700)
                    # Only the extracted orchestration rule is exercised. Every
                    # external precheck is stubbed; no real cluster/backend access.
                    for name, output in (("curl", "printf 200"), ("kubectl", "exit 0"), ("bash", "exit 0")):
                        stub = path / name
                        stub.write_text("#!/bin/sh\n" + output + "\n")
                        stub.chmod(0o700)
                    makefile = path / "Makefile"
                    makefile.write_text("MAKE := " + str(child) + "\nVB_URL := http://invalid\nKC_FILE := invalid\n" + block + "\n")
                    result = subprocess.run(
                        ["make", "-j8", "-f", str(makefile), target], cwd=path,
                        env=dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                                 EVENT_LOG=str(events), FAIL_STAGE=fail), text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode == 0, not fail, result.stdout + result.stderr)
                    self.assertEqual(events.read_text().splitlines(), expected if not fail else expected[:1])

    def test_nuke_stops_without_commands(self):
        source = (ROOT / "Makefile").read_text()
        block = source.split("\nscaleway-nuke:", 1)[1].split("\n\n", 1)[0]
        self.assertIn("@exit 1", block)
        self.assertNotIn("$(MAKE)", block)


if __name__ == "__main__":
    unittest.main()
