#!/usr/bin/env python3
"""Validate/migrate bootstrap identity before replacement, on the selected engine.

Requires Python 3.9+ and PyYAML. Preflight uses no image or helper container.
Replacement never deletes volumes; kube play may fetch application images.
All Podman commands inherit the caller's connection selection.
"""

import argparse
import base64
import binascii
import fcntl
import io
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

import yaml


class Refused(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Refused(message)


def private_file(path):
    require(not path.is_symlink() and path.is_file(), f"Not a regular file: {path}")
    path.chmod(0o600)
    return path.read_bytes()


def state_json(raw):
    try:
        state = json.loads(raw)
    except (ValueError, UnicodeError):
        raise Refused("Invalid setup state JSON") from None
    require(isinstance(state, dict) and state.get("version") == 4
            and isinstance(state.get("lineage"), str) and state["lineage"].strip()
            and type(state.get("serial")) is int and state["serial"] >= 0
            and isinstance(state.get("resources"), list), "Invalid setup state header")
    return state


def validate_state(raw, exports):
    state = state_json(raw)
    resources = {}
    for resource in state["resources"]:
        require(isinstance(resource, dict), "Invalid setup state resource")
        if resource.get("mode") != "managed" or resource.get("module"):
            continue
        key = (resource.get("type"), resource.get("name"))
        require(key not in resources, "Duplicate setup state resource")
        resources[key] = resource.get("instances", [])

    def attributes(kind, name):
        instances = resources.get((kind, name), [])
        require(len(instances) == 1 and isinstance(instances[0], dict)
                and not instances[0].get("deposed") and not instances[0].get("status"),
                f"Missing, tainted or ambiguous PKI resource: {kind}.{name}")
        attrs = instances[0].get("attributes")
        require(isinstance(attrs, dict), f"Invalid PKI resource: {kind}.{name}")
        return attrs

    expected = {}
    root_key = attributes("tls_private_key", "root_ca").get("private_key_pem")
    root = attributes("tls_self_signed_cert", "root_ca")
    require(isinstance(root_key, str) and "PRIVATE KEY-----" in root_key
            and root.get("private_key_pem") == root_key, "Incomplete root CA key in setup state")
    root_cert = root.get("cert_pem")
    require(isinstance(root_cert, str) and "BEGIN CERTIFICATE" in root_cert,
            "Missing root CA certificate in setup state")
    expected["root-ca.pem"] = root_cert
    for name in ("infra", "app"):
        key = attributes("tls_private_key", name + "_ca").get("private_key_pem")
        request = attributes("tls_cert_request", name + "_ca")
        cert = attributes("tls_locally_signed_cert", name + "_ca")
        require(isinstance(key, str) and "PRIVATE KEY-----" in key
                and request.get("private_key_pem") == key
                and request.get("cert_request_pem")
                and request["cert_request_pem"] == cert.get("cert_request_pem")
                and cert.get("ca_private_key_pem") == root_key
                and cert.get("ca_cert_pem") == root_cert,
                f"Incomplete {name} CA identity in setup state")
        pem = cert.get("cert_pem")
        require(isinstance(pem, str) and "BEGIN CERTIFICATE" in pem,
                f"Missing {name} CA certificate in setup state")
        expected[name + "-ca.pem"] = pem
        expected[name + "-ca-key.pem"] = key
        expected[name + "-ca-chain.pem"] = pem + root_cert
    for name, value in exports.items():
        require(name in expected and value.strip() == expected[name].encode().strip(),
                f"Existing PKI does not match setup state: {name}")
    return state


class Preflight:
    def __init__(self, directory):
        self.directory = Path(directory)

    def run(self, *args, stdout=subprocess.PIPE, input=None, absent_ok=False):
        result = subprocess.run(["podman", *args], input=input, stdout=stdout,
                                stderr=subprocess.PIPE, check=False)
        if absent_ok and result.returncode == 1:
            return None
        # Never relay engine output: archives, manifests and inspect may contain secrets.
        require(result.returncode == 0, f"Podman {args[0]} failed ({result.returncode}); refusing further bootstrap actions")
        return result.stdout

    def exists(self, kind, name):
        return self.run(kind, "exists", name, absent_ok=True) is not None

    def archive(self, *args, select):
        # Stream to disk instead of holding provider caches from /tmp/tofu-work in RAM.
        with tempfile.TemporaryFile(dir=self.directory) as stream:
            self.run(*args, stdout=stream)
            stream.seek(0)
            found = {}
            try:
                with tarfile.open(fileobj=stream) as archive:
                    for member in archive:
                        name = member.name.removeprefix("./")
                        if not select(name):
                            continue
                        require(member.isfile() and member.size <= 16 * 1024 * 1024
                                and name not in found, "Unsafe or duplicate bootstrap archive entry")
                        found[name] = archive.extractfile(member).read()
            except tarfile.TarError:
                raise Refused("Invalid bootstrap archive") from None
            return found

    def volume_files(self, volume, select):
        if not self.exists("volume", volume):
            return {}
        return self.archive("volume", "export", volume, select=select)

    def migrate(self, files):
        if not self.exists("volume", "platform-tofu-state"):
            self.run("volume", "create", "platform-tofu-state")
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode="w") as archive:
            for name, raw in files.items():
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(raw), 0o600
                archive.addfile(info, io.BytesIO(raw))
        self.run("volume", "import", "platform-tofu-state", "-", input=payload.getvalue())
        copied = self.volume_files("platform-tofu-state", lambda n: n in files)
        require(copied == files, "Persistent setup state read-back differs; refusing pod deletion")

    def guard_ports(self, manifest):
        try:
            pod = next(d for d in yaml.safe_load_all(manifest.read_bytes())
                       if isinstance(d, dict) and d.get("kind") == "Pod")
            require(not pod["spec"].get("hostNetwork"), "Host networking is not supported by the port guard")
            proposed = set()
            for container in pod["spec"]["containers"]:
                for port in container.get("ports", []):
                    if port.get("hostPort"):
                        proposed.add(port_binding(port.get("hostIP", ""), port["hostPort"],
                                                  port["containerPort"], port.get("protocol", "TCP")))
            info = json.loads(self.run("pod", "inspect", "platform"))[0]["InfraConfig"]
            require(not info.get("HostNetwork"), "Existing pod uses host networking; manual migration required")
            actual = set()
            published = info["PortBindings"] or {}
            require(isinstance(published, dict), "Cannot verify pod port bindings")
            for target, bindings in published.items():
                container_port, protocol = target.split("/")
                for binding in bindings or []:
                    actual.add(port_binding(binding["HostIp"], binding["HostPort"], container_port, protocol))
        except (KeyError, IndexError, TypeError, ValueError, StopIteration, yaml.YAMLError):
            raise Refused("Cannot verify existing/proposed pod port bindings") from None
        require(proposed == actual,
                "Pod port bindings changed; refusing replacement. Keep existing ports, or schedule a manual "
                "stop, state-safe migration and fresh port checks on the engine host before recreating")

    def guard(self, key, retained, replace, manifest):
        paused = False
        deleted = False
        try:
            old_pod = self.exists("pod", "platform")
            if old_pod:
                self.guard_ports(manifest)
            setup = self.exists("container", "platform-tofu-setup")
            bao = self.exists("container", "platform-bao")
            bao_data = self.exists("volume", "platform-bao-data")
            if bao:
                actual = self.archive("cp", "platform-bao:/bao/seal/unseal.key", "-",
                                      select=lambda n: n == "unseal.key")
                require(actual.get("unseal.key") == key,
                        "Seal ConfigMap differs from the key mounted by existing OpenBao")
            elif bao_data or old_pod:
                require(retained.exists(), "Existing bootstrap without provable seal key; restore it first")

            legacy = {}
            if setup:
                info = json.loads(self.run("container", "inspect", "platform-tofu-setup"))[0]
                mounts = {m["Destination"]: m for m in info["Mounts"]}
                require(mounts.get("/kms-output", {}).get("Name") == "platform-kms-output",
                        "Unexpected setup output mount; manual migration required")
                status = info["State"]["Status"]
                require(status in ("running", "exited", "stopped", "created"),
                        "Setup container is not in a stable state")
                if status == "running":
                    self.run("pause", "platform-tofu-setup")
                    paused = True
                if "/var/lib/tofu" in mounts:
                    require(mounts["/var/lib/tofu"].get("Name") == "platform-tofu-state",
                            "Unexpected persistent setup mount")
                else:
                    legacy = self.archive("cp", "platform-tofu-setup:/tmp/tofu-work/.", "-",
                                          select=state_file)

            persistent = self.volume_files("platform-tofu-state", state_file)
            exports = self.volume_files("platform-kms-output", lambda n: n.endswith(".pem"))
            require(".terraform.tfstate.lock.info" not in legacy
                    and ".terraform.tfstate.lock.info" not in persistent,
                    "Setup state is locked; wait for apply completion before replacing")
            old_raw = legacy.get("terraform.tfstate")
            saved_raw = persistent.get("terraform.tfstate")
            require(not setup or old_raw is not None or saved_raw is not None,
                    "Existing setup container without readable state; restore before replacing")
            if old_raw is not None:
                old = validate_state(old_raw, exports)
            if saved_raw is not None:
                saved = validate_state(saved_raw, exports)
                if old_raw is not None:
                    require(old == saved, "Legacy and persistent setup states diverge; resolve manually")
            else:
                require(old_raw is not None or not exports,
                        "Existing PKI without matching setup state; restore before replacing")
                require(old_raw is not None or not legacy and not persistent,
                        "Setup state missing but state artifacts remain; restore before replacing")
                if old_raw is not None:
                    backup = legacy.get("terraform.tfstate.backup")
                    if backup is not None:
                        previous = state_json(backup)
                        require(previous["lineage"] == old["lineage"]
                                and previous["serial"] <= old["serial"], "Invalid legacy state backup")
                    require(not persistent, "Persistent state artifacts already exist; refusing overwrite")
                    self.migrate(legacy)

            if not retained.exists():
                with retained.open("xb") as stream:
                    stream.write(key)
                retained.chmod(0o400)
            if replace:
                # Capability errors must also happen before deleting the old pod.
                help_text = self.run("kube", "play", "--help")
                require(b"--log-driver" in help_text,
                        "Podman kube play must support --log-driver for portable setup logs")
                # `secret ls --format json` is a literal Go template on Podman
                # 5.8. Use the exit-status API, preserving errors other than 1.
                existing_secret = self.exists("secret", "platform-secrets")
                if old_pod:
                    self.run("pod", "rm", "-f", "platform")
                    deleted = True
                else:
                    require(not setup and not bao, "Orphaned bootstrap containers; resolve before replacing")
                if existing_secret:
                    self.run("secret", "rm", "platform-secrets")
                options = ["--build=false"] if b"--build" in help_text else []
                options.append("--log-driver=k8s-file")
                self.run("kube", "play", *options, str(manifest))
            print("[bootstrap-preflight] seal and setup state verified" + ("; pod replaced" if replace else ""))
        finally:
            if paused and not deleted:
                self.run("unpause", "platform-tofu-setup")


