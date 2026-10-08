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
# The on-VM launcher delegates seal/state checks and migration before play.
#
# Recovery story (in order of likelihood):
#   1. Normal: tfstate has the seal key. prevent_destroy blocks replacement;
#      the launcher also compares the ConfigMap with the retained/mounted key.
#   2. tfstate lost: restore the complete bootstrap backup, including outer
#      state and setup state. A saved seal key alone is not a complete restore.
#   3. Key and all its backups lost: the encrypted Raft data is unrecoverable.

resource "random_bytes" "bao_seal_key" {
  length = 32

  lifecycle {
    ignore_changes  = all
    prevent_destroy = true
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
  content_base64       = random_bytes.bao_seal_key.base64
  filename             = "${path.module}/../../../kms-output/bao-seal-key.b64"
  file_permission      = "0600"
  directory_permission = "0700"
}

# ─── Generated artifacts (uploaded to /opt/woodpecker/ on the CI VM) ────
# All four files are produced from TF state. Seal replacement is blocked by
# prevent_destroy and checked against retained data by preflight. Local files
# live under files/ (gitignored).

locals {
  artifacts_dir = "${path.module}/files"

  # Sensitive: binaryData is reversible base64, not encryption.
  configmap_yaml = join("\n---\n", [
    yamlencode({
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata   = { name = "platform-config" }
      data = {
        CI_GITEA_URL      = "http://${scaleway_instance_ip.ci.address}:3000"
        CI_OAUTH_URL      = "http://${scaleway_instance_ip.ci.address}:3000"
        CI_DOMAIN         = scaleway_instance_ip.ci.address
        CI_WP_HOST        = "http://${scaleway_instance_ip.ci.address}:8000"
        CI_ADMIN          = var.gitea_admin_user
        CI_GIT_REPO_URL   = var.git_repo_url
        CI_SCW_PROJECT_ID = var.project_id
      }
    }),
    yamlencode({
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata   = { name = "bao-seal-key" }
      binaryData = { "unseal.key" = random_bytes.bao_seal_key.base64 }
    }),
  ])

  # Secrets: pod manifest is appended as a separate doc by the on-VM
  # launcher, so podman play kube reads multi-doc.
  secrets_yaml = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = "platform-secrets" }
    type       = "Opaque"
    stringData = {
      CI_PASSWORD               = random_password.gitea_admin.result
      CI_AGENT_SECRET           = random_password.wp_agent_secret.result
      CI_SCW_IMAGE_ACCESS_KEY   = var.scw_image_access_key
      CI_SCW_IMAGE_SECRET_KEY   = var.scw_image_secret_key
      CI_SCW_CLUSTER_ACCESS_KEY = var.scw_cluster_access_key
      CI_SCW_CLUSTER_SECRET_KEY = var.scw_cluster_secret_key
    }
  })

  setup_source_sha = sha256(jsonencode({
    for name in sort(tolist(fileset("${path.module}/../../../bootstrap/tofu", "*.tf"))) :
    name => filesha256("${path.module}/../../../bootstrap/tofu/${name}")
  }))

  # Render the same pod template as the local bootstrap, with VM ports.
  vault_backend_image = "docker.io/gherynos/vault-backend@sha256:fb654a3f344ec38edf93e31b95c81a531d3a22178e31d00c25fef2b3dcbffa03"

  pod_yaml = templatefile("${path.module}/../../../bootstrap/platform-pod.yaml", {
    vault_backend_image = local.vault_backend_image
    source_dir          = "/opt/talos/repo"
    podman_socket_path  = "/run/podman/podman.sock"
    p_kms               = 8200
    p_kms_cluster       = 8201
    p_vb                = 8080
    p_gitea_http        = 3000
    p_gitea_ssh         = 2222
    p_wp_http           = 8000
    p_wp_grpc           = 9000
  })
}

resource "local_file" "platform_configmap" {
  content              = local.configmap_yaml
  filename             = "${local.artifacts_dir}/configmap.yaml"
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "local_sensitive_file" "platform_secrets" {
  content              = local.secrets_yaml
  filename             = "${local.artifacts_dir}/secrets.yaml"
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "local_sensitive_file" "platform_unseal_key" {
  content_base64 = random_bytes.bao_seal_key.base64
  # Staged binary; preflight compares it with the ConfigMap and retained key
  # before promoting a first-install key or replacing any pod.
  filename             = "${local.artifacts_dir}/unseal.key.bin"
  file_permission      = "0400"
  directory_permission = "0700"
}

resource "local_file" "platform_pod_yaml" {
  content              = local.pod_yaml
  filename             = "${local.artifacts_dir}/platform-pod.yaml"
  file_permission      = "0600"
  directory_permission = "0700"
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

# ─── Shared Private Network (CI stack OWNS it) ───────────────────────────
# Bug #31 (postmortem 2026-04-30): the cluster stack used to create its own
# private network, while the CI stack tried to look up the cluster's PN via
# data source. Because the CI VM is bootstrapped FIRST (it hosts
# vault-backend, which the cluster's tfstate depends on), the data source
# always resolved to empty → CI ended up on a default Scaleway-allocated PN
# (subnet 172.16.0.0/22) while the cluster created its own (172.16.8.0/24).
# Cross-PN traffic timed out (Scaleway PNs are L2-isolated).
#
# Fix (Option B): CI stack OWNS the canonical shared PN. Cluster stack
# switches to a data source lookup by name. Per-env shared CI VM is the
# canonical PN owner. Naming: ${ci-prefix}-pn (e.g. st4ck-dev-shared-fr-par-pn).
resource "scaleway_vpc_private_network" "shared" {
  name       = "${local.prefix}-pn"
  project_id = var.project_id
  region     = local.region
  tags       = concat(local.base_tags, ["ci-owned", "shared-pn"])
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

  # Private NIC on the shared PN owned by this stack. Scaleway auto-allocates
  # an IPAM IP from the PN's subnet; readable via .private_ips below.
  private_network {
    pn_id = scaleway_vpc_private_network.shared.id
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
#   - launch.sh delegates validation, legacy-state migration and replacement
#     to the same bootstrap-preflight.py used locally.
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
    preflight_sha = filesha256("${path.module}/../../../scripts/bootstrap-preflight.py")
    source_sha    = local.setup_source_sha
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
      "DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-yaml",
      "install -d -m 0700 /opt/woodpecker /opt/talos/kms-output /opt/talos/repo/bootstrap/tofu",
      "find /opt/woodpecker -maxdepth 1 -type f -exec chmod 0600 {} +",
    ]
  }

  provisioner "file" {
    source      = "${path.module}/../../../bootstrap/tofu/"
    destination = "/opt/talos/repo/bootstrap/tofu"
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

  # Preflight refuses any difference with the retained or mounted key.
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

  provisioner "file" {
    source      = "${path.module}/../../../scripts/bootstrap-preflight.py"
    destination = "/opt/woodpecker/bootstrap-preflight.py"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 0600 /opt/woodpecker/configmap.yaml /opt/woodpecker/secrets.yaml /opt/woodpecker/unseal.key.bin",
      "chmod +x /opt/woodpecker/launch.sh",
      "GITEA_ADMIN='${var.gitea_admin_user}' GITEA_PASSWORD='${random_password.gitea_admin.result}' bash /opt/woodpecker/launch.sh",
    ]
  }
}
