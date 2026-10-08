#!/usr/bin/env python3
"""Verify fresh node and pod resource metrics, not just APIService readiness."""

import argparse
from datetime import datetime, timezone
from decimal import Decimal
import json
from pathlib import Path
import re
import subprocess
import sys


def usage_valid(usage):
    for resource in ("cpu", "memory"):
        value = str(usage.get(resource, ""))
        match = re.fullmatch(r"(\d+(?:\.\d+)?)([eE][+-]?\d+|[numkKMGTP]i?)?", value)
        if not match or (resource == "memory" and Decimal(match[1]) <= 0):
            return False
    return True


def assess(nodes, node_metrics, pod_metrics, now=None):
    now = now or datetime.now(timezone.utc)
    expected = {n["metadata"]["name"] for n in nodes["items"]
                if any(c["type"] == "Ready" and c["status"] == "True"
                       for c in n.get("status", {}).get("conditions", []))}
    failures = []
    if not expected:
        failures.append("No Ready nodes found")
    for data, kind in ((node_metrics, "NodeMetricsList"), (pod_metrics, "PodMetricsList")):
        if data.get("kind") != kind or not data.get("items"):
            failures.append(f"{kind}: empty or invalid response")
            continue
        seen = set()
        for item in data["items"]:
            meta = item.get("metadata", {})
            key = (meta.get("namespace", ""), meta.get("name", ""))
            if not key[1] or key in seen:
                failures.append(f"{kind}: invalid or duplicate metric identity")
            seen.add(key)
            try:
                age = (now - datetime.fromisoformat(item["timestamp"].replace("Z", "+00:00"))).total_seconds()
                fresh = -30 <= age <= 300
            except (KeyError, TypeError, ValueError):
                fresh = False
            if not fresh:
                failures.append(f"{kind}/{key}: missing or stale timestamp")
            usages = ([item.get("usage", {})] if kind == "NodeMetricsList" else
                      [c.get("usage", {}) for c in item.get("containers", [])])
            if not usages or not all(usage_valid(u) for u in usages):
                failures.append(f"{kind}/{key}: missing or invalid CPU/memory usage")
        if kind == "NodeMetricsList":
            missing = expected - {name for _, name in seen}
            if missing:
                failures.append(f"Ready nodes missing metrics: {', '.join(sorted(missing))}")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kubeconfig", type=Path, required=True)
    parser.add_argument("--context", required=True)
    args = parser.parse_args()
    command = ["kubectl", "--kubeconfig", str(args.kubeconfig), "--context", args.context,
               "--request-timeout=30s", "get"]
    def read(*query):
        return json.loads(subprocess.check_output([*command, *query], text=True, timeout=40))
    try:
        failures = assess(read("nodes", "-o", "json"),
                          read("--raw", "/apis/metrics.k8s.io/v1beta1/nodes"),
                          read("--raw", "/apis/metrics.k8s.io/v1beta1/pods"))
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"FAIL Resource metrics could not be verified: {exc}", file=sys.stderr)
        return 1
    for failure in failures:
        print(f"FAIL {failure}")
    if not failures:
        print("PASS Fresh CPU/memory metrics for all Ready nodes and nonempty pod metrics")
    return int(bool(failures))


if __name__ == "__main__":
    sys.exit(main())
