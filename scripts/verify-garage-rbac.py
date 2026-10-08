#!/usr/bin/env python3
"""Exercise Garage's actual RBAC on an explicitly selected disposable KWOK API."""

import argparse
import base64
import json
from pathlib import Path
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "system:serviceaccount:storage:garage-bootstrap"
SECRETS = ("velero-s3-credentials", "zot-s3-credentials", "cnpg-s3-credentials")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kubeconfig", required=True)
    parser.add_argument("--context", required=True)
    args = parser.parse_args()
    if not args.context.startswith("kwok-karpenter-em-e2e-"):
        parser.error("Only the disposable Karpenter KWOK harness is supported")
    base = ["kubectl", "--kubeconfig", str(Path(args.kubeconfig).resolve()),
            "--context", args.context, "--request-timeout=15s"]

    def run(*arguments, obj=None, identity=None, denied=False):
        command = base + (["--as", identity] if identity else []) + list(arguments)
        result = subprocess.run(command, input=json.dumps(obj) if obj else None,
                                capture_output=True, text=True, timeout=45)
        if denied:
            if result.returncode == 0 or "Forbidden" not in result.stderr:
                raise RuntimeError(f"Expected authorization refusal: {result.stderr}")
        elif result.returncode != 0:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    def secret(name, namespace="storage", value="local-test"):
        return {"apiVersion": "v1", "kind": "Secret", "metadata": {
            "name": name, "namespace": namespace}, "stringData": {"test": value}}

    namespaces = ("storage", "garage", "identity")
    # Refuse adoption even on the explicitly selected test API.
    for namespace in namespaces:
        if run("get", "namespace", namespace, "--ignore-not-found", "-o", "name"):
            raise RuntimeError(f"Namespace {namespace} already exists; refusing to adopt it")
    created = []
    try:
        for namespace in namespaces:
            run("create", "namespace", namespace)
            created.append(namespace)
        for obj in yaml.safe_load_all((ROOT / "stacks/storage/flux-bootstrap/job.yaml").read_text()):
            if obj and obj["kind"] in ("ServiceAccount", "Role", "RoleBinding"):
                run("create", "-f", "-", obj=obj)
        for name in SECRETS:
            for value in ("created", "updated"):
                run("apply", "--server-side", "--field-manager=garage-bootstrap", "-f", "-",
                    obj=secret(name, value=value), identity=ACCOUNT)
                stored = json.loads(run("get", "secret", name, "-n", "storage", "-o", "json",
                                        identity=ACCOUNT))
                if base64.b64decode(stored["data"]["test"]).decode() != value:
                    raise RuntimeError(f"Secret {name} did not retain its {value} value")
            run("delete", "secret", name, "-n", "storage", identity=ACCOUNT, denied=True)
        run("create", "-f", "-", obj=secret("not-owned"))
        run("get", "secret", "not-owned", "-n", "storage", identity=ACCOUNT, denied=True)
        run("apply", "--server-side", "-f", "-", obj=secret("not-owned"), identity=ACCOUNT, denied=True)
        run("create", "-f", "-", obj=secret("cross-namespace", "identity"), identity=ACCOUNT, denied=True)
        print("Garage RBAC PASS: real SSA create/update/get; foreign read/patch, cross-namespace create and delete denied")
    finally:
        for namespace in reversed(created):
            run("delete", "namespace", namespace, "--wait=true", "--timeout=30s")


if __name__ == "__main__":
    main()
