#!/usr/bin/env python3
"""Delete only the selected bootstrap's declared volumes after backup confirmation."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import yaml

SPEC = importlib.util.spec_from_file_location("backup", Path(__file__).with_name("bootstrap-backup.py"))
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)


def volume_names(documents):
    pod = next(d for d in documents if d and d.get("kind") == "Pod" and d["metadata"]["name"] == "platform")
    names = {v["persistentVolumeClaim"]["claimName"] for v in pod["spec"]["volumes"] if "persistentVolumeClaim" in v}
    if not names or any(not n.startswith("platform-") for n in names):
        raise ValueError("Unexpected bootstrap volume names")
    return sorted(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backup", required=True, type=Path)
    parser.add_argument("--url", required=True)
    parser.add_argument("--confirm-delete-bootstrap", choices=("platform",), required=True)
    args = parser.parse_args()
    if not os.environ.get("CONTAINER_HOST"):
        parser.error("An explicit CONTAINER_HOST is required; never use the default engine for reset")
    try:
        manifest = backup.verify(args.backup)
        health = json.loads(backup.api(args.url, "sys/health"))
        if health.get("cluster_id") != manifest["cluster_id"]:
            raise ValueError("Backup does not belong to the selected KMS")
        # The HTTP tunnel and selected Podman socket must identify the same KMS.
        local = json.loads(backup.command("podman", "exec", "platform-bao", "bao", "status", "-format=json",
                                          "-address=http://127.0.0.1:8200"))
        if local.get("cluster_id") != manifest["cluster_id"]:
            raise ValueError("Podman connection does not match the confirmed KMS backup")
        names = volume_names(list(yaml.safe_load_all((args.backup / "platform.yaml").read_text())))
        backup.command("podman", "pod", "rm", "-f", "platform")
        # No --force and no prefix wildcard: another consumer prevents deletion.
        for name in names:
            backup.command("podman", "volume", "rm", name)
        print("Bootstrap pod and declared volumes deleted. Unrelated volumes were not selected.")
        return 0
    except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError) as exc:
        print(f"FAIL bootstrap reset: {type(exc).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
