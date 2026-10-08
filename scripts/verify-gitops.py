#!/usr/bin/env python3
"""Validate the reachable Flux graph, not parked manifests in stacks/*/flux*."""

import argparse
import json
import re
import subprocess
import tempfile
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP_RELEASES = {"cilium", "local-path-provisioner", "openbao-infra",
                      "openbao-app", "cert-manager", "external-secrets", "flux2"}
BOOTSTRAP_NAMESPACES = {"secrets", "cert-manager", "external-secrets", "flux-system",
                        "kube-system", "local-path-storage"}
VARIABLE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def kubernetes_version(value=None):
    version = value or yaml.safe_load((ROOT / "contexts/_defaults.yaml").read_text())["k8s_version"]
    if not isinstance(version, str) or not re.fullmatch(r"1\.[0-9]+\.[0-9]+", version):
        raise ValueError(f"Expected an exact Kubernetes version, got {version!r}")
    return version


def strict_schema(schema):
    """Close typed objects, retaining maps and Kubernetes optional null fields."""
    if not isinstance(schema, dict):
        return
    properties = schema.get("properties", {})
    if properties:
        schema.setdefault("additionalProperties", False)
    for name, child in properties.items():
        strict_schema(child)
        if name not in schema.get("required", []):
            # The referenced registry does not normalize optional nulls like its
            # standalone variant does. Keep null annotations/labels API-valid.
            if "$ref" in child:
                properties[name] = {"anyOf": [child, {"type": "null"}]}
            elif "type" in child:
                types = child["type"] if isinstance(child["type"], list) else [child["type"]]
                child["type"] = list(dict.fromkeys([*types, "null"]))
    for key in ("definitions", "patternProperties"):
        for child in schema.get(key, {}).values():
            strict_schema(child)
    for key in ("items", "additionalProperties", "additionalItems", "not"):
        child = schema.get(key)
        for item in child if isinstance(child, list) else [child]:
            strict_schema(item)
    for key in ("allOf", "anyOf", "oneOf"):
        for child in schema.get(key, []):
            strict_schema(child)


def prepare_crd_schema(directory, version):
    """Use the recursive Kubernetes schema omitted from the standalone catalog."""
    base = ("https://raw.githubusercontent.com/yannh/kubernetes-json-schema/"
            f"master/v{version}-local/")
    for name in ("customresourcedefinition-apiextensions-v1.json", "_definitions.json"):
        with urllib.request.urlopen(base + name, timeout=60) as response:
            schema = json.load(response)
        if name == "_definitions.json":
            complete_crd_unions(schema["definitions"])
        strict_schema(schema)
        (directory / name).write_text(json.dumps(schema))


def complete_crd_unions(definitions):
    # Kubernetes OpenAPI v2 leaves these Go serialization unions unconstrained.
    # Reconstitute their declared types, but leave arbitrary JSON values alone.
    prefix = "io.k8s.apiextensions-apiserver.pkg.apis.apiextensions.v1."
    schema_ref = {"$ref": f"#/definitions/{prefix}JSONSchemaProps"}
    alternatives = {
        "JSONSchemaPropsOrBool": {"type": "boolean"},
        "JSONSchemaPropsOrArray": {"type": "array", "items": schema_ref},
        "JSONSchemaPropsOrStringArray": {"type": "array", "items": {"type": "string"}},
    }
    for name, alternative in alternatives.items():
        definition = definitions[prefix + name]
        if set(definition) <= {"description"}:
            definition["anyOf"] = [schema_ref, alternative]


def validate_rendered(rendered, directory, version):
    command = ["kubeconform", "-strict", "-kubernetes-version", version,
               "-schema-location", str(directory / "{{.ResourceKind}}{{.KindSuffix}}.json"),
               "-schema-location", "default", "-schema-location",
               "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/"
               "{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json",
               "-summary", "-output", "json"]
    result = subprocess.run(command, input=rendered, text=True, capture_output=True, check=True)
    summary = json.loads(result.stdout)["summary"]
    if any(summary[key] for key in ("invalid", "errors", "skipped")) or not summary["valid"]:
        raise ValueError(f"Incomplete schema validation: {summary}")
    return summary["valid"]


def helm_command(row, version):
    # Offline Helm has no API discovery. prometheus-adapter otherwise selects
    # the removed APIService v1beta1 even when --kube-version is supplied.
    command = ["helm", "template", row["name"], row["chart"], "--namespace", row["namespace"],
               "--kube-version", version, "--api-versions", "apiregistration.k8s.io/v1", "--include-crds"]
    if "repo" in row:
        command.extend(["--repo", row["repo"], "--version", row["version"]])
    return command


