terraform {
  required_version = ">= 1.6"
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════
# CI stage — deploys one CI VM (Gitea + Woodpecker + platform pod).
#
# Naming: {namespace}-{env}-{instance}-{region}-ci
#   - Dev shared CI    → instance='shared' → st4ck-dev-shared-fr-par-ci
#   - Prod per-instance → instance='eu'    → st4ck-prod-eu-fr-par-ci
# ═══════════════════════════════════════════════════════════════════════

module "context" {
  source        = "../../../modules/context"
  context_file  = var.context_file
  defaults_file = "${path.module}/../../../contexts/_defaults.yaml"
}

locals {
  ctx              = module.context.context
  namespace        = local.ctx.namespace
  env              = local.ctx.env
  instance         = local.ctx.instance
  region           = local.ctx.region
  owner            = lookup(local.ctx, "owner", "unknown")
  zone             = lookup(local.ctx, "zone", "${local.region}-1")
  management_cidrs = lookup(local.ctx, "management_cidrs", [])

  prefix = "${local.namespace}-${local.env}-${local.instance}-${local.region}"
  ci_id  = "${local.prefix}-ci"

  base_tags = [
    "app:${local.namespace}",
    "env:${local.env}",
    "instance:${local.instance}",
    "region:${local.region}",
    "component:ci",
    "managed-by:opentofu",
    "owner:${local.owner}",
    "context-id:${local.prefix}",
  ]
}

provider "scaleway" {
  access_key = var.scw_access_key
  secret_key = var.scw_secret_key
  zone       = local.zone
  region     = local.region
  project_id = var.project_id
}

resource "random_password" "gitea_admin" {
  length  = 24
  special = false

  lifecycle {
    ignore_changes = all
  }
}

# ─── Platform pod artifacts — generated in TF, shipped to the CI VM ─────
#
# Postmortem 2026-04-26: the previous design had an on-VM shell script
# (setup.sh.tpl) generate the OpenBao seal key with `openssl rand` and
# append it to a configmap. Any re-run of the script regenerated the key,
# rendering the bao raft storage permanently undecryptable (static-seal
# mode encrypts data with the file content). When `null_resource.ci_bootstrap`
# fired its trigger after a server in-place update (private NIC added),
# all tfstate stored in vault-backend was lost.
#
# Cleanup strategy: ALL state-bearing artifacts (seal key, configmap,
# secrets, patched pod manifest) are now generated as Terraform resources.
# The on-VM script is a thin launcher that just runs `podman play kube`.
# Re-runs are deterministic and idempotent.
#
# Recovery story (in order of likelihood):
#   1. Normal: tfstate has the seal key. random_bytes.bao_seal_key has
#      lifecycle.ignore_changes=all so even `tofu taint` can't rotate it.
#   2. tfstate lost, VM intact: kms-output/bao-seal-key.b64 holds the key
#      (workstation-local backup, gitignored). SCP it back to the VM and
#      manually rebuild tfstate via `tofu state import`.
#   3. Both lost: bao data is permanently lost. Wipe + redeploy.

resource "random_bytes" "bao_seal_key" {
  length = 32

  lifecycle {
    ignore_changes = all
  }
}

resource "random_password" "wp_agent_secret" {
  length  = 64
  special = false

  lifecycle {
    ignore_changes = all
  }
}

# Workstation-local backup of the seal key — gitignored.
resource "local_sensitive_file" "bao_seal_key_backup" {
  content_base64  = random_bytes.bao_seal_key.base64
  filename        = "${path.module}/../../../kms-output/bao-seal-key.b64"
  file_permission = "0600"
}

# ─── Generated artifacts (uploaded to /opt/woodpecker/ on the CI VM) ────
# All four files are produced from TF state, so re-applies are deterministic
# and the seal key value never changes (random_bytes.bao_seal_key has
# ignore_changes=all). The local files live under files/ — gitignored.

locals {
  artifacts_dir = "${path.module}/files"

  # Plain configmap (non-sensitive): platform-config + bao-seal-key (whose
  # binaryData is the seal key, base64-encoded — same value as the one in
  # /opt/woodpecker/unseal.key uploaded below).
  configmap_yaml = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: platform-config
    data:
      CI_GITEA_URL: "http://${scaleway_instance_ip.ci.address}:3000"
      CI_OAUTH_URL: "http://${scaleway_instance_ip.ci.address}:3000"
      CI_DOMAIN: "${scaleway_instance_ip.ci.address}"
      CI_WP_HOST: "http://${scaleway_instance_ip.ci.address}:8000"
      CI_ADMIN: "${var.gitea_admin_user}"
      CI_GIT_REPO_URL: "${var.git_repo_url}"
      CI_SCW_PROJECT_ID: "${var.project_id}"
    ---
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: bao-seal-key
    binaryData:
      unseal.key: ${random_bytes.bao_seal_key.base64}
  YAML

  # Secrets: pod manifest is appended as a separate doc by the on-VM
  # launcher, so podman play kube reads multi-doc.
  secrets_yaml = <<-YAML
    apiVersion: v1
    kind: Secret
    metadata:
      name: platform-secrets
    type: Opaque
    stringData:
      CI_PASSWORD: "${random_password.gitea_admin.result}"
      CI_AGENT_SECRET: "${random_password.wp_agent_secret.result}"
      CI_SCW_IMAGE_ACCESS_KEY: "${var.scw_image_access_key}"
      CI_SCW_IMAGE_SECRET_KEY: "${var.scw_image_secret_key}"
      CI_SCW_CLUSTER_ACCESS_KEY: "${var.scw_cluster_access_key}"
      CI_SCW_CLUSTER_SECRET_KEY: "${var.scw_cluster_secret_key}"
  YAML

  # Pod manifest: the upstream YAML in bootstrap/ has two placeholders
  # filled in via TF (image pin + source dir).
  vault_backend_image = "docker.io/gherynos/vault-backend@sha256:fb654a3f344ec38edf93e31b95c81a531d3a22178e31d00c25fef2b3dcbffa03"

  pod_yaml = replace(
    replace(
      file("${path.module}/../../../bootstrap/platform-pod.yaml"),
      "__VAULT_BACKEND_IMAGE__",
      local.vault_backend_image,
    ),
    "__SOURCE_DIR__",
    "/opt/talos/repo",
  )
}

resource "local_file" "platform_configmap" {
  content              = local.configmap_yaml
  filename             = "${local.artifacts_dir}/configmap.yaml"
  file_permission      = "0644"
  directory_permission = "0755"
}

resource "local_sensitive_file" "platform_secrets" {
  content              = local.secrets_yaml
  filename             = "${local.artifacts_dir}/secrets.yaml"
  file_permission      = "0600"
  directory_permission = "0755"
}

resource "local_sensitive_file" "platform_unseal_key" {
  content_base64       = random_bytes.bao_seal_key.base64
  # `.bin` suffix (not .tf) — the TF file provisioner silently drops files
  # with .tf extension on upload (probably a guard against accidentally
  # shipping TF sources). The provisioner DOES preserve source basename
  # over the destination's explicit filename, so we name it as we want it
  # to land on the VM. launch.sh then idempotently promotes it.
  filename             = "${local.artifacts_dir}/unseal.key.bin"
  file_permission      = "0400"
  directory_permission = "0755"
}

resource "local_file" "platform_pod_yaml" {
  content              = local.pod_yaml
  filename             = "${local.artifacts_dir}/platform-pod.yaml"
  file_permission      = "0644"
  directory_permission = "0755"
}

# ─── Security group ─────────────────────────────────────────────────────

resource "scaleway_instance_security_group" "ci" {
  name                    = "${local.ci_id}-sg"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"
  tags                    = local.base_tags

  dynamic "inbound_rule" {
    for_each = toset(local.management_cidrs)
    content {
      action   = "accept"
      port     = 22
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  dynamic "inbound_rule" {
    for_each = toset(local.management_cidrs)
    content {
      action   = "accept"
      port     = 2222
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  dynamic "inbound_rule" {
    for_each = toset(local.management_cidrs)
    content {
      action   = "accept"
      port     = 3000
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  dynamic "inbound_rule" {
    for_each = toset(local.management_cidrs)
    content {
      action   = "accept"
      port     = 8000
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  # vault-backend (:8080) + OpenBao (:8200) reachable for tunnel use
  dynamic "inbound_rule" {
    for_each = toset(local.management_cidrs)
    content {
      action   = "accept"
      port     = 8080
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }
}

resource "scaleway_instance_ip" "ci" {
  tags = local.base_tags
}

# ─── Optional VPC attachment ─────────────────────────────────────────────
# Looks up the cluster's existing private network by name convention
# (created by envs/scaleway/main.tf as `${prefix}-pn`). Only resolves when
# var.vpc_attach_instance is non-empty.
data "scaleway_vpc_private_network" "cluster" {
  count      = var.vpc_attach_instance == "" ? 0 : 1
  name       = "${local.namespace}-${local.env}-${var.vpc_attach_instance}-${local.region}-pn"
  project_id = var.project_id
  region     = local.region
}

resource "scaleway_instance_server" "ci" {
  name  = local.ci_id
  type  = var.instance_type
  image = "ubuntu_noble"
  ip_id = scaleway_instance_ip.ci.id

  security_group_id = scaleway_instance_security_group.ci.id

  root_volume {
    size_in_gb = var.root_disk_size
  }

  # Optional private NIC into the cluster's VPC. Scaleway auto-allocates an
  # IPAM IP from the VPC's subnet; readable via .private_ip below.
  dynamic "private_network" {
    for_each = data.scaleway_vpc_private_network.cluster
    content {
      pn_id = private_network.value.id
    }
  }

  user_data = {
    cloud-init = templatefile("${path.module}/cloud-init.yml.tpl", {
      ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
    })
  }

  tags = concat(local.base_tags, ["role:ci", "service:gitea", "service:woodpecker", "service:openbao"])
}

# ─── Provisioner: ship TF-generated artifacts and launch the platform pod
#
# Upload pattern:
#   - All four pod artifacts come from local_file/local_sensitive_file
#     resources above (deterministic, idempotent across re-applies).
#   - launch.sh is the only on-VM script; it just stops any running
#     platform pod and re-runs `podman play kube`. It never generates
#     state-bearing content.
#
# Trigger: hashes of every uploaded artifact, so any TF-side change
# (new image pin, rotated Gitea password, etc.) re-uploads + restarts.
# Server ID is included so VM rebuild also re-bootstraps.

resource "null_resource" "ci_bootstrap" {
  depends_on = [
    scaleway_instance_server.ci,
    local_file.platform_configmap,
    local_sensitive_file.platform_secrets,
    local_sensitive_file.platform_unseal_key,
    local_file.platform_pod_yaml,
  ]

  triggers = {
    server_id     = scaleway_instance_server.ci.id
    configmap_sha = local_file.platform_configmap.content_sha256
    secrets_sha   = local_sensitive_file.platform_secrets.content_sha256
    pod_sha       = local_file.platform_pod_yaml.content_sha256
    launcher_sha  = sha256(file("${path.module}/launch.sh"))
    # NOTE: NOT triggering on the unseal key — random_bytes.bao_seal_key
    # has ignore_changes=all so its content is fixed for the life of the
    # tfstate. Including it here is harmless but slightly misleading.
  }

  connection {
    type        = "ssh"
    host        = scaleway_instance_ip.ci.address
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait || true",
      "mkdir -p /opt/woodpecker /opt/talos/kms-output /opt/talos/repo/bootstrap /tmp/empty-source",
    ]
  }

  provisioner "file" {
    source      = "${path.module}/../../../bootstrap/"
    destination = "/opt/talos/repo/bootstrap"
  }

  provisioner "file" {
    source      = local_file.platform_pod_yaml.filename
    destination = "/opt/woodpecker/platform-pod.yaml"
  }

  provisioner "file" {
    source      = local_file.platform_configmap.filename
    destination = "/opt/woodpecker/configmap.yaml"
  }

  provisioner "file" {
    source      = local_sensitive_file.platform_secrets.filename
    destination = "/opt/woodpecker/secrets.yaml"
  }

  # Idempotent: launch.sh refuses to overwrite an existing on-disk key.
  # NOTE: source must be a LITERAL path string, not an attribute of a
  # sensitive resource — OpenTofu's provisioner refuses to upload files
  # whose source path was derived from a sensitive value (transitive
  # taint). We use the same string the local_sensitive_file resource
  # below uses.
  provisioner "file" {
    source      = "${path.module}/files/unseal.key.bin"
    destination = "/opt/woodpecker/unseal.key.bin"
  }

  provisioner "file" {
    source      = "${path.module}/launch.sh"
    destination = "/opt/woodpecker/launch.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 0600 /opt/woodpecker/secrets.yaml /opt/woodpecker/unseal.key.bin",
      "chmod +x /opt/woodpecker/launch.sh",
      "GITEA_ADMIN='${var.gitea_admin_user}' GITEA_PASSWORD='${random_password.gitea_admin.result}' bash /opt/woodpecker/launch.sh",
    ]
  }
}
