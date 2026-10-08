#!/usr/bin/env python3
"""Recover only KMS into new, explicitly named Podman resources. Never overwrite."""

import argparse
import base64
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import time
import urllib.error

import yaml

SPEC = importlib.util.spec_from_file_location("backup", Path(__file__).with_name("bootstrap-backup.py"))
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)


def recovery_manifest(documents, name, port):
    docs = copy.deepcopy(documents)
    pod = next(d for d in docs if d and d["kind"] == "Pod")
    bao = next(c for c in pod["spec"]["containers"] if c["name"] == "bao")
    bao["ports"] = [{"containerPort": 8200, "hostPort": port, "hostIP": "127.0.0.1"}]
    pod["metadata"] = {"name": name, "labels": {"app": name}}
    needed_volumes = {v["name"] for v in bao["volumeMounts"]}
    pod["spec"] = {"restartPolicy": "Always", "containers": [bao],
                   "volumes": [v for v in pod["spec"]["volumes"] if v["name"] in needed_volumes]}
    for volume in pod["spec"]["volumes"]:
        if "persistentVolumeClaim" in volume:
            volume["persistentVolumeClaim"]["claimName"] = name + "-bao-data"
        if "configMap" in volume:
            volume["configMap"]["name"] = name + "-" + volume["configMap"]["name"]
    for env in bao["env"]:
        reference = env.get("valueFrom", {}).get("secretKeyRef")
        if reference:
            reference["name"] = name + "-" + reference["name"]
    result = []
    for doc in docs:
        if doc and doc["kind"] in ("Secret", "ConfigMap") and doc["metadata"]["name"] in (
                "platform-secrets", "bao-seal-key", "openbao-config"):
            if doc["kind"] == "Secret":
                # Recovery KMS has no reason to receive CI/cloud credentials.
                for field in ("data", "stringData"):
                    if field in doc:
                        doc[field] = {k: v for k, v in doc[field].items() if k == "CI_PASSWORD"}
            doc["metadata"]["name"] = name + "-" + doc["metadata"]["name"]
            result.append(doc)
    return result + [pod]


def verify_endpoint_identity(url, container):
    health = json.loads(backup.api(url, "sys/health"))
    actual = json.loads(backup.command("podman", "exec", container, "bao", "status",
                                     "-format=json", "-address=http://127.0.0.1:8200"))
    if (not health.get("cluster_id") or health["cluster_id"] != actual.get("cluster_id")
            or health.get("initialized") is not True or health.get("sealed") is not False):
        raise ValueError("HTTP endpoint does not match the selected recovery KMS container")


def import_volume(name, files):
    backup.command("podman", "volume", "create", name)
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as tar:
        for path, content in files.items():
            member = tarfile.TarInfo(path)
            member.size, member.mode = len(content), 0o600
            tar.addfile(member, io.BytesIO(content))
    subprocess.run(["podman", "volume", "import", name, "-"], input=archive.getvalue(),
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=120)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("backup", type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--confirm-new-resources", action="store_true", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z][a-z0-9-]{2,48}", args.name) or not 1024 <= args.port <= 65535:
        parser.error("Use a distinct lowercase resource name and unprivileged port")
    if not os.environ.get("CONTAINER_HOST"):
        parser.error("Set CONTAINER_HOST explicitly; the default Podman connection is forbidden")
    try:
        manifest = backup.verify(args.backup)
        for resource in ("pod", "container", "volume", "secret"):
            flags = ["--all"] if resource == "container" else []
            names = backup.command("podman", resource, "ls", *flags, "--format", "{{.Name}}" if resource != "container" else "{{.Names}}").decode().splitlines()
            if any(n == args.name or n.startswith(args.name + "-") for n in names):
                raise ValueError("Recovery resource prefix already exists; nothing was changed")
        docs = list(yaml.safe_load_all((args.backup / "platform.yaml").read_text()))
        secret = next(d for d in docs if d and d.get("metadata", {}).get("name") == "platform-secrets")
        password = secret.get("stringData", {}).get("CI_PASSWORD")
        if password is None:
            password = base64.b64decode(secret["data"]["CI_PASSWORD"]).decode()
        args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
        podfile = args.output / "recovery.yaml"
        backup.write_private(podfile, yaml.safe_dump_all(recovery_manifest(docs, args.name, args.port)).encode())
        setup_files = {"terraform.tfstate": (args.backup / "setup.tfstate").read_bytes()}
        with tarfile.open(args.backup / "setup-source.tar") as archive:
            for member in archive.getmembers():
                setup_files[member.name] = archive.extractfile(member).read()
        import_volume(args.name + "-tofu-state", setup_files)
        import_volume(args.name + "-kms-output", {p.name: p.read_bytes() for p in (args.backup / "kms-output").iterdir()})
        # KMS only: no setup/CI writer may run before the old Raft is restored.
        subprocess.run(["bash", str(Path(__file__).with_name("podman-kube-play.sh")), str(podfile)],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=180)
        url = f"http://127.0.0.1:{args.port}"
        deadline = time.monotonic() + 180
        while True:
            try:
                health = json.loads(backup.api(url, "sys/health"))
                if health.get("initialized") and not health.get("sealed"):
                    break
            except (OSError, urllib.error.URLError):
                pass
            if time.monotonic() > deadline:
                raise ValueError("Recovery KMS did not become healthy; resources retained for diagnosis")
            time.sleep(2)
        verify_endpoint_identity(url, args.name + "-bao")
        token = json.loads(backup.api(url, "auth/userpass/login/bootstrap-admin",
                                     data=json.dumps({"password": password}).encode()))["auth"]["client_token"]
        backup.api(url, "sys/storage/raft/snapshot", token, (args.backup / "raft.snap").read_bytes())
        deadline = time.monotonic() + 90
        while True:
            try:
                health = json.loads(backup.api(url, "sys/health"))
                if health.get("cluster_id") == manifest["cluster_id"] and not health.get("sealed"):
                    break
            except (OSError, urllib.error.URLError):
                pass
            if time.monotonic() > deadline:
                raise ValueError("Restored cluster identity not confirmed")
            time.sleep(2)
        verify_endpoint_identity(url, args.name + "-bao")
        # Authenticate with the restored AppRole, not the temporary admin session.
        credentials = {"role_id": (args.backup / "kms-output/approle-role-id.txt").read_text().strip(),
                       "secret_id": (args.backup / "kms-output/approle-secret-id.txt").read_text().strip()}
        restored = json.loads(backup.api(url, "auth/approle/login", data=json.dumps(credentials).encode()))["auth"]["client_token"]
        backup.api(url, "auth/token/revoke-self", restored, b"{}")
        backup.write_private(args.output / "outer.tfstate", (args.backup / "outer.tfstate").read_bytes())
        print(f"PASS restored KMS cluster identity and original AppRole at {url}")
        print(f"Preserved setup/export volumes: {args.name}-tofu-state, {args.name}-kms-output")
        print("KMS only: CI volumes, workloads and PostgreSQL are NOT restored; no writers started")
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, tarfile.TarError) as exc:
        print(f"FAIL {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
