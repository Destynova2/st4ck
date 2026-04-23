terraform {
  required_version = ">= 1.6"
  required_providers {
    matchbox = {
      source  = "poseidon/matchbox"
      version = "~> 0.5"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════
# Matchbox-driven Talos install on Scaleway Elastic Metal (tenant cluster).
#
# Companion to modules/em-talos-bootstrap. Where em-talos-bootstrap uses
# a rescue+dd bootstrap (fits the management cluster's one-shot deploy),
# this module drives a Matchbox-served iPXE boot → Talos installer flow
# that Karpenter's custom provider (issue #1 Phase B) fans out per
# tenant for autoscale.
#
# Scope for P14: scaffolding only. The Matchbox sidecar lives in
# bootstrap/platform-pod.yaml and listens on 127.0.0.1:8080 inside the
# pod. A later plat wires the iPXE chain-boot, PXE config, and Karpenter
# NodeClass consumption.
#
# Source of truth: ADR-025 §3.5 + GitHub issue #1 (Karpenter custom
# provider for EM).
# ═══════════════════════════════════════════════════════════════════════

# ─── Matchbox profile — wraps the Talos iPXE kernel + initramfs ─────────

resource "matchbox_profile" "talos" {
  name = "talos-${var.name}"

  # iPXE-style kernel/initrd references. The profile names must match
  # ConfigMap entries served from /var/lib/matchbox/profiles inside the
  # sidecar. See ./profiles/README.md for the expected layout.
  kernel = "/assets/talos/vmlinuz-amd64"
  initrd = ["/assets/talos/initramfs-amd64.xz"]

  args = [
    "initrd=initramfs-amd64.xz",
    "init_on_alloc=1",
    "slab_nomerge",
    "pti=on",
    "console=tty0",
    "console=ttyS0,115200n8",
    "printk.devkmsg=on",
    "talos.platform=metal",
    "talos.config=${var.matchbox_url}/generic?mac=$${mac:hexhyp}",
  ]

  # Talos reads the rendered machine config from Matchbox's `generic`
  # template endpoint — swap to a per-MAC template once the tenant node
  # class lands.
  generic_config = var.talos_machine_config
}

resource "matchbox_group" "node" {
  name    = var.name
  profile = matchbox_profile.talos.name

  selector = {
    mac = var.mac_address
  }

  metadata = {
    hostname = var.name
    role     = var.role
  }
}
