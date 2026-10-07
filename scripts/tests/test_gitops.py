import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

MODULE = Path(__file__).resolve().parents[1] / "verify-gitops.py"
spec = importlib.util.spec_from_file_location("gitops", MODULE)
gitops = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gitops)


class FluxGraphTests(unittest.TestCase):
    def test_reachable_graph_and_render_plan(self):
        objects, owners, children = gitops.load_graph()
        gitops.check_graph(objects, children)
        plan = {row["name"]: row for row in gitops.render_plan(objects)}
        self.assertIn("cnpg", plan)
        self.assertEqual(plan["garage"]["chart"], "./stacks/storage/chart")
        self.assertNotIn("cilium", plan)
        self.assertIn("storage-bootstrap", children)
        self.assertEqual(owners[("postgresql.cnpg.io", "Cluster", "identity", "identity-pg")], "identity-database")
        cm = objects[("v1", "ConfigMap", "storage", "garage-bootstrap")]
        self.assertIn('[[ "$access" =~ ^GK', cm["data"]["bootstrap.sh"])
        dashboard = objects[("v1", "ConfigMap", "monitoring", "grafana-dashboard-platform-overview")]
        self.assertGreater(len(dashboard["data"]["platform-overview.json"]), 100)

    def test_missing_dependency_fails(self):
        with self.assertRaisesRegex(ValueError, "Missing Kustomization"):
            gitops.check_graph({}, {"apps": {"spec": {"dependsOn": [{"name": "absent"}]}}})

    def test_external_secret_cannot_require_a_removed_tofu_target(self):
        with self.assertRaisesRegex(ValueError, "ESO must create"):
            gitops.check_graph({"es": {"kind": "ExternalSecret", "metadata": {
                "name": "grafana-admin", "namespace": "monitoring"},
                "spec": {"target": {"creationPolicy": "Merge"}}}}, {})

    def test_cycle_fails(self):
        with self.assertRaisesRegex(ValueError, "Cyclic"):
            gitops.check_graph({}, {
                "apps": {"spec": {"dependsOn": [{"name": "db"}]}},
                "db": {"spec": {"dependsOn": [{"name": "apps"}]}}})

    def test_bootstrap_helm_release_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Tofu-owned"):
            gitops.check_graph({"hr": {"kind": "HelmRelease", "metadata": {
                "name": "cilium", "namespace": "kube-system"}, "spec": {}}}, {})

    def test_duplicate_object_across_children_fails(self):
        manifest = """apiVersion: v1
kind: ConfigMap
metadata: {name: duplicate, namespace: default}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: duplicate, namespace: default}
"""
        with patch.object(gitops.subprocess, "check_output", return_value=manifest):
            with self.assertRaisesRegex(ValueError, "Double Flux owner"):
                gitops.load_graph()

    def test_undefined_substitution_is_not_silently_emptied(self):
        manifest = """apiVersion: v1
kind: ConfigMap
metadata: {name: values, namespace: default}
data: {version: '${missing_version}'}
"""
        with patch.object(gitops.subprocess, "check_output", return_value=manifest):
            with self.assertRaisesRegex(ValueError, "Missing Flux substitutions"):
                gitops.load_graph()


