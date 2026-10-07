"""Offline image contracts and execution of the rendered cloud-init build script."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
IMAGE = ROOT / "envs/scaleway/image"
BUILDER_ID = "22222222-2222-2222-2222-222222222222"
SCHEMATIC = "18d0321d7fb289f707a76e1deeaa5c97e62209722cbf4bc533a5d51eb666885f"


def tofu_environment(directory):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("TF_", "TOFU_", "SCW_"))}
    env.update(TF_IN_AUTOMATION="1", TF_INPUT="0", CHECKPOINT_DISABLE="1",
               SCW_CONFIG_PATH=str(directory / "no-scaleway-config"))
    return env


def run_tofu(directory, *args, input_text=None):
    return subprocess.run(
        ["tofu", *args], cwd=directory, env=tofu_environment(directory),
        input=input_text, capture_output=True, text=True, timeout=120,
    )


class ImageProviderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="image-mock-tests-")
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        cls.directory = directory
        # Never copy backend.tf or state: all applies use mock_provider, and
        # only the already installed provider schema is loaded offline.
        for name in ("main.tf", "variables.tf", "outputs.tf", "cloud-init.yml.tpl",
                     ".terraform.lock.hcl"):
            shutil.copy2(IMAGE / name, directory / name)
        shutil.copytree(IMAGE / "tests", directory / "tests")
        (directory / ".terraform").mkdir()
        (directory / ".terraform/providers").symlink_to(IMAGE / ".terraform/providers")
        result = run_tofu(directory, "validate", "-no-color")
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        result = run_tofu(directory, "test", "-json", "-verbose", "-no-color")
        cls.events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        if result.returncode:
            raise AssertionError("\n".join(
                event.get("@message", "") + ": " + event.get("diagnostic", {}).get("detail", "")
                for event in cls.events if event.get("type") not in ("test_plan", "test_state")
            ) + result.stderr)
        cls.plans = {event["@testrun"]: event["test_plan"] for event in cls.events
                     if event.get("type") == "test_plan"}
        cls.states = {event["@testrun"]: event["test_state"]["values"] for event in cls.events
                      if event.get("type") == "test_state"}

    def change(self, run, address):
        return next(change["change"] for change in self.plans[run]["resource_changes"]
                    if change["address"] == address)

    def test_all_hcl_runs_pass(self):
        summary = next(event["test_summary"] for event in self.events
                       if event.get("type") == "test_summary")
        self.assertEqual(summary["failed"], 0)
        self.assertEqual(summary["errored"], 0)
        self.assertEqual(summary["skipped"], 0)

    def test_targeted_contract_requires_builder_but_not_imports(self):
        state = self.states["targeted_builder_contract"]
        addresses = {resource["address"] for resource in state["root_module"]["resources"]}
        self.assertIn("terraform_data.builder_config", addresses)
        self.assertIn("scaleway_instance_server.builder", addresses)
        self.assertFalse(any("snapshot" in address or "instance_image" in address for address in addresses))
        output = state["outputs"]["image_build"]
        self.assertFalse(output["sensitive"])
        contract = output["value"]
        self.assertEqual(contract["marker_url"],
                         f'https://{contract["bucket"]}.s3.{contract["region"]}.scw.cloud/{contract["marker_key"]}')
        self.assertIn(f"/builders/{BUILDER_ID}/", contract["marker_key"])

    def test_rendered_config_and_import_output_share_artifact(self):
        state = self.states["baseline"]
        resources = {resource["address"]: resource["values"] for resource in state["root_module"]["resources"]}
        contract = state["outputs"]["image_build"]["value"]
        config = yaml.safe_load(resources["scaleway_instance_server.builder"]["user_data"]["cloud-init"])
        script = next(entry["content"] for entry in config["write_files"]
                      if entry["path"] == "/usr/local/sbin/build-talos-image")
        self.assertIn(f's3://{contract["bucket"]}/{contract["artifact_key"]}', script)
        self.assertIn(contract["marker_key"].replace(BUILDER_ID, "$instance_id"), script)
        for address in ("scaleway_instance_snapshot.talos", "scaleway_block_snapshot.talos"):
            self.assertEqual(resources[address]["import"][0]["key"], contract["artifact_key"])

    def test_template_change_versions_artifact_and_builder_config(self):
        template = self.directory / "cloud-init.yml.tpl"
        original = template.read_text()
        try:
            template.write_text(original + "\n# Test-only recipe revision\n")
            result = run_tofu(self.directory, "test", "-json", "-verbose", "-no-color")
        finally:
            template.write_text(original)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        errors = [event.get("diagnostic") for event in events if event.get("type") == "diagnostic"]
        self.assertEqual(result.returncode, 0, str(errors) + result.stderr)
        state = next(event["test_state"]["values"] for event in events
                     if event.get("type") == "test_state" and event.get("@testrun") == "baseline")
        baseline = self.states["baseline"]
        self.assertNotEqual(state["outputs"]["image_build"]["value"]["artifact_key"],
                            baseline["outputs"]["image_build"]["value"]["artifact_key"])
        hashes = []
        for values in (state, baseline):
            resource = next(resource for resource in values["root_module"]["resources"]
                            if resource["address"] == "terraform_data.builder_config")
            hashes.append(resource["values"]["triggers_replace"]["cloud_init"])
        self.assertNotEqual(*hashes)

    def test_meaningful_changes_replace_builder(self):
        for run in ("version_change", "schematic_change_same_short_prefix", "credential_rotation"):
            with self.subTest(run=run):
                for address in ("terraform_data.builder_config", "scaleway_instance_server.builder"):
                    self.assertEqual(self.change(run, address)["actions"], ["delete", "create"])

    def test_unchanged_inputs_do_not_replace_resources(self):
        for change in self.plans["unchanged_inputs"]["resource_changes"]:
            self.assertEqual(change["change"]["actions"], ["no-op"], change["address"])

    def test_tag_only_changes_do_not_replace_builder(self):
        self.assertEqual(self.change("owner_tag_change", "terraform_data.builder_config")["actions"],
                         ["no-op"])
        self.assertEqual(self.change("owner_tag_change", "scaleway_instance_server.builder")["actions"],
                         ["update"])

    def test_credentials_do_not_change_public_artifact_key(self):
        for address in ("scaleway_instance_snapshot.talos", "scaleway_block_snapshot.talos"):
            change = self.change("credential_rotation", address)
            self.assertEqual(change["before"]["import"][0]["key"], change["after"]["import"][0]["key"])

    def test_both_imports_change_with_image_inputs(self):
        for run in ("version_change", "schematic_change_same_short_prefix"):
            for address in ("scaleway_instance_snapshot.talos", "scaleway_block_snapshot.talos"):
                with self.subTest(run=run, address=address):
                    change = self.change(run, address)
                    self.assertNotEqual(change["before"]["import"][0]["key"],
                                        change["after"]["import"][0]["key"])


# All potentially networked/build commands resolve to this test-only executable.
FAKE_TOOL = r'''
import json
import os
from pathlib import Path
import shutil
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
step = name
if name == "qemu-img":
    step += "-" + args[0]
elif name == "s3cmd":
    step += "-marker" if args[-1].endswith("/.upload-complete") else "-artifact"
with open(os.environ["CALL_LOG"], "a") as log:
    log.write(json.dumps({"step": step, "args": args}) + "\n")
if step == os.environ.get("FAIL_STEP"):
    sys.exit(23)
if name == "cloud-init":
    assert args == ["query", "v1.instance_id"]
    print(os.environ["BUILDER_ID"])
elif name == "wget":
    Path(args[args.index("-O") + 1]).write_bytes(b"" if os.environ.get("EMPTY_DOWNLOAD") else b"raw.zst")
elif name == "zstd":
    Path(args[args.index("-o") + 1]).write_bytes(b"raw")
elif name == "qemu-img" and args[0] == "convert":
    Path(args[-1]).write_bytes(b"qcow2")
elif name == "s3cmd":
    assert args[0] == "put"
    destination = Path(os.environ["FAKE_S3"]) / args[-1].removeprefix("s3://")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args[-2], destination)
'''


class ImageCloudInitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prefix = f"talos/v1.12.4/{SCHEMATIC}/" + "a" * 64
        cls.artifact = cls.prefix + "/scaleway-amd64.qcow2"
        variables = dict(
            talos_version="v1.12.4", schematic_id=SCHEMATIC,
            access_key="TESTACCESS", secret_key="TESTSECRET", region="fr-par",
            bucket_name="image-test", artifact_key=cls.artifact, artifact_prefix=cls.prefix,
        )
        expression = "jsonencode(templatefile(%s, %s))" % (
            json.dumps(str(IMAGE / "cloud-init.yml.tpl")), json.dumps(variables))
        with tempfile.TemporaryDirectory() as temporary:
            result = run_tofu(Path(temporary), "console", input_text=expression + "\n")
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        cls.config = yaml.safe_load(json.loads(json.loads(result.stdout)))
        cls.script = next(entry["content"] for entry in cls.config["write_files"]
                          if entry["path"] == "/usr/local/sbin/build-talos-image")

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="image-script-tests-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.s3 = self.directory / "s3"
        self.s3.mkdir()
        self.log = self.directory / "calls.jsonl"
        for tool in ("cloud-init", "wget", "zstd", "qemu-img", "s3cmd"):
            path = self.bin / tool
            path.write_text(f"#!{sys.executable}\n" + FAKE_TOOL)
            path.chmod(0o755)
        self.path = self.directory / "build.sh"
        self.path.write_text(self.script)

    def execute(self, **overrides):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.defpath,
                   CALL_LOG=str(self.log), FAKE_S3=str(self.s3), BUILDER_ID=BUILDER_ID,
                   TMPDIR=str(self.directory), FAIL_STEP="", EMPTY_DOWNLOAD="")
        env.update(overrides)
        result = subprocess.run(["/bin/bash", str(self.path)], env=env, capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(list(self.directory.glob("talos-image.*")), [])
        return result

    def marker(self, instance_id=BUILDER_ID):
        return self.s3 / "image-test" / self.prefix / "builders" / instance_id / ".upload-complete"

    def test_runcmd_is_one_fail_fast_script(self):
        self.assertEqual(self.config["runcmd"], [["bash", "/usr/local/sbin/build-talos-image"]])
        self.assertIn("set -euo pipefail", self.script)
        cfg = next(entry for entry in self.config["write_files"] if entry["path"] == "/root/.s3cfg")
        self.assertEqual(cfg["permissions"], "0600")
        result = subprocess.run(["/bin/bash", "-n", str(self.path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_success_uploads_private_artifact_then_current_public_marker(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker().read_text().strip(), self.artifact)
        self.assertEqual((self.s3 / "image-test" / self.artifact).read_bytes(), b"qcow2")
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual([call["step"] for call in calls], [
            "cloud-init", "wget", "zstd", "qemu-img-convert", "qemu-img-check",
            "s3cmd-artifact", "s3cmd-marker",
        ])
        self.assertIn("--acl-private", calls[-2]["args"])
        self.assertIn("--acl-public", calls[-1]["args"])
        self.assertFalse((self.s3 / "image-test/.upload-complete").exists())
        self.assertNotIn("TESTSECRET", result.stdout + result.stderr)

    def test_each_failure_prevents_marker_and_later_steps(self):
        for step in ("cloud-init", "wget", "zstd", "qemu-img-convert", "qemu-img-check",
                     "s3cmd-artifact", "s3cmd-marker"):
            with self.subTest(step=step):
                self.log.unlink(missing_ok=True)
                result = self.execute(FAIL_STEP=step)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.marker().exists())
                calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                self.assertEqual(calls[-1]["step"], step)
                self.assertNotIn("Image ready", result.stdout)

    def test_empty_download_and_invalid_instance_id_fail_closed(self):
        for overrides in ({"EMPTY_DOWNLOAD": "1"}, {"BUILDER_ID": ""}, {"BUILDER_ID": "invalid/id"}):
            with self.subTest(overrides=overrides):
                result = self.execute(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.marker().exists())

    def test_previous_builder_marker_cannot_certify_failed_rebuild(self):
        previous = "11111111-1111-1111-1111-111111111111"
        self.assertEqual(self.execute(BUILDER_ID=previous).returncode, 0)
        self.assertTrue(self.marker(previous).exists())
        self.assertNotEqual(self.execute(FAIL_STEP="wget").returncode, 0)
        self.assertFalse(self.marker().exists())
        self.assertTrue(self.marker(previous).exists())


if __name__ == "__main__":
    unittest.main()
