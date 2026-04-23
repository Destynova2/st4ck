terraform {
  required_version = ">= 1.6"
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════
# Scaleway Elastic Metal + Talos via "dummy install → rescue → wipe → dd"
#
# Talos is NOT in Scaleway's EM OS catalog, and there is no BYO-image
# install API. The provider also rejects `install = null` on
# scaleway_baremetal_server (see ADR-025 §3.5 — "Option B drops the TF
# managed resource, unacceptable"). So we take Option A: install a
# dummy Ubuntu first, then wipe + re-flash with Talos.
#
#   Step 0. CreateServer with install { os_id = ubuntu_jammy } — provider-
#           compliant (~+10 min penalty vs. bare-EM, but keeps the server
#           under TF state).
#   Step 1. Reboot into rescue mode (Debian ramdisk, SSH key auto-injected).
#   Step 2. Wipe the dummy Ubuntu: `wipefs -af $DISK && dd if=/dev/zero
#           of=$DISK bs=4M count=128` — makes sure the next dd starts from
#           a clean GPT + no stale superblocks.
#   Step 3. dd Talos RAW image onto the disk.
#   Step 4. Reboot normal — Talos boots in maintenance mode (port 50000
#           open, no config).
#   Step 5. `talosctl apply-config --insecure` — kubelet bootstrap, node
#           joins the cluster.
#
# Source of truth: ADR-025 §3.5 + GitHub issue #1 + scripts/em-bootstrap.sh.
# Cost: ~€0.077/h on EM-A116X-SSD entry tier (hourly billing).
# ═══════════════════════════════════════════════════════════════════════

# ─── Step 0 — Dummy Ubuntu Jammy (provider-compliant install block) ─────
#
# Verified via `scw -p st4ck-readonly baremetal os list zone=fr-par-2`:
#   id: 96e5f0f2-d216-4de2-8a15-68730d877885
#   name: Ubuntu, version: 22.04 LTS (Jammy Jellyfish)
#
# Using the data source (instead of hard-coding the UUID) so fr-par-1 and
# later zones resolve to the equivalent OS without a code change.
data "scaleway_baremetal_os" "ubuntu_jammy" {
  zone    = var.zone
  name    = "Ubuntu"
  version = "22.04 LTS (Jammy Jellyfish)"
}

resource "scaleway_baremetal_server" "this" {
  name        = var.name
  hostname    = var.name
  offer       = var.offer
  zone        = var.zone
  project_id  = var.project_id
  ssh_key_ids = [var.ssh_key_id]
  tags        = concat(var.tags, ["managed-by=opentofu", "talos=rescue-dd"])

  # Dummy Ubuntu install — Scaleway v2 provider flattens the install fields
  # onto the server resource (no nested `install` block). The OS is wiped
  # in Step 2 before Talos is flashed in Step 3.
  os = data.scaleway_baremetal_os.ubuntu_jammy.os_id

  # Once Talos is flashed, the Scaleway-reported `os` still points at
  # Ubuntu. Ignoring the drift keeps apply idempotent post-bootstrap.
  lifecycle {
    ignore_changes = [os]
  }
}

# ─── Step 1+2 — rescue + wipe the dummy OS ──────────────────────────────

resource "null_resource" "wipe_dummy_os" {
  triggers = {
    server_id = scaleway_baremetal_server.this.id
  }

  # Stage 1 — reboot into rescue and wait for SSH.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SCW_ACCESS_KEY = var.scw_access_key
      SCW_SECRET_KEY = var.scw_secret_key
      SERVER_ID      = scaleway_baremetal_server.this.id
      ZONE           = var.zone
      SERVER_IP      = scaleway_baremetal_server.this.ips[0].address
      WAIT_MIN       = var.wait_rescue_minutes
      SSH_KEY_PATH   = pathexpand(var.ssh_private_key_path)
    }
    command = <<-EOT
      set -euo pipefail
      echo "[step 1] reboot into rescue: $SERVER_ID"
      scw baremetal server reboot "$SERVER_ID" zone="$ZONE" boot-type=rescue >/dev/null

      echo "[step 1] waiting for SSH on $SERVER_IP (max $${WAIT_MIN} min)"
      DEADLINE=$(($(date +%s) + WAIT_MIN * 60))
      until ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=5 -o BatchMode=yes \
                rescue@"$SERVER_IP" "echo rescue-ssh-up" 2>/dev/null; do
        if [ $(date +%s) -gt $DEADLINE ]; then
          echo "TIMEOUT waiting for rescue SSH"; exit 1
        fi
        sleep 10
      done
      echo "[step 1] rescue SSH up"
    EOT
  }

  # Stage 2 — wipe the dummy OS: drop filesystem signatures + zero the
  # first 512 MiB so the next dd starts from a pristine disk.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SERVER_IP    = scaleway_baremetal_server.this.ips[0].address
      SSH_KEY_PATH = pathexpand(var.ssh_private_key_path)
    }
    command = <<-EOT
      set -euo pipefail
      echo "[step 2] wiping dummy Ubuntu via rescue SSH"
      ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          rescue@"$SERVER_IP" "bash -s" <<'REMOTE'
      set -euxo pipefail
      apt-get update -qq && apt-get install -y -qq util-linux
      DISK=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')
      echo "Detected disk: $DISK"
      # ─── Idempotency guard — refuse to wipe a live Talos disk ────
      # On `tofu taint null_resource.wipe_dummy_os` the resource would
      # re-run against whatever is on disk. Signatures:
      #   - Talos-flashed → ABORT (rebuild from scratch via taint on
      #     scaleway_baremetal_server.this instead).
      #   - Ubuntu/GRUB   → OK, wipe.
      #   - Unknown       → ABORT (fail-safe).
      FIRSTMB=$(dd if="$DISK" bs=1M count=4 2>/dev/null | strings | head -n 500)
      if echo "$FIRSTMB" | grep -qiE 'TALOS|siderolabs'; then
        echo "ABORT: disk appears Talos-flashed; refusing to wipe. Taint scaleway_baremetal_server.this to rebuild from scratch."
        exit 1
      fi
      echo "$FIRSTMB" | grep -qiE 'ubuntu|jammy|grub' \
        || { echo "ABORT: disk signature unrecognized (neither Talos nor Ubuntu); refusing (safety)."; exit 1; }
      # Drop any filesystem signatures first (fast).
      wipefs -af "$DISK"
      # Zero the first 512 MiB — covers GPT + common stray superblocks.
      dd if=/dev/zero of="$DISK" bs=4M count=128 oflag=direct status=progress
      sync
      echo "Disk wiped."
      REMOTE
    EOT
  }

  depends_on = [scaleway_baremetal_server.this]
}

