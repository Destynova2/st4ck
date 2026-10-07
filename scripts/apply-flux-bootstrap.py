#!/usr/bin/env python3
"""Supply Flux bootstrap inputs from the selected provider without logging secrets."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys


def inputs(provider, outputs, environment):
    values = {key: value["value"] for key, value in outputs.items()}
    if provider == "local":
        host = environment.get("GITEA_CLUSTER_HOST", "")
        user, password = values["admin_user"], values["admin_password"]
    else:
        host = environment.get("GITEA_CLUSTER_HOST") or values.get("ci_vpc_ip") or values.get("ci_ip", "")
        user, password = values.get("gitea_admin_user", "st4ck-admin"), values["gitea_admin_password"]
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        raise ValueError("GITEA_CLUSTER_HOST must be an IP reachable from cluster nodes") from None
    if address.is_loopback or address.is_unspecified or address.is_multicast:
        raise ValueError("Gitea endpoint cannot be loopback, unspecified or multicast")
    if not user or not password:
        raise ValueError("Missing Gitea admin credentials in selected bootstrap state")
    port = environment.get("GITEA_SSH_PORT", "2222")
    if not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise ValueError("GITEA_SSH_PORT must be an integer TCP port between 1 and 65535")
    return {"gitea_external_host": host, "gitea_admin_user": user, "gitea_repo_owner": user,
            "gitea_external_port": port,
            "gitea_admin_password": password,
            "gitea_api_url": environment.get("GITEA_API_URL", "http://127.0.0.1:" + environment.get("GITEA_PORT", "3000"))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "destroy"))
    parser.add_argument("--provider", choices=("scaleway", "local"), required=True)
    parser.add_argument("--kubeconfig", required=True)
    parser.add_argument("--context-id", required=True)
    args = parser.parse_args()
    try:
        source = "bootstrap" if args.provider == "local" else "envs/scaleway/ci"
        raw = subprocess.check_output(["tofu", "-chdir=" + source, "output", "-json"], text=True, timeout=60)
        values = inputs(args.provider, json.loads(raw), os.environ)
        known_file = os.environ.get("GITEA_KNOWN_HOSTS_FILE")
        if known_file:
            known = Path(known_file).read_text().strip()
        else:
            scan = subprocess.check_output(["ssh-keyscan", "-T", "10", "-p", os.environ.get("GITEA_SSH_PORT", "2222"),
                     "-t", "ed25519,rsa", os.environ.get("VB_HOST", "localhost")], text=True, stderr=subprocess.PIPE, timeout=30)
            keys = [line.split()[1:] for line in scan.splitlines() if line and not line.startswith("#")]
            known = "\n".join("gitea.flux-system.svc.cluster.local " + " ".join(key) for key in keys if len(key) == 2)
        if not known or not any(line.startswith("gitea.flux-system.svc.cluster.local ") for line in known.splitlines()):
            raise ValueError("No SSH host key for gitea.flux-system.svc.cluster.local")
        values.update(gitea_known_hosts=known, kubeconfig_path=args.kubeconfig, flux_deploy_key_suffix=args.context_id)
        environment = dict(os.environ, **{"TF_VAR_" + key: value for key, value in values.items()})
        return subprocess.run(["tofu", "-chdir=stacks/flux-bootstrap", args.action,
                               "-input=false", "-auto-approve"], env=environment).returncode
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print(f"FAIL Flux bootstrap inputs: {type(exc).__name__}", file=sys.stderr)
        if isinstance(exc, ValueError) and not isinstance(exc, json.JSONDecodeError):
            print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
