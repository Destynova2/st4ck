# ─── Output directory ──────────────────────────────────────────────────────
# Version pins do NOT live here. Single sources of truth:
#   - clusters/management/versions-configmap.yaml  (charts/providers — tofu,
#     Flux substituteFrom, hauler manifest)
#   - contexts/_defaults.yaml                      (talos/k8s machine configs)
# The former TALOS_VERSION/KUBERNETES_VERSION/CILIUM_VERSION/IMAGER_IMAGE
# variables here were consumed by nothing and had drifted from the real pins
# (hanoi audit 2026-07-12, finding #1).
OUT_DIR            ?= _out