def check_velero_compatibility(rendered):
    # Official matrix: github.com/velero-io/velero-plugin-for-aws#compatibility
    # New server branches require an explicit matrix review, not an assumption.
    compatible = {"1.17": "1.13", "1.18": "1.14"}
    deployments = [d for d in yaml.safe_load_all(rendered) if d and d.get("kind") == "Deployment"
                   and any(c.get("name") == "velero" for c in d["spec"]["template"]["spec"].get("containers", []))]
    if len(deployments) != 1:
        raise ValueError("Expected one rendered Velero Deployment")
    pod = deployments[0]["spec"]["template"]["spec"]
    images = {c["name"]: c["image"] for key in ("containers", "initContainers") for c in pod.get(key, [])}
    versions = []
    for name in ("velero", "velero-plugin-for-aws"):
        match = re.search(r":v?([0-9]+\.[0-9]+)\.[0-9]+$", images.get(name, ""))
        if not match:
            raise ValueError(f"Expected stable versioned image for {name}")
        versions.append(match[1])
    server, plugin = versions
    if compatible.get(server) != plugin:
        raise ValueError(f"Unsupported Velero/AWS plugin pairing: {server}.x / {plugin}.x; review the upstream matrix")


def identity(doc):
    meta = doc["metadata"]
    return (doc["apiVersion"].split("/")[0], doc["kind"],
            meta.get("namespace", ""), meta["name"])


def load_graph(root=ROOT):
    registry = yaml.safe_load((root / "clusters/management/versions-configmap.yaml").read_text())["data"]
    queue = [("management", "clusters/management", dict(registry,
              s3_url="http://garage.garage.svc.cluster.local:3900", velero_bucket="velero-backups"))]
    objects, owners, paths, children = {}, {}, {}, {}
    while queue:
        owner, path, variables = queue.pop(0)
        if owner in paths:
            raise ValueError(f"Repeated Flux Kustomization: {owner}")
        paths[owner] = path
        rendered = subprocess.check_output(["kubectl", "kustomize", str(root / path)], text=True)
        for doc in yaml.safe_load_all(rendered):
            if not doc:
                continue
            key = identity(doc)
            if key in objects:
                raise ValueError(f"Double Flux owner: {key}: {owners[key]} / {owner}")
            # Model only Flux substitutions, leaving ESO Go templates untouched.
            if doc["metadata"].get("annotations", {}).get("kustomize.toolkit.fluxcd.io/substitute") != "disabled":
                serialized = yaml.safe_dump(doc)
                missing = set(VARIABLE.findall(serialized)) - variables.keys()
                if missing:
                    raise ValueError(f"Missing Flux substitutions in {key}: {sorted(missing)}")
                doc = yaml.safe_load(VARIABLE.sub(lambda m: str(variables[m[1]]), serialized))
            objects[key], owners[key] = doc, owner
            if doc.get("apiVersion") == "kustomize.toolkit.fluxcd.io/v1" and doc["kind"] == "Kustomization":
                name, spec = doc["metadata"]["name"], doc["spec"]
                children[name] = doc
                child_vars = {}
                for source in spec.get("postBuild", {}).get("substituteFrom", []):
                    if source != {"kind": "ConfigMap", "name": "platform-versions"}:
                        raise ValueError(f"Unmodelled substituteFrom in {name}: {source}")
                    child_vars.update(registry)
                child_vars.update(spec.get("postBuild", {}).get("substitute", {}))
                queue.append((name, spec["path"], child_vars))
    return objects, owners, children


