#!/usr/bin/env python3
"""Check a deployed Flux graph against its expected objects and Git revision."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

SPEC = importlib.util.spec_from_file_location("gitops", Path(__file__).with_name("verify-gitops.py"))
gitops = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gitops)


def ready(obj, condition="Ready"):
    generation = obj["metadata"].get("generation", 1)
    status = obj.get("status", {})
    for item in status.get("conditions", []):
        if item["type"] == condition:
            if item.get("reason") == "SecretMissing":
                return False
            observed = item.get("observedGeneration", status.get("observedGeneration", generation))
            return item["status"] == "True" and observed >= generation
    return False


def at_revision(value, revision):
    return isinstance(value, str) and value.rsplit(":", 1)[-1] == revision


def assess(objects, owners, live, revision, allowed):
    expected = {(d["kind"], d["metadata"].get("namespace", ""), d["metadata"]["name"])
                for d in objects.values() if d["kind"] in (
                    "HelmRelease", "Kustomization", "ExternalSecret", "Job", "Cluster", "Certificate")}
    if not any(kind == "HelmRelease" for kind, _, _ in expected):
        raise ValueError("Expected graph has no HelmReleases")
    expected.update({("GitRepository", "flux-system", "management"),
                     ("Kustomization", "flux-system", "management"),
                     ("ExternalSecret", "flux-system", "flux-ssh-identity"),
                     ("ClusterSecretStore", "", "openbao-infra")})
    expected.update(("ClusterIssuer", "", name) for name in (
        "internal-ca-bootstrap", "internal-ca", "cilium-issuer"))
    releases = {f"{ns}/{name}" for kind, ns, name in expected if kind == "HelmRelease"}
    if not allowed <= releases:
        raise ValueError(f"Unknown allowed HelmReleases: {sorted(allowed - releases)}")
    exempt_owners = {owners[key] for key, doc in objects.items()
                     if doc["kind"] == "HelmRelease" and
                     f"{doc['metadata'].get('namespace', '')}/{doc['metadata']['name']}" in allowed}
    # Only a root-owned release can exempt root health. Child dependencies
    # are not waived transitively; their consumers still have to converge.
    failures, exemptions = [], []
    for kind, ns, name in sorted(expected):
        label = f"{kind}/{ns}/{name}"
        obj = live.get((kind, ns, name))
        if obj is None:
            failures.append(f"{label}: missing")
            continue
        status = obj.get("status", {})
        if kind == "Cluster" and status.get("readyInstances", 0) != obj["spec"]["instances"]:
            failures.append(f"{label}: not all database instances are ready")
        exempt = ((kind == "HelmRelease" and f"{ns}/{name}" in allowed) or
                  (kind == "Kustomization" and name in exempt_owners))
        if kind == "GitRepository" and not at_revision(status.get("artifact", {}).get("revision"), revision):
            failures.append(f"{label}: wrong or missing source revision")
        if kind == "Kustomization":
            field = "lastAttemptedRevision" if exempt else "lastAppliedRevision"
            if not at_revision(status.get(field), revision):
                failures.append(f"{label}: wrong or missing {field}")
        if not ready(obj, "Complete" if kind == "Job" else "Ready"):
            if exempt:
                exemptions.append(label)
            else:
                messages = [c.get("message", "") for c in status.get("conditions", [])
                            if c.get("type") in ("Ready", "Failed")]
                failures.append(f"{label}: not ready {'; '.join(messages)[:240]}")
    return failures, exemptions, len(expected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kubeconfig", required=True)
    parser.add_argument("--context", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--allow-unready", action="append", default=[], metavar="NAMESPACE/HELMRELEASE")
    args = parser.parse_args()
    objects, owners, _ = gitops.load_graph()
    live = {}
    for resource in ("helmreleases", "kustomizations.kustomize.toolkit.fluxcd.io",
                     "gitrepositories", "externalsecrets", "clustersecretstores", "clusterissuers", "jobs",
                     "clusters.postgresql.cnpg.io", "certificates.cert-manager.io"):
        result = subprocess.check_output([
            "kubectl", "--kubeconfig", args.kubeconfig, "--context", args.context,
            "--request-timeout=30s", "get", resource, "--all-namespaces", "-o", "json"],
            text=True, timeout=45)
        for obj in json.loads(result)["items"]:
            meta = obj["metadata"]
            live[(obj["kind"], meta.get("namespace", ""), meta["name"])] = obj
    failures, exemptions, count = assess(objects, owners, live, args.revision, set(args.allow_unready))
    for line in failures:
        print(f"FAIL {line}")
    for line in exemptions:
        print(f"EXEMPT {line}")
    print(f"Platform: {count} expected objects, {len(failures)} failures, {len(exemptions)} explicit exemptions")
    raise SystemExit(bool(failures))


if __name__ == "__main__":
    main()
