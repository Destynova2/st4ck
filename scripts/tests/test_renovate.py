"""Renovate contract tests; optional real-engine checks never contact a forge.

Set RENOVATE_PACKAGE to an installed renovate package directory to exercise its
validator, local extraction and updater. No dependency installation occurs here.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "renovate.json"
REGISTRY = "clusters/management/versions-configmap.yaml"
MANUAL = {
    "garage_chart_version": "Vendored chart: regenerate/review the chart with its pin.",
    "kamaji_git_ref": "Vendored chart: keep the commit and image compatible.",
    "kamaji_image_tag": "Edge image coupled to the vendored chart commit.",
    "karpenter_version": "Retired upstream Karpenter path; not a native-provider pin.",
    "karpenter_capi_provider_version": "Retired CAPI provider path.",
}
ENGINE = os.environ.get("RENOVATE_PACKAGE")


def config():
    return json.loads(CONFIG.read_text())


def registry_manager():
    return config()["customManagers"][0]


def source_files():
    """Only public dependency sources, never state, outputs or local credentials."""
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    ).decode().split("\0")
    for name in sorted(set(names)):
        path = ROOT / name
        if not name or not path.is_file() or path.is_symlink():
            continue
        if name in ("renovate.json", ".woodpecker.yml", REGISTRY, "bootstrap/platform-pod.yaml"):
            yield name
        elif name.endswith(".tf") and name.split("/")[0] in ("bootstrap", "envs", "modules", "stacks"):
            yield name
        elif re.fullmatch(r"(?:contexts/[^/]+|stacks/[^/]+/flux[^/]*/.*)\.ya?ml", name):
            yield name
        elif re.fullmatch(r"stacks/[^/]+/values[^/]*\.ya?ml", name):
            yield name
        elif path.name in ("Dockerfile", "go.mod", "go.sum", "Chart.yaml"):
            yield name


def safe_env(home):
    # Do not inherit forge tokens, host rules, proxy credentials or Renovate flags.
    return {
        "PATH": os.environ.get("PATH", os.defpath),
        "HOME": str(home),
        "TMPDIR": str(home),
        "LOG_LEVEL": "trace",
        "LOG_FORMAT": "json",
        "RENOVATE_BASE_DIR": str(home / "cache"),
        "RENOVATE_BINARY_SOURCE": "global",
        "RENOVATE_ONBOARDING": "false",
        "RENOVATE_REQUIRE_CONFIG": "optional",
    }


class RenovateConfigTests(unittest.TestCase):
    def test_manual_review_and_no_server_side_execution(self):
        cfg = config()
        self.assertFalse(cfg["automerge"])
        self.assertTrue(cfg["dependencyDashboard"])
        for forbidden in ("token", "hostRules", "repositories", "platform", "postUpgradeTasks"):
            self.assertNotIn(forbidden, cfg)
        self.assertTrue(all(not rule.get("automerge", False) for rule in cfg.get("packageRules", [])))

    def test_every_registry_key_has_one_owner_or_a_manual_reason(self):
        keys = set(yaml.safe_load((ROOT / REGISTRY).read_text())["data"])
        queries = registry_manager()["matchStrings"]
        for key in keys:
            matching = [q for q in queries if f'"depType":"{key}"' in q]
            with self.subTest(key=key):
                self.assertEqual(len(matching), 0 if key in MANUAL else 1)
                if matching:
                    self.assertIn(f'"currentValue":{key},', matching[0])
        self.assertTrue(set(MANUAL) <= keys)
        self.assertEqual(len(queries), len(keys - MANUAL.keys()))

    def test_chart_versions_are_not_application_releases(self):
        queries = registry_manager()["matchStrings"]
        for key, chart in {"flux_version": "flux2", "openbao_version": "openbao",
                           "kubescape_version": "kubescape-operator", "cnpg_version": "cloudnative-pg"}.items():
            query = next(q for q in queries if f'"depType":"{key}"' in q)
            self.assertIn(f'"depName":"{chart}"', query)
            self.assertIn('"datasource":"helm"', query)
            self.assertIn('"registryUrl":"https://', query)
        for key in ("etcd_operator_version", "capi_operator_version"):
            query = next(q for q in queries if f'"depType":"{key}"' in q)
            self.assertIn('"datasource":"docker"', query)

    def test_generated_and_vendored_files_are_excluded(self):
        for pattern in ("hauler-manifest.yaml", "orca.yaml", "**/tests/**", "**/.terraform/**",
                        "kms-output/**", "stacks/kamaji/chart/**", "stacks/storage/chart/**"):
            self.assertIn(pattern, config()["ignorePaths"])

    def test_velero_chart_and_plugin_share_a_human_review_group(self):
        rules = [rule for rule in config()["packageRules"] if rule.get("groupSlug") == "velero-aws"]
        self.assertEqual(len(rules), 1)
        self.assertEqual(set(rules[0]["matchPackageNames"]), {"velero", "velero/velero-plugin-for-aws"})
        self.assertFalse(rules[0]["automerge"])
        self.assertFalse(rules[0]["separateMajorMinor"])
        self.assertIn("compatibility", " ".join(rules[0]["prBodyNotes"]))

    def test_audit_environment_does_not_inherit_credentials(self):
        env = safe_env(Path("/tmp/renovate-test"))
        self.assertNotIn("GITHUB_TOKEN", env)
        self.assertNotIn("RENOVATE_TOKEN", env)
        self.assertNotIn("NODE_OPTIONS", env)
        self.assertEqual(env["RENOVATE_BINARY_SOURCE"], "global")


@unittest.skipUnless(ENGINE, "set RENOVATE_PACKAGE for real Renovate validation/extraction")
class RenovateEngineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.package = Path(ENGINE).resolve()
        cls.node = shutil.which("node")
        if not cls.node or not (cls.package / "dist/renovate.js").is_file():
            raise RuntimeError("RENOVATE_PACKAGE must point to an installed Renovate package; Node is required")
        cls.temp = tempfile.TemporaryDirectory(prefix="st4ck-renovate-test-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.home = Path(cls.temp.name)
        cls.fixture = cls.home / "repo"
        cls.fixture.mkdir()
        cls.hashes = {}
        for name in source_files():
            data = (ROOT / name).read_bytes()
            cls.hashes[name] = hashlib.sha256(data).hexdigest()
            target = cls.fixture / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        # Sentinels prove ignore rules with the real file-discovery engine.
        for name in ("hauler-manifest.yaml", "docs/ignored.yaml", "orca.yaml",
                     "stacks/example/tests/ignored.tf", "stacks/storage/chart/Chart.yaml"):
            target = cls.fixture / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if name.endswith(".tf"):
                target.write_text('module "ignored" { source = "hashicorp/consul/aws"\n version = "0.0.1"\n}\n')
            else:
                target.write_text("apiVersion: v1\nkind: Pod\nmetadata: {name: ignored}\nspec:\n  containers:\n    - {name: ignored, image: example.invalid/ignored:1.0.0}\n")
        cls.baseline = cls.extract(False)
        cls.extracted = cls.extract(True)
        evidence = os.environ.get("RENOVATE_AUDIT_OUTPUT_DIR")
        if evidence:
            output = Path(evidence)
            output.mkdir(parents=True, exist_ok=True, mode=0o700)
            (output / "extraction.json").write_text(json.dumps({
                "renovateVersion": json.loads((cls.package / "package.json").read_text())["version"],
                "sourceHashes": cls.hashes, "baseline": cls.baseline, "configured": cls.extracted,
            }, indent=2) + "\n")

    @classmethod
    def run_node(cls, args, *, input=None):
        result = subprocess.run([cls.node, *args], cwd=cls.fixture, env=safe_env(cls.home),
                                input=input, text=True, capture_output=True, timeout=120)
        if result.returncode:
            raise AssertionError((result.stdout + result.stderr)[-12000:])
        return result.stdout + result.stderr

    @classmethod
    def extract(cls, configured):
        target = cls.fixture / "renovate.json"
        if configured:
            target.write_bytes(CONFIG.read_bytes())
        else:
            target.unlink(missing_ok=True)
        output = cls.run_node([str(cls.package / "dist/renovate.js"), "--platform=local", "--dry-run=extract"])
        records = []
        for line in output.splitlines():
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        errors = [r for r in records if r.get("level", 0) >= 50]
        if errors:
            raise AssertionError(json.dumps(errors, indent=2))
        packages = [r["config"] for r in records if r.get("msg") == "packageFiles"]
        if len(packages) != 1:
            raise AssertionError("Renovate did not emit exactly one extraction result: " + output[-8000:])
        return packages[0]

    def deps(self, manager):
        return [(file["packageFile"], dep) for file in self.extracted.get(manager, []) for dep in file["deps"]]

    def test_strict_official_validator_and_native_re2(self):
        output = self.run_node([str(self.package / "dist/config-validator.js"), "--strict", "--no-global", "renovate.json"])
        self.assertIn("Config validated successfully", output)
        self.assertNotIn("RE2 not usable", output)

    def test_actual_registry_extraction_covers_automatic_keys(self):
        registry = yaml.safe_load((self.fixture / REGISTRY).read_text())["data"]
        deps = {dep["depType"]: dep for path, dep in self.deps("jsonata") if path == REGISTRY}
        self.assertEqual(set(deps), registry.keys() - MANUAL.keys())
        for key, dep in deps.items():
            self.assertEqual(dep["currentValue"], registry[key])
            self.assertNotIn("skipReason", dep)
        self.assertFalse(any(file["packageFile"] == REGISTRY for files in self.baseline.values() for file in files))

    def test_context_defaults_keep_release_prefixes(self):
        deps = {dep["depType"]: dep for path, dep in self.deps("jsonata") if path == "contexts/_defaults.yaml"}
        self.assertEqual(set(deps), {"talos_version", "k8s_version"})
        self.assertTrue(deps["talos_version"]["currentValue"].startswith("v"))
        self.assertFalse(deps["k8s_version"]["currentValue"].startswith("v"))
        self.assertEqual(deps["k8s_version"]["extractVersion"], "^v(?<version>.+)$")

    def test_native_extraction_includes_ci_alias_bootstrap_and_velero(self):
        ci = {dep.get("depName") for _, dep in self.deps("woodpecker") if not dep.get("skipReason")}
        self.assertIn("ghcr.io/opentofu/opentofu", ci)
        self.assertIn("golang", ci)
        self.assertTrue(any(path.startswith("bootstrap/tofu/") for path, _ in self.deps("terraform")))
        all_deps = self.deps("kubernetes") + self.deps("flux") + self.deps("helm-values")
        self.assertTrue(any(dep.get("depName") == "velero/velero-plugin-for-aws" and not dep.get("skipReason")
                            for _, dep in all_deps))
        self.assertTrue(any(path == "bootstrap/platform-pod.yaml" and not dep.get("skipReason")
                            for path, dep in self.deps("kubernetes")))

    def test_generated_and_private_sentinels_are_not_extracted(self):
        paths = {file["packageFile"] for files in self.extracted.values() for file in files}
        self.assertTrue(paths.isdisjoint({"hauler-manifest.yaml", "orca.yaml", "docs/ignored.yaml",
                                        "stacks/example/tests/ignored.tf", "stacks/storage/chart/Chart.yaml"}))

    def test_real_updater_changes_only_one_of_equal_version_values(self):
        # Exercise Renovate's updater, not a Python approximation of JSONata.
        script = r"""
