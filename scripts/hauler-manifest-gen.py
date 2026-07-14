#!/usr/bin/env python3
"""Generate hauler-manifest.yaml from the repo's sources of truth (ADR-034).

Sources harvested:
  Images — bootstrap/platform-pod.yaml (podman play kube)
           scripts/mirror-images.txt (curated cluster images)
  Charts — stacks/*/main.tf helm_release blocks (Tofu day-1) and
           stacks/*/flux*/ HelmRepository/OCIRepository + HelmRelease
           (Flux day-2); version pins resolve against the platform
           version registry clusters/management/versions-configmap.yaml
           (coalesce(var.x, local.platform_versions.x) / ${x} forms)
  Files  — Talos Image Factory raw images (scaleway + metal) and talosctl,
           versions from contexts/_defaults.yaml and
           envs/scaleway/image/variables.tf

Output is deterministic (sorted, no timestamp) so the checked-in manifest
diffs cleanly in PRs. Anything skipped is reported on stderr — no silent
drops (the arbor bug this replaces was a silent skip of OCI charts).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
PLATFORM_POD = REPO / "bootstrap" / "platform-pod.yaml"
MIRROR_IMAGES = REPO / "scripts" / "mirror-images.txt"
STACKS = REPO / "stacks"
DEFAULTS_YAML = REPO / "contexts" / "_defaults.yaml"
IMAGE_VARS = REPO / "envs" / "scaleway" / "image" / "variables.tf"

VERSIONS_CM = REPO / "clusters" / "management" / "versions-configmap.yaml"

HAULER_API = "content.hauler.cattle.io/v1"
PLATFORM = "linux/amd64"

REGISTRY: dict[str, str] = yaml.safe_load(VERSIONS_CM.read_text())["data"]


def warn(msg: str) -> None:
    print(f"WARN: {msg}", file=sys.stderr)


def collect_images() -> list[str]:
    images: set[str] = set()

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "image" and isinstance(value, str):
                    images.add(value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    for doc in yaml.safe_load_all(PLATFORM_POD.read_text()):
        walk(doc)

    for line in MIRROR_IMAGES.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            images.add(line)

    # Control-plane images track the deployed k8s_version (contexts), not
    # the hand-maintained tags in mirror-images.txt (sync audit 2026-07-12
    # critique #1: the list froze at the version of the cluster it was
    # generated from).
    k8s_version = yaml.safe_load(DEFAULTS_YAML.read_text())["k8s_version"]
    kube_prefixes = tuple(
        f"registry.k8s.io/kube-{c}" for c in
        ("apiserver", "controller-manager", "proxy", "scheduler")
    )

    kept = []
    for img in sorted(images):
        if "__" in img or "${" in img:  # placeholder de template bootstrap (image locale)
            warn(f"image skipped (build-time placeholder): {img}")
            continue
        name, _, tag = img.partition(":")
        if name in kube_prefixes and tag != f"v{k8s_version}":
            warn(f"kube image retagged to deployed k8s_version: {name}:v{k8s_version} (was :{tag})")
            img = f"{name}:v{k8s_version}"
        kept.append(img)
    return sorted(set(kept))


def tf_var_defaults(variables_tf: Path) -> dict[str, str]:
    if not variables_tf.is_file():
        return {}
    text = variables_tf.read_text()
    defaults = {}
    for m in re.finditer(
        r'variable\s+"([^"]+)"\s*{[^}]*?default\s*=\s*"([^"]*)"', text, re.DOTALL
    ):
        defaults[m.group(1)] = m.group(2)
    return defaults


def resolve(value: str, defaults: dict[str, str], origin: str) -> str | None:
    value = value.strip()
    m = re.fullmatch(r'"([^"]*)"', value)
    if m:
        return m.group(1)
    # registry-backed pin: coalesce(var.x, local.platform_versions.x)
    m = re.fullmatch(
        r"coalesce\(var\.(\w+),\s*local\.platform_versions\.\1\)", value
    ) or re.fullmatch(r"local\.platform_versions\.(\w+)", value)
    if m:
        resolved = REGISTRY.get(m.group(1))
        if resolved is None:
            warn(f"{origin}: {m.group(1)} missing from version registry")
        return resolved
    m = re.fullmatch(r"var\.(\w+)", value)
    if m:
        resolved = defaults.get(m.group(1)) or REGISTRY.get(m.group(1))
        if resolved is None:
            warn(f"{origin}: no default for var.{m.group(1)}")
        return resolved
    warn(f"{origin}: unresolvable expression {value!r}")
    return None


def resolve_flux_pin(value: str, origin: str) -> str | None:
    """Resolve a Flux version/tag field: literal or ${registry_key}."""
    m = re.fullmatch(r"\$\{(\w+)\}", value)
    if not m:
        return value
    resolved = REGISTRY.get(m.group(1))
    if resolved is None:
        warn(f"{origin}: {m.group(1)} missing from version registry")
    return resolved


def charts_from_tofu() -> list[dict]:
    charts = []
    for main_tf in sorted(STACKS.glob("*/main.tf")):
        defaults = tf_var_defaults(main_tf.parent / "variables.tf")
        text = main_tf.read_text()
        for m in re.finditer(
            r'resource\s+"helm_release"\s+"(\w+)"\s*{(.*?)^}', text, re.DOTALL | re.MULTILINE
        ):
            name, body = m.group(1), m.group(2)
            origin = f"{main_tf.relative_to(REPO)}:{name}"
            fields = {}
            for fm in re.finditer(
                r"^\s{2}(repository|chart|version)\s*=\s*(.+?)\s*$", body, re.MULTILINE
            ):
                fields[fm.group(1)] = fm.group(2)

            chart = resolve(fields.get("chart", '""'), defaults, origin)
            if not chart:
                continue
            if "path.module" in chart or "${" in chart:
                warn(f"{origin}: local chart skipped ({chart})")
                continue
            repo = (
                resolve(fields["repository"], defaults, origin)
                if "repository" in fields
                else None
            )
            if chart.startswith("oci://"):  # full OCI ref in chart, no repository
                repo, chart = chart.rsplit("/", 1)
            if not repo or not (repo.startswith("https://") or repo.startswith("oci://")):
                warn(f"{origin}: no usable repoURL (repo={repo!r}) — skipped")
                continue
            version = resolve(fields.get("version", '""'), defaults, origin)
            if not version:
                warn(f"{origin}: no pinned version — skipped")
                continue
            charts.append({"name": chart, "repoURL": repo, "version": version})
    return charts


def charts_from_flux() -> list[dict]:
    repos: dict[str, tuple[str, str | None]] = {}  # source name -> (url, oci tag)
    releases = []
    flux_files = sorted(
        p for d in STACKS.glob("*/flux*") if d.is_dir() for p in d.rglob("*.yaml")
    )
    for path in flux_files:
        try:
            docs = list(yaml.safe_load_all(path.read_text()))
        except yaml.YAMLError as exc:
            warn(f"{path.relative_to(REPO)}: unparseable ({exc}) — skipped")
            continue
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            kind = doc.get("kind")
            if kind in ("HelmRepository", "OCIRepository"):
                spec = doc.get("spec", {})
                repos[doc["metadata"]["name"]] = (
                    spec.get("url", ""),
                    spec.get("ref", {}).get("tag"),
                )
            elif kind == "HelmRelease":
                releases.append((path, doc))

    charts = []
    for path, doc in releases:
        origin = f"{path.relative_to(REPO)}:{doc['metadata']['name']}"
        spec = doc.get("spec", {}).get("chart", {}).get("spec", {})
        if not spec:  # chartRef → OCIRepository holds the full URL + tag
            ref = doc.get("spec", {}).get("chartRef", {})
            url, tag = repos.get(ref.get("name", ""), ("", None))
            if url.startswith("oci://") and tag:
                tag = resolve_flux_pin(str(tag), origin)
                repo_url, name = url.rsplit("/", 1)
                if tag:
                    charts.append({"name": name, "repoURL": repo_url, "version": tag})
            else:
                warn(f"{origin}: chartRef without OCI url + pinned tag — skipped")
            continue
        name = spec.get("chart")
        version = spec.get("version")
        if version:
            version = resolve_flux_pin(str(version), origin)
        source = spec.get("sourceRef", {}).get("name", "")
        repo_url, _ = repos.get(source, ("", None))
        if not (name and repo_url):
            warn(f"{origin}: missing chart name or HelmRepository {source!r} — skipped")
            continue
        if not version:
            warn(f"{origin}: no pinned version — skipped")
            continue
        charts.append({"name": name, "repoURL": repo_url.rstrip("/"), "version": str(version)})
    return charts


def talos_files() -> list[dict]:
    defaults = yaml.safe_load(DEFAULTS_YAML.read_text())
    talos_version = defaults["talos_version"]
    m = re.search(
        r'"talos_schematic_id"\s*{[^}]*?default\s*=\s*"([0-9a-f]{64})"',
        IMAGE_VARS.read_text(),
        re.DOTALL,
    )
    if not m:
        warn("talos_schematic_id default not found — Files section incomplete")
        return []
    schematic = m.group(1)
    factory = f"https://factory.talos.dev/image/{schematic}/{talos_version}"
    return [
        {"path": f"{factory}/scaleway-amd64.raw.zst"},
        {"path": f"{factory}/metal-amd64.raw.xz"},  # Elastic Metal (ADR-035)
        {
            "path": f"https://github.com/siderolabs/talos/releases/download/{talos_version}/talosctl-linux-amd64",
            "name": "talosctl",
        },
        {
            # Chart Kamaji vendore depuis git (l'OCI ghcr est ferme aux
            # anonymes) — le tarball pinne par SHA suit le registre.
            "path": f"https://github.com/clastix/kamaji/archive/{REGISTRY['kamaji_git_ref']}.tar.gz",
            "name": "kamaji-src.tar.gz",
        },
    ]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--output", default=str(REPO / "hauler-manifest.yaml"))
    args = parser.parse_args()

    images = collect_images()

    # Keep every distinct (chart, version): if Tofu day-1 and Flux day-2 pin
    # different versions, BOTH must be staged or one of the two deploy paths
    # breaks air-gapped. The drift itself is reported — target state (ADR-033)
    # is a single pin in the Flux manifests.
    versions: dict[tuple[str, str], set[str]] = {}
    for c in charts_from_tofu() + charts_from_flux():
        versions.setdefault((c["repoURL"], c["name"]), set()).add(c["version"])
    charts = []
    for (repo_url, name), vers in sorted(versions.items(), key=lambda kv: kv[0][1]):
        if len(vers) > 1:
            warn(
                f"pin drift for chart {name} ({repo_url}): "
                f"{sorted(vers)} — staging all; align Tofu default and Flux pin"
            )
        for v in sorted(vers):
            charts.append({"name": name, "repoURL": repo_url, "version": v})

    files = talos_files()

    docs = [
        {
            "apiVersion": HAULER_API,
            "kind": "Images",
            "metadata": {
                "name": "st4ck-images",
                "annotations": {"hauler.dev/platform": PLATFORM},
            },
            "spec": {"images": [{"name": img} for img in images]},
        },
        {
            "apiVersion": HAULER_API,
            "kind": "Charts",
            "metadata": {"name": "st4ck-charts"},
            "spec": {"charts": charts},
        },
        {
            "apiVersion": HAULER_API,
            "kind": "Files",
            "metadata": {"name": "st4ck-files"},
            "spec": {"files": files},
        },
    ]

    header = (
        "# Generated by scripts/hauler-manifest-gen.py (make hauler-manifest) — do not edit.\n"
        "# Sources: bootstrap/platform-pod.yaml, scripts/mirror-images.txt,\n"
        "#          stacks/*/main.tf (helm_release), stacks/*/flux*/ (HelmRelease),\n"
        "#          contexts/_defaults.yaml, envs/scaleway/image/variables.tf.\n"
        "# See ADR-034.\n"
    )
    body = yaml.safe_dump_all(docs, sort_keys=False, default_flow_style=False)
    Path(args.output).write_text(header + body)
    print(
        f"{args.output}: {len(images)} images, {len(charts)} charts, {len(files)} files",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
