# ─── Versions ───────────────────────────────────────────────────────────────
TALOS_VERSION      ?= v1.12.6
KUBERNETES_VERSION ?= 1.35.4
IMAGER_IMAGE       ?= ghcr.io/siderolabs/imager:$(TALOS_VERSION)
CILIUM_VERSION     ?= 1.17.13

# ─── Output directory ──────────────────────────────────────────────────────
OUT_DIR            ?= _out