def state_file(name):
    return name in ("terraform.tfstate", "terraform.tfstate.backup", ".terraform.tfstate.lock.info")


def port_binding(host, published, target, protocol):
    host = str(ipaddress.ip_address(host or "0.0.0.0"))
    published, target = int(published), int(target)
    protocol = protocol.lower()
    require(0 < published <= 65535 and 0 < target <= 65535 and protocol in ("tcp", "udp", "sctp"),
            "Invalid pod port binding")
    return host, published, target, protocol


def manifest_key(raw, replacing=False):
    try:
        documents = [doc for doc in yaml.safe_load_all(raw) if doc is not None]
        identities = [(d["kind"], d["metadata"]["name"]) for d in documents]
        require(len(identities) == len(set(identities)), "Duplicate objects in bootstrap manifest")
        require([identity for identity in identities if identity[0] == "Pod"] == [("Pod", "platform")],
                "Bootstrap manifest must contain only the platform pod")
        pod = documents[identities.index(("Pod", "platform"))]
        volumes = {v["name"]: v for v in pod["spec"]["volumes"]}
        containers = {c["name"]: c for c in pod["spec"]["containers"]}
        mounts = {m["mountPath"]: m["name"] for m in containers["bao"]["volumeMounts"]}
        require(volumes[mounts["/bao/seal"]]["configMap"]["name"] == "bao-seal-key",
                "Pod does not consume the expected seal ConfigMap")
        mounts = {m["mountPath"]: m["name"] for m in containers["tofu-setup"]["volumeMounts"]}
        required = [("/kms-output", "platform-kms-output")]
        if replacing:
            required.append(("/var/lib/tofu", "platform-tofu-state"))
        for path, name in required:
            require(volumes[mounts[path]]["persistentVolumeClaim"]["claimName"] == name,
                    "Target pod must persist setup state and PKI output")
        seal = documents[identities.index(("ConfigMap", "bao-seal-key"))]
        key = base64.b64decode(seal["binaryData"]["unseal.key"], validate=True)
        require(len(key) == 32, "Seal ConfigMap must contain exactly 32 bytes")
        return key
    except (KeyError, ValueError, TypeError, yaml.YAMLError, binascii.Error):
        raise Refused("Invalid bootstrap manifest or seal ConfigMap") from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--configmap", type=Path, help="Legacy separate ConfigMap/Secret YAML")
    parser.add_argument("--uploaded-key", type=Path)
    parser.add_argument("--replace", action="store_true", help="Replace only after successful validation/migration")
    args = parser.parse_args()
    os.umask(0o077)
    directory = args.manifest.absolute().parent
    require(not directory.is_symlink() and directory.is_dir(), "Unsafe bootstrap directory")
    directory.chmod(0o700)
    lock_path = directory / ".bootstrap-preflight.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused("Another bootstrap replacement is already running") from None
        raw = private_file(args.manifest)
        if args.configmap:
            raw = private_file(args.configmap) + b"\n---\n" + raw
        key = manifest_key(raw, replacing=args.replace)
        if args.uploaded_key:
            require(private_file(args.uploaded_key) == key, "Uploaded seal key differs from seal ConfigMap")
        retained = directory / "unseal.key"
        if retained.exists() or retained.is_symlink():
            require(private_file(retained) == key, "Uploaded seal key differs from retained seal key")
            retained.chmod(0o400)
        # Validate and launch the same private snapshot, even if an upload races us.
        with tempfile.TemporaryDirectory(prefix=".preflight-", dir=directory) as temporary:
            snapshot = Path(temporary) / "platform-pod.yaml"
            snapshot.write_bytes(raw)
            Preflight(temporary).guard(key, retained, args.replace, snapshot)


if __name__ == "__main__":
    try:
        main()
    except (Refused, OSError, ValueError, TypeError) as error:
        print(f"FATAL: bootstrap preflight refused: {error}", file=sys.stderr)
        sys.exit(1)