# ─── Step 3+4+5 — dd Talos + reboot normal + apply-config ───────────────

resource "null_resource" "talos_install" {
  triggers = {
    server_id   = scaleway_baremetal_server.this.id
    image_url   = var.talos_image_url
    config_hash = sha256(var.talos_machine_config)
  }

  # Stage 3 — dd Talos image onto the clean disk.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SERVER_IP    = scaleway_baremetal_server.this.ips[0].address
      IMAGE_URL    = var.talos_image_url
      SSH_KEY_PATH = pathexpand(var.ssh_private_key_path)
    }
    command = <<-EOT
      set -euo pipefail
      echo "[step 3] dd Talos image to disk via rescue SSH"
      # Pass IMAGE_URL into the heredoc body (envsubst-style by escaping locally).
      ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          rescue@"$SERVER_IP" \
          "IMAGE_URL='$IMAGE_URL' bash -s" <<'REMOTE'
      set -euxo pipefail
      apt-get install -y -qq curl xz-utils
      DISK=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')
      echo "Detected disk: $DISK"
      curl -fsSL "$IMAGE_URL" | xz -d | dd of="$DISK" bs=4M oflag=direct status=progress
      sync
      echo "Disk flashed."
      REMOTE
    EOT
  }

  # Stage 4 — reboot normal, wait for Talos maintenance API.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SCW_ACCESS_KEY = var.scw_access_key
      SCW_SECRET_KEY = var.scw_secret_key
      SERVER_ID      = scaleway_baremetal_server.this.id
      ZONE           = var.zone
      SERVER_IP      = scaleway_baremetal_server.this.ips[0].address
      WAIT_MIN       = var.wait_talos_minutes
    }
    command = <<-EOT
      set -euo pipefail
      echo "[step 4] reboot normal"
      scw baremetal server reboot "$SERVER_ID" zone="$ZONE" boot-type=normal >/dev/null

      echo "[step 4] waiting for Talos maintenance API on $SERVER_IP:50000 (max $${WAIT_MIN} min)"
      DEADLINE=$(($(date +%s) + WAIT_MIN * 60))
      until nc -zw5 "$SERVER_IP" 50000; do
        if [ $(date +%s) -gt $DEADLINE ]; then
          echo "TIMEOUT waiting for Talos maintenance API"; exit 1
        fi
        sleep 10
      done
      echo "[step 4] Talos maintenance up — ready for talosctl apply-config"
    EOT
  }

  # Stage 5 — apply machine config (insecure mode, port 50000).
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SERVER_IP      = scaleway_baremetal_server.this.ips[0].address
      MACHINE_CONFIG = var.talos_machine_config
    }
    command = <<-EOT
      set -euo pipefail
      command -v talosctl >/dev/null || { echo "talosctl required (brew install siderolabs/tap/talosctl)"; exit 1; }
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT
      printf '%s' "$MACHINE_CONFIG" > "$tmp"
      echo "[step 5] talosctl apply-config --insecure -n $SERVER_IP"
      talosctl apply-config --insecure -n "$SERVER_IP" -f "$tmp"
      echo "[step 5] config applied — Talos will reboot into normal mode"
    EOT
  }

  depends_on = [
    scaleway_baremetal_server.this,
    null_resource.wipe_dummy_os,
  ]
}