def check_graph(objects, children):
    edges = {name: [d["name"] for d in doc["spec"].get("dependsOn", [])]
             for name, doc in children.items()}
    visiting, done = set(), set()

    def visit(name):
        if name not in edges:
            raise ValueError(f"Missing Kustomization dependency: {name}")
        if name in visiting:
            raise ValueError(f"Cyclic Kustomization dependency: {name}")
        if name in done:
            return
        visiting.add(name)
        for dependency in edges[name]:
            visit(dependency)
        visiting.remove(name)
        done.add(name)

    for name in edges:
        visit(name)
    releases = {(d["metadata"].get("namespace", ""), d["metadata"]["name"])
                for d in objects.values() if d["kind"] == "HelmRelease"}
    for doc in objects.values():
        kind, meta = doc["kind"], doc["metadata"]
        name, ns = meta["name"], meta.get("namespace", "")
        if kind == "Namespace" and name in BOOTSTRAP_NAMESPACES:
            raise ValueError(f"Bootstrap namespace must remain Tofu-owned: {name}")
        if kind in {"ClusterSecretStore", "ClusterIssuer"}:
            raise ValueError(f"Bootstrap object must remain Tofu-owned: {kind}/{name}")
        if kind == "HelmRelease":
            if doc["spec"].get("releaseName", name) in BOOTSTRAP_RELEASES:
                raise ValueError(f"Bootstrap Helm release must remain Tofu-owned: {name}")
            for dep in doc["spec"].get("dependsOn", []):
                if (dep.get("namespace", ns), dep["name"]) not in releases:
                    raise ValueError(f"Missing HelmRelease dependency: {ns}/{name} -> {dep}")
        if kind == "Job" and "ttlSecondsAfterFinished" in doc["spec"]:
            raise ValueError(f"Flux waits for retained Job completion: {ns}/{name}")
        if kind == "ExternalSecret" and doc["spec"].get("target", {}).get("creationPolicy", "Owner") != "Owner":
            raise ValueError(f"ESO must create and own day-1 targets: {ns}/{name}")
    for stack in ("identity", "security", "storage", "autoscaling"):
        # These are migration-only states. No live Kubernetes resource is allowed back.
        for path in (ROOT / "stacks" / stack).glob("*.tf"):
            if re.search(r'^resource\s+"(?:helm_release|kubernetes_[^"]+|kubectl_manifest)"',
                         path.read_text(), re.MULTILINE):
                raise ValueError(f"Kubernetes resource reintroduced outside Flux: {path}")


def render_plan(objects):
    docs = list(objects.values())
    repos = {(d["metadata"].get("namespace", ""), d["metadata"]["name"]): d["spec"]["url"]
             for d in docs if d["kind"] == "HelmRepository"}
    configs = {(d["metadata"].get("namespace", ""), d["metadata"]["name"]): d.get("data", {})
               for d in docs if d["kind"] == "ConfigMap"}
    plan = []
    for doc in docs:
        if doc["kind"] != "HelmRelease":
            continue
        spec, meta = doc["spec"], doc["metadata"]
        chart = spec["chart"]["spec"]
        source = chart["sourceRef"]
        row = {"name": spec.get("releaseName", meta["name"]), "namespace": meta["namespace"],
               "chart": chart["chart"], "values": []}
        if source["kind"] == "GitRepository":
            if not (ROOT / chart["chart"] / "Chart.yaml").is_file():
                raise ValueError(f"Missing vendored chart: {chart['chart']}")
        else:
            row.update(repo=repos[(source.get("namespace", meta["namespace"]), source["name"])],
                       version=chart["version"])
            if not row["version"]:
                raise ValueError(f"Unresolved chart version: {meta['name']}")
        for ref in spec.get("valuesFrom", []):
            if ref["kind"] == "ConfigMap":
                row["values"].append(configs[(meta["namespace"], ref["name"])][ref.get("valuesKey", "values.yaml")])
        if "values" in spec:
            row["values"].append(yaml.safe_dump(spec["values"]))
        plan.append(row)
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render-plan", action="store_true")
    parser.add_argument("--render-helm", action="store_true")
    parser.add_argument("--kubernetes-version", help="Exact target version; defaults to contexts/_defaults.yaml")
    args = parser.parse_args()
    objects, _, children = load_graph()
    check_graph(objects, children)
    plan = render_plan(objects)
    if args.render_helm:
        if not plan:
            raise ValueError("No reachable Helm releases to validate")
        version = kubernetes_version(args.kubernetes_version)
        with tempfile.TemporaryDirectory(prefix="st4ck-render-") as tmp:
            prepare_crd_schema(Path(tmp), version)
            total = 0
            for row in plan:
                command = helm_command(row, version)
                for i, values in enumerate(row["values"]):
                    path = Path(tmp) / f"{row['name']}-{i}.yaml"
                    path.write_text(values)
                    command.extend(["-f", str(path)])
                rendered = subprocess.check_output(command, cwd=ROOT, text=True)
                if row["chart"] == "velero":
                    check_velero_compatibility(rendered)
                try:
                    count = validate_rendered(rendered, Path(tmp), version)
                except subprocess.CalledProcessError as error:
                    raise SystemExit(f"Schema validation failed for {row['name']}:\n{error.stdout}\n{error.stderr}") from error
                total += count
                print(f"Validated {row['namespace']}/{row['name']}: {count} resources, 0 skipped", flush=True)
            print(f"Kubernetes {version}: {len(plan)} charts, {total} valid resources, 0 skipped", flush=True)
    elif args.render_plan:
        print(json.dumps(plan))
    else:
        print(f"Flux: {len(objects)} objects, {len(children)} child Kustomizations, {len(plan)} Helm releases; ownership and dependencies OK")


if __name__ == "__main__":
    main()
