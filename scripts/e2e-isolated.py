#!/usr/bin/env python3
"""Cold local E2E on an explicitly dedicated, empty Podman engine.

Only run-local files/resources are created. There is deliberately no resume,
repair, state reset, shared-context fallback, cloud stage or cleanup operation.
"""

import argparse
import base64
from contextlib import ExitStack
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

import yaml

SOURCE = Path(__file__).resolve().parents[1]
PORT_KEYS = {"kms", "kms_cluster", "vb", "gitea_http", "gitea_ssh", "wp_http", "wp_grpc"}
REQUIRED = {"run_dir", "context", "podman_connection", "subnet", "ports"}
OPTIONAL = {"talosctl", "timeout_minutes", "metrics_timeout_minutes", "lima_instance"}
ENGINE_INVENTORIES = (("ps", "-aq"), ("pod", "ps", "-q"),
                      ("volume", "ls", "-q"), ("secret", "ls", "-q"))


def validate_config(config, source=SOURCE):
    if not isinstance(config, dict) or not REQUIRED <= config.keys():
        raise ValueError(f"Config requires: {sorted(REQUIRED)}")
    if config.keys() - REQUIRED - OPTIONAL:
        raise ValueError("Unknown config keys (reuse, allowlists and cleanup are not supported)")
    for name in ("run_dir", "context", "podman_connection", "subnet"):
        if not isinstance(config[name], str) or not config[name]:
            raise ValueError(f"{name} must be a nonempty string")
    run_dir = Path(config["run_dir"])
    if not re.fullmatch(r"(?:/[A-Za-z0-9_.-]+)+", config["run_dir"]):
        raise ValueError("run_dir must not contain whitespace or shell metacharacters")
    if not run_dir.is_absolute() or run_dir.exists() or run_dir.is_symlink():
        raise ValueError("run_dir must be absolute and must NOT exist")
    if not run_dir.parent.is_dir() or run_dir != run_dir.resolve():
        raise ValueError("run_dir needs an existing canonical parent, without symlinks or '..'")
    if run_dir == source or source in run_dir.parents or run_dir in source.parents:
        raise ValueError("run_dir must be outside the source checkout")
    if not re.fullmatch(r"e2e-[a-z0-9][a-z0-9-]{5,40}", config["context"]):
        raise ValueError("context must be a unique e2e- name, 10-45 characters")
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]+", config["podman_connection"]):
        raise ValueError("Invalid dedicated Podman connection name")
    network = ipaddress.ip_network(config["subnet"])
    private_ranges = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
    if network.version != 4 or network.prefixlen != 24 or not any(
            network.subnet_of(ipaddress.ip_network(cidr)) for cidr in private_ranges):
        raise ValueError("subnet must be a dedicated private IPv4 /24")
    for reserved in ("10.244.0.0/16", "10.96.0.0/12", "127.0.0.0/8", "169.254.0.0/16"):
        if network.overlaps(ipaddress.ip_network(reserved)):
            raise ValueError("subnet overlaps Kubernetes or local endpoint ranges")
    ports = config["ports"]
    if not isinstance(ports, dict) or ports.keys() != PORT_KEYS:
        raise ValueError(f"ports must contain exactly {sorted(PORT_KEYS)}")
    if any(type(port) is not int or not 1024 <= port <= 65535 for port in ports.values()):
        raise ValueError("Ports must be integers in 1024..65535")
    if len(set(ports.values())) != len(ports):
        raise ValueError("Ports must be distinct")
    for key in ("timeout_minutes", "metrics_timeout_minutes"):
        if key in config and (type(config[key]) is not int or not 1 <= config[key] <= 120):
            raise ValueError(f"{key} must be an integer in 1..120")
    if "talosctl" in config and (not isinstance(config["talosctl"], str) or
                                not Path(config["talosctl"]).is_absolute()):
        raise ValueError("talosctl override must be an absolute executable path")
    if "lima_instance" in config and (not isinstance(config["lima_instance"], str) or
            not re.fullmatch(r"[a-z][a-z0-9-]{5,50}", config["lima_instance"]) or
            config["lima_instance"] == "default"):
        raise ValueError("lima_instance must name the dedicated VM, never default")
    return config