const { pathToFileURL } = await import('node:url');
const { readFile } = await import('node:fs/promises');
const { join } = await import('node:path');
const pkg = process.argv[1];
const load = (p) => import(pathToFileURL(join(pkg, 'dist', p)));
const { GlobalConfig } = await load('config/global.js');
const { extractPackageFile } = await load('modules/manager/custom/jsonata/index.js');
const { doAutoReplace } = await load('workers/repository/update/branch/auto-replace.js');
const { applyPackageRules } = await load('util/package-rules/index.js');
const cfg = JSON.parse(await readFile('renovate.json', 'utf8'));
GlobalConfig.set({localDir: process.cwd()});
const manager = cfg.customManagers[0];
const content = 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: test}\ndata:\n  hydra_version: "0.62.1" # keep\n  kratos_version: "0.62.1"\n';
const extracted = await extractPackageFile(content, 'update-fixture.yaml', manager);
const depIndex = extracted.deps.findIndex((d) => d.depType === 'kratos_version');
const updated = await doAutoReplace({...manager, ...extracted.deps[depIndex], manager: 'jsonata',
  packageFile: 'update-fixture.yaml', depIndex, newValue: '0.63.0', autoReplaceGlobalMatch: false}, content, false);
const groups = [];
for (const [datasource, depName] of [['helm', 'velero'], ['docker', 'velero/velero-plugin-for-aws']]) {
  const result = await applyPackageRules({datasource, depName, packageName: depName,
    updateType: 'major', packageRules: cfg.packageRules});
  groups.push({depName, groupSlug: result.groupSlug, automerge: result.automerge,
    separateMajorMinor: result.separateMajorMinor});
}
const placeholder = await applyPackageRules({manager: 'flux', currentValue: '${velero_version}',
  depName: 'velero', packageName: 'velero', datasource: 'helm', packageRules: cfg.packageRules});
console.log(JSON.stringify({updated, groups, placeholderEnabled: placeholder.enabled}));
"""
        output = self.run_node(["--input-type=module", "-e", script, str(self.package)])
        result = next(json.loads(line) for line in output.splitlines() if line.startswith('{"updated":'))
        self.assertEqual(result["updated"], 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: test}\ndata:\n  hydra_version: "0.62.1" # keep\n  kratos_version: "0.63.0"\n')
        self.assertEqual([group["groupSlug"] for group in result["groups"]], ["velero-aws", "velero-aws"])
        self.assertEqual([group["automerge"] for group in result["groups"]], [False, False])
        self.assertEqual([group["separateMajorMinor"] for group in result["groups"]], [False, False])
        self.assertFalse(result["placeholderEnabled"])


if __name__ == "__main__":
    unittest.main()
