"""Run the bootstrap Git shell with a strict mock, never a real Git push."""

import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
GITEA = ROOT / "bootstrap/tofu/gitea.tf"


class GitPushTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.log = self.root / "calls.jsonl"
        self.password = "quoted '\" dollar $ backslash \\ and\nnewline"
        self.env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                        GITEA_ADMIN="talos", GITEA_PASSWORD=self.password,
                        GIT_SOURCE_URL="https://source.invalid/repo.git",
                        GITEA_PUSH_URL="http://platform-gitea:3000/talos/talos.git",
                        CALL_LOG=str(self.log))
        fake = self.root / "git"
        fake.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
            import json, os, pathlib, sys
            args = sys.argv[1:]
            stage = next((a for a in args if a in ("clone", "remote", "push")), None)
            if stage is None:
                raise SystemExit(99)
            with open(os.environ["CALL_LOG"], "a") as log:
                log.write(json.dumps({"args": args, "stage": stage,
                    "header": os.environ.get("GIT_CONFIG_VALUE_0"),
                    "header_key": os.environ.get("GIT_CONFIG_KEY_0"),
                    "redirects": os.environ.get("GIT_CONFIG_VALUE_1")}) + "\\n")
            if stage == os.environ.get("FAIL_STAGE"):
                raise SystemExit(42)
            if stage == "clone":
                pathlib.Path(args[-1]).mkdir()
                (pathlib.Path(args[-1]) / "owned-temporary-file").touch()
        '''))
        fake.chmod(0o700)
        source = GITEA.read_text().split('resource "terraform_data" "git_push" {', 1)[1]
        self.command = textwrap.dedent(source.split("command = <<-SH\n", 1)[1].split("\n    SH", 1)[0])
        self.command = self.command.replace("/tmp/gitea-push.XXXXXX", str(self.root / "gitea-push.XXXXXX"))
        self.command = self.command.replace("/source", str(self.source))

    def run_push(self, fail=None):
        env = dict(self.env)
        if fail:
            env["FAIL_STAGE"] = fail
        result = subprocess.run(["sh", "-c", self.command], env=env, capture_output=True, text=True, timeout=10)
        self.assertNotIn(self.password, result.stdout + result.stderr)
        self.assertFalse(list(self.root.glob("gitea-push.*")), "Only the owned temporary clone must be removed")
        return result, [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_pushes_head_without_force_or_plaintext_cli_credentials(self):
        (self.source / ".git").mkdir()
        untouched = self.root / "unrelated"
        untouched.touch()
        result, calls = self.run_push()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["stage"] for c in calls], ["clone", "remote", "push"])
        self.assertIn("--no-local", calls[0]["args"])
        self.assertEqual(calls[-1]["args"], ["push", "gitea", "HEAD:refs/heads/main"])
        self.assertEqual(calls[-1]["header_key"], "http." + self.env["GITEA_PUSH_URL"] + ".extraHeader")
        self.assertEqual(calls[-1]["redirects"], "false")
        encoded = calls[-1]["header"].removeprefix("Authorization: Basic ")
        self.assertEqual(base64.b64decode(encoded).decode(), "talos:" + self.password)
        self.assertNotIn(self.password, json.dumps([c["args"] for c in calls]))
        self.assertTrue(untouched.exists())
        self.assertTrue((self.source / ".git").exists())

    def test_worktree_git_file_is_a_local_source(self):
        (self.source / ".git").write_text("gitdir: elsewhere")
        _, calls = self.run_push()
        self.assertIn(str(self.source), calls[0]["args"])

    def test_remote_source_is_used_without_local_checkout(self):
        _, calls = self.run_push()
        self.assertIn(self.env["GIT_SOURCE_URL"], calls[0]["args"])

    def test_clone_failure_stops_before_remote_and_push(self):
        result, calls = self.run_push("clone")
        self.assertEqual(result.returncode, 42)
        self.assertEqual([c["stage"] for c in calls], ["clone"])

    def test_remote_failure_stops_before_push(self):
        result, calls = self.run_push("remote")
        self.assertEqual(result.returncode, 42)
        self.assertEqual([c["stage"] for c in calls], ["clone", "remote"])

    def test_push_rejection_propagates_status(self):
        result, calls = self.run_push("push")
        self.assertEqual(result.returncode, 42)
        self.assertEqual([call["stage"] for call in calls], ["clone", "remote", "push"])
        self.assertEqual(calls[-1]["args"], ["push", "gitea", "HEAD:refs/heads/main"])

    def test_fresh_repository_disables_provider_initial_commit(self):
        block = GITEA.read_text().split('resource "gitea_repository" "talos" {', 1)[1].split("\n}", 1)[0]
        self.assertRegex(block, r"(?m)^\s*auto_init\s*=\s*false\s*$")

    def test_secret_resources_keep_addresses_and_secure_permissions(self):
        source = GITEA.read_text()
        for name in ("gitea_client", "gitea_secret"):
            block = source.split(f'resource "local_file" "{name}" {{', 1)[1].split("\n}", 1)[0]
            self.assertIn('file_permission      = "0600"', block)
            self.assertIn('directory_permission = "0700"', block)

    def test_no_false_automatic_ci_or_obsolete_secrets(self):
        source = (ROOT / "bootstrap/tofu/woodpecker.tf").read_text()
        self.assertNotIn('resource "terraform_data" "wp_setup"', source)
        self.assertNotIn("--save-cookies", source)
        self.assertNotIn("cluster-secrets-token", source)


if __name__ == "__main__":
    unittest.main()