def dedicated_socket(connections, name):
    selected = [item for item in connections if item.get("Name") == name]
    if len(selected) != 1 or selected[0].get("Default") is not False:
        raise ValueError("Select an explicitly NON-default Podman connection")

    def path(item):
        uri = urlsplit(item.get("URI", ""))
        if uri.scheme != "unix" or uri.netloc or uri.query or uri.fragment:
            raise ValueError("Only a local unix:// socket is supported, never SSH/TCP/cloud")
        if not Path(uri.path).is_absolute():
            raise ValueError("Podman socket path must be absolute")
        return Path(uri.path).resolve()

    target = path(selected[0])
    for item in connections:
        if item.get("Default") and item.get("URI", "").startswith("unix:") and path(item) == target:
            raise ValueError("Dedicated connection aliases the default Podman socket")
    if not target.is_socket():
        raise ValueError("Dedicated Podman socket does not exist")
    return target


def snapshot_file(name):
    """Never import local state, credentials, provider caches or variable overrides."""
    path = Path(name)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("Invalid snapshot path")
    excluded = {".git", ".terraform", ".codex", ".agents", "kms-output", "__pycache__"}
    return not (excluded.intersection(path.parts) or
                any(part.startswith(".orca") or part == "orca.yaml" for part in path.parts) or
                path.name.startswith(".env") or ".tfstate" in path.name or
                ".tfvars" in path.name or path.name.endswith((".pyc", ".pem", ".key")) or
                path.name.endswith(("_override.tf", "_override.tf.json")) or
                path.name in {"override.tf", "override.tf.json", "kubeconfig", "talosconfig"})


def isolated_env(base, podman_socket, path):
    # No inherited TF/SCW/AWS/GIT/CONTAINER/KUBE settings or credentials.
    return {"PATH": path, "HOME": str(base / "home"), "LANG": "C.UTF-8",
            "TMPDIR": str(base / "tmp"), "TF_IN_AUTOMATION": "true", "TF_INPUT": "0",
            "KUBECONFIG": str(base / "kubeconfig"), "TALOSCONFIG": str(base / "talosconfig"),
            "CONTAINER_HOST": f"unix://{podman_socket}", "DOCKER_HOST": f"unix://{podman_socket}",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"}


def gitea_host_keys(output, port):
    keys = set()
    for line in output.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split()
        if (len(fields) != 3 or fields[0] != f"[127.0.0.1]:{port}" or
                fields[1] not in {"ssh-ed25519", "ssh-rsa"}):
            raise ValueError("Unexpected disposable Gitea SSH host key")
        try:
            decoded = base64.b64decode(fields[2], validate=True)
        except ValueError as error:
            raise ValueError("Malformed disposable Gitea SSH host key") from error
        if not decoded:
            raise ValueError("Empty disposable Gitea SSH host key")
        keys.add("gitea.flux-system.svc.cluster.local " + " ".join(fields[1:]))
    if not keys:
        raise ValueError("No disposable Gitea SSH host keys")
    return "\n".join(sorted(keys))


def stop_process(process):
    """Stop only this invocation's process group, never a runtime/cluster."""
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            process.wait(timeout=10)
            return
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=10)