class SchemaValidationTests(unittest.TestCase):
    def test_empty_render_plan_fails_before_fetching_schemas(self):
        with patch.object(sys, "argv", ["verify-gitops.py", "--render-helm"]), \
                patch.object(gitops, "load_graph", return_value=({}, {}, {})), \
                patch.object(gitops, "prepare_crd_schema") as prepare:
            with self.assertRaisesRegex(ValueError, "No reachable Helm"):
                gitops.main()
        prepare.assert_not_called()

    def test_version_is_exact_and_uses_the_existing_defaults(self):
        self.assertRegex(gitops.kubernetes_version(), r"^1\.[0-9]+\.[0-9]+$")
        self.assertEqual(gitops.kubernetes_version("1.35.6"), "1.35.6")
        for value in ("master", "1.35", "../other", "v1.35.6"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                gitops.kubernetes_version(value)

    def test_helm_uses_target_discovery_and_includes_crds(self):
        command = gitops.helm_command({"name": "adapter", "chart": "prometheus-adapter",
            "namespace": "monitoring", "repo": "https://example.test", "version": "4.11.0"}, "1.35.6")
        self.assertIn("--include-crds", command)
        self.assertEqual(command[command.index("--kube-version") + 1], "1.35.6")
        self.assertEqual(command[command.index("--api-versions") + 1], "apiregistration.k8s.io/v1")
        self.assertEqual(command[command.index("--version") + 1], "4.11.0")

    def test_no_missing_schema_exemption(self):
        result = Mock(stdout=json.dumps({"summary": {"valid": 1, "invalid": 0, "errors": 0, "skipped": 0}}))
        with patch.object(gitops.subprocess, "run", return_value=result) as run:
            self.assertEqual(gitops.validate_rendered("manifest", Path("/schemas"), "1.35.6"), 1)
        command = run.call_args.args[0]
        self.assertNotIn("-ignore-missing-schemas", command)
        self.assertNotIn("-skip", command)
        self.assertIn("-strict", command)
        self.assertEqual(command[command.index("-kubernetes-version") + 1], "1.35.6")
        self.assertTrue(run.call_args.kwargs["check"])

    def test_incomplete_summary_fails_even_with_zero_process_exit(self):
        for failure in ("invalid", "errors", "skipped", "empty"):
            summary = dict(valid=1, invalid=0, errors=0, skipped=0)
            summary["valid" if failure == "empty" else failure] = 0 if failure == "empty" else 1
            with self.subTest(failure=failure), patch.object(gitops.subprocess, "run",
                    return_value=Mock(stdout=json.dumps({"summary": summary}))):
                with self.assertRaisesRegex(ValueError, "Incomplete"):
                    gitops.validate_rendered("manifest", Path("/schemas"), "1.35.6")

    def test_missing_schema_failure_propagates(self):
        with patch.object(gitops.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "kubeconform")):
            with self.assertRaises(subprocess.CalledProcessError):
                gitops.validate_rendered("manifest", Path("/schemas"), "1.35.6")

    def test_strict_schema_retains_maps_and_freeform_defaults(self):
        schema = {"type": "object", "required": ["count"], "properties": {
            "count": {"type": "integer"}, "labels": {"type": "object", "additionalProperties": {"type": "string"}},
            "nested": {"$ref": "#/definitions/nested"},
            "default": {"default": {"properties": {"arbitrary": {"type": "string"}}}}},
            "definitions": {"nested": {"type": "object", "properties": {"name": {"type": "string"}}}}}
        gitops.strict_schema(schema)
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(schema["properties"]["count"]["type"], "integer")
        self.assertIn("null", schema["properties"]["labels"]["type"])
        self.assertEqual(schema["properties"]["labels"]["additionalProperties"], {"type": "string"})
        self.assertEqual(schema["properties"]["nested"]["anyOf"][1], {"type": "null"})
        self.assertFalse(schema["definitions"]["nested"]["additionalProperties"])
        self.assertNotIn("additionalProperties", schema["properties"]["default"]["default"])

    def test_crd_serialization_unions_are_not_unconstrained(self):
        prefix = "io.k8s.apiextensions-apiserver.pkg.apis.apiextensions.v1."
        names = ("JSONSchemaPropsOrBool", "JSONSchemaPropsOrArray", "JSONSchemaPropsOrStringArray")
        definitions = {prefix + name: {"description": "serialization union"} for name in names}
        definitions[prefix + "JSON"] = {"description": "any JSON value"}
        gitops.complete_crd_unions(definitions)
        for name in names:
            self.assertEqual(definitions[prefix + name]["anyOf"][0], {"$ref": f"#/definitions/{prefix}JSONSchemaProps"})
        self.assertEqual(definitions[prefix + names[0]]["anyOf"][1], {"type": "boolean"})
        self.assertEqual(definitions[prefix + names[1]]["anyOf"][1]["items"], {"$ref": f"#/definitions/{prefix}JSONSchemaProps"})
        self.assertEqual(definitions[prefix + names[2]]["anyOf"][1]["items"], {"type": "string"})
        self.assertEqual(definitions[prefix + "JSON"], {"description": "any JSON value"})
        unchanged = json.loads(json.dumps(definitions))
        gitops.complete_crd_unions(definitions)
        self.assertEqual(definitions, unchanged)

    @unittest.skipUnless(shutil.which("kubeconform"), "kubeconform binary unavailable")
    def test_actual_validator_checks_recursive_crd_union_types(self):
        prefix = "io.k8s.apiextensions-apiserver.pkg.apis.apiextensions.v1."
        definitions = {prefix + suffix: {} for suffix in (
            "JSONSchemaPropsOrBool", "JSONSchemaPropsOrArray", "JSONSchemaPropsOrStringArray", "JSON")}
        definitions[prefix + "JSONSchemaProps"] = {"type": "object", "properties": {
            "type": {"type": "string"}, "items": {"$ref": f"#/definitions/{prefix}JSONSchemaPropsOrArray"},
            "additionalProperties": {"$ref": f"#/definitions/{prefix}JSONSchemaPropsOrBool"},
            "dependencies": {"type": "object", "additionalProperties": {
                "$ref": f"#/definitions/{prefix}JSONSchemaPropsOrStringArray"}},
            "default": {"$ref": f"#/definitions/{prefix}JSON"}}}
        gitops.complete_crd_unions(definitions)
        schema = {"type": "object", "properties": {"apiVersion": {"type": "string"}, "kind": {"type": "string"},
            "metadata": {"type": "object", "additionalProperties": True},
            "spec": {"$ref": f"#/definitions/{prefix}JSONSchemaProps"}}, "definitions": definitions}
        gitops.strict_schema(schema)
        cases = [({"items": 42}, 1), ({"additionalProperties": 42}, 1), ({"dependencies": {"x": 42}}, 1),
                 ({"items": {"type": "string"}}, 0), ({"items": [{"type": "string"}]}, 0),
                 ({"additionalProperties": False}, 0), ({"additionalProperties": {"type": "integer"}}, 0),
                 ({"dependencies": {"x": ["other"]}}, 0), ({"dependencies": {"x": {"type": "object"}}}, 0),
                 ({"default": {"arbitrary": [42, False, None]}}, 0)]
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "sample.json"
            path.write_text(json.dumps(schema))
            for spec, expected in cases:
                doc = {"apiVersion": "example.test/v1", "kind": "Sample", "metadata": {"name": "sample"}, "spec": spec}
                result = subprocess.run(["kubeconform", "-strict", "-schema-location", str(path)],
                                        input=json.dumps(doc), text=True, capture_output=True)
                with self.subTest(spec=spec):
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    @unittest.skipUnless(shutil.which("kubeconform"), "kubeconform binary unavailable")
    def test_actual_validator_rejects_bad_types_and_unknown_nested_fields(self):
        schema = {"type": "object", "properties": {"apiVersion": {"type": "string"}, "kind": {"type": "string"},
            "metadata": {"type": "object", "properties": {"name": {"type": "string"}}},
            "spec": {"$ref": "#/definitions/spec"}}, "required": ["spec"],
            "definitions": {"spec": {"type": "object", "properties": {"count": {"type": "integer"}}, "required": ["count"]}}}
        gitops.strict_schema(schema)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "sample.json"
            path.write_text(json.dumps(schema))
            for spec, code in (({"count": 1}, 0), ({"count": "one"}, 1), ({"count": 1, "typo": True}, 1), ({}, 1)):
                doc = {"apiVersion": "example.test/v1", "kind": "Sample", "metadata": {"name": "sample"}, "spec": spec}
                result = subprocess.run(["kubeconform", "-strict", "-schema-location", str(path)],
                                        input=json.dumps(doc), text=True, capture_output=True)
                with self.subTest(spec=spec):
                    self.assertEqual(result.returncode, code, result.stdout + result.stderr)

    def test_velero_plugin_pair_is_checked_from_actual_rendered_images(self):
        for server, plugin, supported in (("1.17.1", "1.13.2", True), ("1.18.2", "1.14.3", True),
                                         ("1.17.1", "1.14.0", False), ("1.19.0", "1.15.0", False),
                                         ("1.17.1", "1.13.3-rc.1", False)):
            doc = {"kind": "Deployment", "metadata": {"name": "custom-release-name"}, "spec": {"template": {"spec": {
                "containers": [{"name": "velero", "image": f"docker.io/velero/velero:v{server}"}],
                "initContainers": [{"name": "velero-plugin-for-aws", "image": f"velero/velero-plugin-for-aws:v{plugin}"}]}}}}
            with self.subTest(server=server, plugin=plugin):
                if supported:
                    gitops.check_velero_compatibility(json.dumps(doc))
                else:
                    with self.assertRaises(ValueError):
                        gitops.check_velero_compatibility(json.dumps(doc))


if __name__ == "__main__":
    unittest.main()
