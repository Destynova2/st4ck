#!/usr/bin/env python3
"""Back up bootstrap KMS, including the state and seal material outside Raft."""

import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request

import yaml

EXPORTS = ("root-ca.pem", "infra-ca.pem", "app-ca.pem", "infra-ca-key.pem",
           "app-ca-key.pem", "approle-role-id.txt", "approle-secret-id.txt", "transit-token.txt")
REQUIRED = {"raft.snap", "outer.tfstate", "setup.tfstate", "seal.key", "platform.yaml", "setup-source.tar"}
REQUIRED.update("kms-output/" + name for name in EXPORTS)


def command(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE, timeout=120)


def write_private(path, data):
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)


def digest_stream(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
    return digest.hexdigest()


def api(url, path, token=None, data=None):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1", "::1")):
        raise ValueError("KMS requires HTTPS or a loopback SSH tunnel")
    headers = {"X-Vault-Token": token} if token else {}
    if data is not None:
        headers["Content-Type"] = "application/json" if path.startswith("auth/") else "application/octet-stream"
    request = urllib.request.Request(url.rstrip("/") + "/v1/" + path, data=data, headers=headers)
    # Never forward administrative credentials to a redirect destination.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    with urllib.request.build_opener(NoRedirect).open(request, timeout=120) as response:
        return response.read()


@contextmanager
def authenticated(args):
    external = bool(args.token_file)
    if external:
        token = Path(args.token_file).read_text().strip()
    else:
        password = (Path(args.password_file).read_text().rstrip("\n") if args.password_file else
                    command("podman", "exec", "platform-tofu-setup", "printenv", "CI_PASSWORD").decode().rstrip("\n"))
        response = json.loads(api(args.url, "auth/userpass/login/bootstrap-admin",
                                  data=json.dumps({"password": password}).encode()))
        token = response["auth"]["client_token"]
    if not token:
        raise ValueError("Empty authentication credential")
    try:
        yield token
    finally:
        if not external:
            try:
                api(args.url, "auth/token/revoke-self", token, b"{}")
            except (OSError, urllib.error.URLError):
                print("WARNING: session revocation could not be confirmed (a restore invalidates the new session)", file=sys.stderr)


def snapshot_valid(path):
    with tarfile.open(path, "r:gz") as archive:
        names = {item.name for item in archive.getmembers() if item.isfile()}
        if not {"meta.json", "state.bin", "SHA256SUMS"} <= names:
            raise ValueError("Not an OpenBao Raft snapshot")
        checksums = archive.extractfile("SHA256SUMS").read().decode()
        checked = set()
        for line in checksums.splitlines():
            digest, name = line.split(None, 1)
            name = name.lstrip(" *")
            if name not in names:
                raise ValueError("Snapshot checksum references missing member")
            actual = digest_stream(archive.extractfile(name))
            if digest != actual:
                raise ValueError("Snapshot checksum mismatch")
            checked.add(name)
        if not {"meta.json", "state.bin"} <= checked or not archive.getmember("state.bin").size:
            raise ValueError("Empty Raft snapshot")


def state_resources(path):
    state = json.loads(path.read_text())
    if state.get("version") != 4 or not state.get("lineage") or not state.get("resources"):
        raise ValueError(f"Incomplete Terraform state: {path.name}")
    resources = {(r["type"], r["name"]): i["attributes"] for r in state["resources"]
                 if r.get("mode") == "managed" for i in r.get("instances", [])}
    return state["lineage"], resources


def validate_material(root):
    outer_lineage, outer = state_resources(root / "outer.tfstate")
    setup_lineage, setup = state_resources(root / "setup.tfstate")
    seal = (root / "seal.key").read_bytes()
    candidates = [attrs for (kind, name), attrs in outer.items()
                  if kind == "random_bytes" and name in ("seal_key", "bao_seal_key")]
    if len(seal) != 32 or len(candidates) != 1 or base64.b64decode(candidates[0]["base64"], validate=True) != seal:
        raise ValueError("Outer state and running static seal do not match")
    docs = list(yaml.safe_load_all((root / "platform.yaml").read_text()))
    seal_maps = [d for d in docs if d and d.get("metadata", {}).get("name") == "bao-seal-key"]
    if len(seal_maps) != 1 or base64.b64decode(seal_maps[0]["binaryData"]["unseal.key"], validate=True) != seal:
        raise ValueError("Manifest and running static seal do not match")
    if sum(d is not None and d.get("kind") == "Pod" for d in docs) != 1:
        raise ValueError("Expected a complete generated platform manifest")
    for name in ("root", "infra", "app"):
        cert_kind = "tls_self_signed_cert" if name == "root" else "tls_locally_signed_cert"
        cert = setup[(cert_kind, name + "_ca")]["cert_pem"]
        key = setup[("tls_private_key", name + "_ca")]["private_key_pem"]
        if not key or cert.strip() != (root / "kms-output" / (name + "-ca.pem")).read_text().strip():
            raise ValueError(f"Setup state and exported {name} CA do not match")
        if name != "root" and key.strip() != (root / "kms-output" / (name + "-ca-key.pem")).read_text().strip():
            raise ValueError(f"Setup state and exported {name} key do not match")
    with tarfile.open(root / "setup-source.tar") as source:
        members = source.getmembers()
        if not any(m.name.endswith("pki.tf") for m in members):
            raise ValueError("Missing setup source")
        if any(not m.isfile() or Path(m.name).is_absolute() or ".." in Path(m.name).parts for m in members):
            raise ValueError("Unsafe setup source archive")
    snapshot_valid(root / "raft.snap")
    return {"outer_lineage": outer_lineage, "setup_lineage": setup_lineage}


def verify(root):
    manifest = json.loads((root / "backup.json").read_text())
    if manifest.get("format") != 1 or not REQUIRED <= manifest.get("sha256", {}).keys():
        raise ValueError("Incomplete backup manifest")
    for name, digest in manifest["sha256"].items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Unsafe backup path")
        path = root / relative
        if path.is_symlink() or not path.is_file() or root.resolve() not in path.resolve().parents:
            raise ValueError(f"Missing or unsafe backup member: {name}")
        with path.open("rb") as stream:
            if digest_stream(stream) != digest:
                raise ValueError(f"Checksum mismatch: {name}")
    material = validate_material(root)
    if any(manifest.get(k) != v for k, v in material.items()):
        raise ValueError("State lineage mismatch")
    return manifest


def backup(args):
    root = Path(args.directory).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    # Callers must quiesce Terraform/CI writes. Detect concurrent state changes
    # across the capture instead of publishing an internally inconsistent backup.
    outer = Path(args.outer_state).read_bytes()
    write_private(root / "outer.tfstate", outer)
    write_private(root / "platform.yaml", Path(args.manifest).read_bytes())
    command("podman", "cp", "platform-tofu-setup:/var/lib/tofu/terraform.tfstate", str(root / "setup.tfstate"))
    command("podman", "cp", "platform-bao:/bao/seal/unseal.key", str(root / "seal.key"))
    (root / "kms-output").mkdir(mode=0o700)
    command("podman", "cp", "platform-tofu-setup:/kms-output/.", str(root / "kms-output"))
    write_private(root / "setup-source.tar", command("podman", "exec", "platform-tofu-setup", "sh", "-ec",
                  "cd /var/lib/tofu; tar cf - ./*.tf .terraform.lock.hcl"))
    with authenticated(args) as token:
        health = json.loads(api(args.url, "sys/health", token))
        write_private(root / "raft.snap", api(args.url, "sys/storage/raft/snapshot", token))
    setup_after = command("podman", "exec", "platform-tofu-setup", "cat", "/var/lib/tofu/terraform.tfstate")
    if outer != Path(args.outer_state).read_bytes() or setup_after != (root / "setup.tfstate").read_bytes():
        raise ValueError("State changed during backup; quiesce writers and retry into a new directory")
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError("Symlink in bootstrap exports")
        path.chmod(0o700 if path.is_dir() else 0o600)
    material = validate_material(root)
    files = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in root.rglob("*") if p.is_file()}
    metadata = dict(format=1, created_at=datetime.now(timezone.utc).isoformat(),
                    cluster_id=health["cluster_id"], sha256=files, **material)
    write_private(root / "backup.json", json.dumps(metadata, indent=2).encode())
    verify(root)
    print(f"Verified KMS backup: {root} (secret material; encrypt before off-site transfer)")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=os.environ.get("BAO_ADDR", "http://127.0.0.1:8200"))
    auth = parser.add_mutually_exclusive_group()
    auth.add_argument("--token-file", default=os.environ.get("BAO_TOKEN_FILE"))
    auth.add_argument("--password-file", default=os.environ.get("BAO_PASSWORD_FILE"))
    commands = parser.add_subparsers(dest="action", required=True)
    snap = commands.add_parser("snapshot")
    snap.add_argument("file", type=Path)
    restore = commands.add_parser("restore")
    restore.add_argument("file", type=Path)
    restore.add_argument("--confirm-cluster-id", required=True)
    full = commands.add_parser("backup")
    full.add_argument("directory")
    full.add_argument("--outer-state", default="bootstrap/terraform.tfstate")
    full.add_argument("--manifest", default="/tmp/platform-local/platform-pod.yaml")
    check = commands.add_parser("verify")
    check.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "verify":
            verify(args.directory)
            print("PASS backup contents, checksums, static seal, CA/state consistency and lineages")
        elif args.action == "backup":
            backup(args)
        elif args.action == "snapshot":
            with authenticated(args) as token:
                data = api(args.url, "sys/storage/raft/snapshot", token)
            args.file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(dir=args.file.parent) as directory:
                staged = Path(directory) / "raft.snap"
                write_private(staged, data)
                snapshot_valid(staged)
                write_private(args.file, data)
            print(f"Saved verified Raft snapshot: {args.file} (not a complete KMS backup)")
        else:
            snapshot_valid(args.file)
            with authenticated(args) as token:
                health = json.loads(api(args.url, "sys/health", token))
                if health.get("cluster_id") != args.confirm_cluster_id:
                    raise ValueError("Target cluster ID does not match confirmation")
                api(args.url, "sys/storage/raft/snapshot", token, args.file.read_bytes())
            print("Raft restored without force; verify KMS and state backends before resuming writers")
        return 0
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError, subprocess.SubprocessError) as exc:
        # Never print command stdout/stderr: setup logs and states contain keys.
        print(f"FAIL {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