def execute(args, *, cwd, env, timeout=1800, data=None, log_path=None):
    with ExitStack() as stack:
        stream = stack.enter_context(log_path.open("a+")) if log_path else None
        start = stream.tell() if stream else 0
        process = subprocess.Popen(args, cwd=cwd, env=env, text=True, stdin=subprocess.PIPE,
                                   stdout=stream if stream else subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            output, _ = process.communicate(data, timeout=timeout)
            if stream:
                stream.seek(start)
                output = stream.read()
            return subprocess.CompletedProcess(args, process.returncode, output)
        finally:
            stop_process(process)


class Run:
    def __init__(self, config, source=SOURCE):
        self.config = config
        self.source = source
        self.base = Path(config["run_dir"])
        self.repo = self.base / "repo"
        self.context = config["context"]
        self.network = ipaddress.ip_network(config["subnet"])
        self.talos = config.get("talosctl", "talosctl")
        self.env = None
        self.revision = None

    def command(self, args, *, log="commands", cwd=None, env=None, timeout=1800, data=None,
                check=True):
        result = execute(args, cwd=cwd or self.repo, env=env or self.env,
                         timeout=timeout, data=data, log_path=self.base / f"{log}.log")
        if check and result.returncode:
            raise RuntimeError(f"{log} failed (exit {result.returncode}); see private log")
        return result

    def wait(self, probe, seconds, label):
        deadline = time.monotonic() + seconds
        while True:
            if probe():
                print(f"PASS {label}", flush=True)
                return
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Timeout: {label}")
            time.sleep(min(10, max(0, deadline - time.monotonic())))

    def preflight(self):
        tools = ("podman", "tofu", self.talos, "kubectl", "helm", "git", "bash", "jq", "ssh-keyscan")
        if "lima_instance" in self.config:
            tools += ("limactl",)
        for tool in tools:
            if not shutil.which(tool):
                raise ValueError(f"Missing executable: {tool}")
        env = {"PATH": os.environ["PATH"], "HOME": str(Path.home()), "LANG": "C.UTF-8"}

        def read(args, target_env=env):
            result = execute(args, cwd=self.source, env=target_env, timeout=45)
            if result.returncode:
                raise RuntimeError(f"Read-only preflight failed: {args[0]}")
            return result.stdout

        connections = json.loads(read(["podman", "system", "connection", "list", "--format=json"]))
        target = dedicated_socket(connections, self.config["podman_connection"])
        self.env = isolated_env(self.base, target, os.environ["PATH"])
        self.env["E2E_PYTHON"] = sys.executable
        lima_home = (Path.home() / ".lima").resolve()
        if target.is_relative_to(lima_home) and "lima_instance" not in self.config:
            raise ValueError("Lima sockets require lima_instance to avoid duplicate port forwarding")
        if "lima_instance" in self.config:
            instance = self.config["lima_instance"]
            expected_socket = (lima_home / instance / "sock/podman.sock").resolve()
            if target != expected_socket:
                raise ValueError("Podman connection does not belong to the selected Lima VM")
            machine = json.loads(read(["limactl", "list", instance, "--json"]))
            if (machine.get("name") != instance or machine.get("status") != "Running" or
                    Path(machine.get("dir", "")).resolve() != lima_home / instance):
                raise ValueError("Selected Lima VM must already be running at the expected path")
            if machine.get("memory", 0) < 32 * 1024**3 or machine.get("cpus", 0) < 8:
                raise ValueError("Lima VM requires at least 32 GiB allocated RAM and 8 CPUs")
            mounts = machine.get("config", {}).get("mounts", [])
            if not any(m.get("writable") is True and m.get("location") == m.get("mountPoint") and
                       self.base.is_relative_to(Path(m["location"])) for m in mounts):
                raise ValueError("Lima must mount the private run directory's parent writable at the same path")
            for condition in (["-f"], ["!", "-s"]):
                read(["limactl", "shell", "--workdir=/", instance, "sudo", "-n", "test",
                      *condition, "/etc/containers/mounts.conf"])
            self.env.update(LIMA_HOME=str(lima_home), E2E_LIMA_INSTANCE=instance,
                            E2E_LIMACTL=str(Path(shutil.which("limactl")).resolve()),
                            E2E_REAL_PODMAN=str(Path(shutil.which("podman")).resolve()),
                            E2E_PODMAN_SOCKET=f"unix://{target}", E2E_RUN_DIR=str(self.base))
        # The named connection is only used for discovery. Every subsequent
        # client/provisioner uses this pinned socket, including Talos' Docker API.
        # Read-only clients can create local config/cache directories. Keep these
        # away from both the user's HOME and the not-yet-created run directory.
        with tempfile.TemporaryDirectory(prefix="st4ck-e2e-preflight-") as scratch:
            probe_env = dict(self.env, HOME=scratch, TMPDIR=scratch)
            python = execute([sys.executable, "-c", "import yaml; yaml.safe_load('probe: true')"],
                             cwd=self.source, env=probe_env, timeout=30)
            if python.returncode:
                raise ValueError("PyYAML is unavailable with private HOME; launch with "
                                 "E2E_PYTHON=/absolute/private/venv/bin/python3")
            info = json.loads(read(["podman", "info", "--format=json"], probe_env))
            if info.get("host", {}).get("security", {}).get("rootless") is not False:
                raise ValueError("Dedicated engine must be rootful")
            # The guest reports less MemTotal after kernel reservations.
            if info["host"].get("memTotal", 0) < 28 * 1024**3 or info["host"].get("cpus", 0) < 8:
                raise ValueError("Dedicated engine needs at least 28 GiB usable RAM and 8 CPUs (32 GiB VM)")
            for args in ENGINE_INVENTORIES:
                if read(["podman", *args], probe_env).strip():
                    raise ValueError("Dedicated engine must be empty (containers, pods, volumes, secrets)")
            networks = json.loads(read(["podman", "network", "ls", "--format=json"], probe_env))
            if any(item.get("name") != "podman" for item in networks):
                raise ValueError("Dedicated engine has non-default networks; no reuse is supported")
        for port in self.config["ports"].values():
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", port))
        versions = yaml.safe_load((self.source / "contexts/_defaults.yaml").read_text())
        client = read([self.talos, "version", "--client", "--short"])
        if not re.search(r"^Talos " + re.escape(versions["talos_version"]) + r"\s*$", client, re.M):
            raise ValueError("talosctl must exactly match contexts/_defaults.yaml")
        for helper in ("verify-platform-ready.py", "verify-metrics.py", "check-talos-container-mounts.sh"):
            if not (self.source / "scripts" / helper).is_file():
                raise ValueError(f"Missing required verifier: {helper}")
        print("PASS read-only preflight (no resources created)", flush=True)

    def prepare(self):
        # mkdir is exclusive: retries can never overwrite or reset an old run.
        self.base.mkdir(mode=0o700)
        for name in ("home", "tmp", "repo"):
            (self.base / name).mkdir(mode=0o700)
        names = self.command(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                             cwd=self.source, log="snapshot-files").stdout.split("\0")
        for name in sorted(set(filter(None, names))):
            if not snapshot_file(name):
                continue
            source = self.source / name
            if any(part.is_symlink() for part in (source, *source.parents)):
                raise ValueError(f"Refusing snapshot symlink: {name}")
            if not source.exists():
                continue  # Deleted tracked files stay deleted in the snapshot.
            if not source.is_file():
                raise ValueError(f"Non-file snapshot entry: {name}")
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        binary_dir = self.base / "bin"
        binary_dir.mkdir(mode=0o700)
        python_wrapper = binary_dir / "python3"
        shutil.copy2(self.source / "scripts/e2e-python.sh", python_wrapper)
        python_wrapper.chmod(0o700)
        if "lima_instance" in self.config:
            wrapper = binary_dir / "podman"
            shutil.copy2(self.repo / "scripts/e2e-podman.sh", wrapper)
            wrapper.chmod(0o700)
        self.env["PATH"] = str(binary_dir) + os.pathsep + self.env["PATH"]
        # Commit ONLY the private snapshot, never the user's checkout/index.
        self.command(["git", "init", "-b", "main"], log="snapshot")
        self.command(["git", "add", "."], log="snapshot")
        self.command(["git", "-c", "user.name=Local E2E", "-c", "user.email=e2e@local.invalid",
                      "-c", "commit.gpgsign=false", "commit", "-m", "test: isolated E2E snapshot"],
                     log="snapshot")
        self.revision = self.command(["git", "rev-parse", "HEAD"], log="snapshot").stdout.strip()
        (self.base / "revision").write_text(self.revision + "\n")
        (self.base / "config.json").write_text(json.dumps(self.config, indent=2) + "\n")
        self.password = secrets.token_hex(32)
        (self.base / "password").write_text(self.password)

    def tofu(self, stack, action, variables=None):
        args = ["tofu", f"-chdir={stack}", action, "-input=false", "-no-color"]
        if action == "apply":
            args += ["-auto-approve", "-lock-timeout=60s"]
        if variables is not None:
            path = self.base / (stack.replace("/", "-") + ".tfvars.json")
            path.write_text(json.dumps(variables))
            args += [f"-var-file={path}"]
        if stack == "stacks/pki" and action == "apply":
            args = ["bash", "scripts/apply-pki.sh", *args]
        return self.command(args, log=stack.replace("/", "-") + "-" + action)

    def bootstrap(self):
        print("Bootstrap dedicated platform", flush=True)
        self.tofu("bootstrap", "init")
        # bootstrap/main.tf may replace a pod named platform. Recheck emptiness
        # immediately before it runs; this engine must remain exclusive to E2E.
        for args in ENGINE_INVENTORIES:
            if self.command(["podman", *args], log="engine-empty").stdout.strip():
                raise ValueError("Engine no longer empty; refusing bootstrap")
        self.tofu("bootstrap", "apply", dict(source_dir=str(self.repo),
                  bootstrap_dir=str(self.base / "bootstrap"), host_ports=self.config["ports"],
                  admin_password=self.password))
        self.wait(lambda: "[setup] === Platform ready ===" in self.command(
            ["podman", "logs", "platform-tofu-setup"], log="bootstrap-ready", timeout=30).stdout,
            1200, "bootstrap sidecar completed")
        output = self.repo / "kms-output"
        output.mkdir(mode=0o700)
        self.command(["podman", "cp", "platform-tofu-setup:/kms-output/.", str(output)],
                     log="bootstrap-export")
        for name in ("root-ca.pem", "infra-ca.pem", "app-ca.pem",
                     "infra-ca-key.pem", "infra-ca-chain.pem", "app-ca-key.pem", "app-ca-chain.pem",
                     "approle-role-id.txt", "approle-secret-id.txt"):
            if not (output / name).is_file() or not (output / name).stat().st_size:
                raise RuntimeError(f"Missing bootstrap output: {name}")
        self.env.update(TF_HTTP_USERNAME=(output / "approle-role-id.txt").read_text().strip(),
                        TF_HTTP_PASSWORD=(output / "approle-secret-id.txt").read_text().strip())

    def init_stack(self, name):
        address = f"http://127.0.0.1:{self.config['ports']['vb']}/state/e2e/{self.context}/{name}"
        self.command(["tofu", f"-chdir=stacks/{name}", "init", "-input=false", "-no-color",
                      f"-backend-config=address={address}", f"-backend-config=lock_address={address}",
                      f"-backend-config=unlock_address={address}"], log=f"{name}-init")

    def stack(self, name, extra=None):
        print(f"Apply {name} with isolated AppRole state", flush=True)
        self.init_stack(name)
        values = dict(kubeconfig_path=self.env["KUBECONFIG"])
        values.update(extra or {})
        self.tofu(f"stacks/{name}", "apply", values)

    def kubectl(self, *args, **kwargs):
        return self.command(["kubectl", "--kubeconfig", self.env["KUBECONFIG"],
                             "--context", self.context, "--request-timeout=30s", *args], **kwargs)

    def cluster(self):
        versions = yaml.safe_load((self.repo / "contexts/_defaults.yaml").read_text())
        args = [self.talos, "cluster", "create", "docker", "--name", self.context,
                "--state", str(self.base / "talos-state"),
                "--talosconfig-destination", self.env["TALOSCONFIG"],
                "--subnet", str(self.network), "--host-ip", "127.0.0.1",
                "--image", "ghcr.io/siderolabs/talos:" + versions["talos_version"],
                "--kubernetes-version", versions["k8s_version"], "--workers", "3",
                "--memory-controlplanes", "6GB", "--memory-workers", "6GB",
                "--config-patch", "@" + str(self.repo / "patches/cilium-cni.yaml")]
        with (self.base / "talos-create.log").open("w") as stream:
            process = subprocess.Popen(args, cwd=self.repo, env=self.env, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                def export():
                    if process.poll() not in (None, 0):
                        raise RuntimeError("Talos creation failed; see talos-create.log")
                    return self.command([self.talos, "--context", self.context, "-n",
                        str(self.network[2]), "kubeconfig", self.env["KUBECONFIG"], "--force"],
                        log="kubeconfig-export", timeout=45, check=False).returncode == 0

                self.wait(export, 600, "private kubeconfig exported")
                mapping = json.loads(self.command(["podman", "inspect",
                    self.context + "-controlplane-1"], log="talos-inspect").stdout)
                port = mapping[0]["NetworkSettings"]["Ports"]["6443/tcp"][0]["HostPort"]
                config = yaml.safe_load(Path(self.env["KUBECONFIG"]).read_text())
                if any(len(config.get(key, [])) != 1 for key in ("contexts", "clusters", "users")):
                    raise RuntimeError("Expected a new kubeconfig with exactly one context/cluster/user")
                config["clusters"][0]["cluster"]["server"] = "https://127.0.0.1:" + str(int(port))
                config["contexts"][0]["name"] = self.context
                config["current-context"] = self.context
                Path(self.env["KUBECONFIG"]).write_text(yaml.safe_dump(config))
                self.wait(lambda: self.kubectl("get", "--raw", "/readyz", log="api-ready",
                          timeout=45, check=False).returncode == 0, 300, "Kubernetes API")

                def registered():
                    result = self.kubectl("get", "nodes", "-o", "json", log="nodes", timeout=45)
                    return len(json.loads(result.stdout)["items"]) == 4

                self.wait(registered, 300, "all four nodes registered")
                self.command(["bash", "scripts/check-talos-container-mounts.sh", self.context,
                              *[str(self.network[n]) for n in range(2, 6)]], log="talos-mounts",
                             env=dict(self.env, TALOSCTL=self.talos), timeout=180)
                # Talos 1.12 waits for CNI. Install Cilium while its own readiness
                # process is running; never kill the checker and call that success.
                self.stack("cni")
                if process.wait(timeout=600):
                    raise RuntimeError("Talos final health checks failed")
            finally:
                stop_process(process)

    def read_gitea_keys(self):
        ssh_port = self.config["ports"]["gitea_ssh"]
        keys = self.command(["ssh-keyscan", "-T", "10", "-p", str(ssh_port), "-t", "ed25519,rsa",
                             "127.0.0.1"], log="gitea-host-key", timeout=30).stdout
        self.gitea_known_hosts = gitea_host_keys(keys, ssh_port)
        print("PASS disposable Gitea SSH host keys (before Talos)", flush=True)

    def flux(self):
        port = self.config["ports"]["gitea_http"]
        # Bootstrap clones /source into this engine's own Gitea. Verify the SHA
        # instead of pushing anything to the user's existing remotes.
        auth = base64.b64encode(("talos:" + self.password).encode()).decode()
        env = dict(self.env, GIT_CONFIG_COUNT="2", GIT_CONFIG_KEY_0="http.extraHeader",
                   GIT_CONFIG_VALUE_0="Authorization: Basic " + auth,
                   GIT_CONFIG_KEY_1="credential.helper", GIT_CONFIG_VALUE_1="")
        result = self.command(["git", "ls-remote", f"http://127.0.0.1:{port}/talos/talos.git",
                               "refs/heads/main"], env=env, log="gitea-revision", timeout=60)
        if result.stdout.split() != [self.revision, "refs/heads/main"]:
            raise RuntimeError("Disposable Gitea does not contain the exact snapshot revision")
        ssh_port = self.config["ports"]["gitea_ssh"]
        self.stack("flux-bootstrap", dict(gitea_external_host=str(self.network[1]),
            gitea_external_port=ssh_port,
            gitea_known_hosts=self.gitea_known_hosts,
            gitea_api_url=f"http://127.0.0.1:{port}", gitea_admin_user="talos",
            gitea_repo_owner="talos", gitea_admin_password=self.password,
            flux_deploy_key_suffix=self.context))

    def verify(self):
        common = ["--kubeconfig", self.env["KUBECONFIG"], "--context", self.context]

        def readiness():
            result = self.command([sys.executable, "scripts/verify-platform-ready.py", *common,
                                   "--revision", self.revision], log="platform-strict",
                                  timeout=600, check=False)
            summary = re.search(r"Platform: ([1-9][0-9]*) expected objects, 0 failures, "
                                r"0 explicit exemptions", result.stdout)
            return result.returncode == 0 and summary is not None

        self.wait(readiness, self.config.get("timeout_minutes", 45) * 60,
                  "strict inventory at exact snapshot revision, zero exemptions")
        self.wait(lambda: self.command([sys.executable, "scripts/verify-metrics.py", *common],
                  log="metrics", timeout=180, check=False).returncode == 0,
                  self.config.get("metrics_timeout_minutes", 10) * 60, "functional metrics")
        # Metrics warming must not conceal a platform regression during that wait.
        if not readiness():
            raise RuntimeError("Platform regressed during metrics verification")
        nodes = json.loads(self.kubectl("get", "nodes", "-o", "json", log="final-nodes").stdout)["items"]
        if len(nodes) != 4 or any(not any(c["type"] == "Ready" and c["status"] == "True"
            for c in node.get("status", {}).get("conditions", [])) for node in nodes):
            raise RuntimeError("Not all four expected nodes are Ready")
        pods = json.loads(self.kubectl("get", "pods", "-A", "-o", "json", log="final-pods").stdout)["items"]
        if not pods or any(pod.get("status", {}).get("phase") != "Succeeded" and not (
            pod.get("status", {}).get("phase") == "Running" and any(
                c["type"] == "Ready" and c["status"] == "True"
                for c in pod.get("status", {}).get("conditions", []))) for pod in pods):
            raise RuntimeError("Empty pod inventory or non-ready workloads")

    def run(self):
        self.prepare()
        self.bootstrap()
        self.read_gitea_keys()
        self.cluster()
        for stack in ("pki", "monitoring", "identity", "security", "storage", "autoscaling"):
            self.stack(stack)
        self.flux()
        self.verify()
        (self.base / "result.json").write_text(json.dumps(dict(
            result="PASS", revision=self.revision, context=self.context,
            strict_readiness=True, metrics=True, exemptions=[]), indent=2) + "\n")
        print(f"E2E PASS: {self.revision}; retained isolated run: {self.base}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--check", action="store_true", help="Read-only preflight; do not create a run")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        config = validate_config(json.loads(args.config.read_text()))
        run = Run(config)
        run.preflight()
        if not args.check:
            run.run()
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError, KeyError) as error:
        print(f"E2E FAIL: {error}. No resources cleaned up; inspect the private run directory.",
              file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("E2E interrupted. Resources retained; no automatic cleanup.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
