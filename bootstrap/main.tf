terraform {
  required_providers {
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

# ─── Variables ──────────────────────────────────────────────────────────

variable "source_dir" {
  description = "Host path to mount as /source in the pod (repo root or empty dir)"
  type        = string
}

variable "bootstrap_dir" {
  description = "Working directory for generated files"
  type        = string
  default     = "/tmp/platform-local"
}

# Ports hote publies par le pod. Surchargables quand un autre projet
# local occupe deja un port (ex.: make bootstrap VB_PORT=18080).
variable "host_ports" {
  description = "Host-side ports published by the platform pod."
  type = object({
    kms         = number
    kms_cluster = number
    vb          = number
    gitea_http  = number
    gitea_ssh   = number
    wp_http     = number
    wp_grpc     = number
  })
  default = {
    kms         = 8200
    kms_cluster = 8201
    vb          = 8080
    gitea_http  = 3000
    gitea_ssh   = 2222
    wp_http     = 8000
    wp_grpc     = 9000
  }
}

variable "gitea_url" {
  description = "Gitea external URL (used by WP OAuth callback). Null = derived from host_ports."
  type        = string
  default     = null
}

variable "oauth_url" {
  description = "OAuth URL (browser-accessible Gitea URL). Null = derived from host_ports."
  type        = string
  default     = null
}

variable "domain" {
  description = "Domain for Gitea server"
  type        = string
  default     = "127.0.0.1"
}

variable "wp_host" {
  description = "Woodpecker external URL. Null = derived from host_ports."
  type        = string
  default     = null
}

variable "admin_user" {
  description = "Admin username for Gitea and Woodpecker"
  type        = string
  default     = "talos"
}

variable "admin_password" {
  description = "Admin password for Gitea, Woodpecker, and OpenBao bootstrap-admin"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 16
    error_message = "admin_password must be at least 16 characters."
  }
}

variable "git_repo_url" {
  description = "Git repo URL for Woodpecker"
  type        = string
  default     = "file:///source"
}

variable "vault_backend_image" {
  description = "Container image for vault-backend (use localhost/vault-backend:<commit> for local build)"
  type        = string
  default     = "docker.io/gherynos/vault-backend@sha256:fb654a3f344ec38edf93e31b95c81a531d3a22178e31d00c25fef2b3dcbffa03"
}

variable "scw_project_id" {
  type    = string
  default = "dummy"
}
variable "scw_image_access_key" {
  type    = string
  default = "dummy"
}
variable "scw_image_secret_key" {
  type      = string
  default   = "dummy"
  sensitive = true
}
variable "scw_cluster_access_key" {
  type    = string
  default = "dummy"
}
variable "scw_cluster_secret_key" {
  type      = string
  default   = "dummy"
  sensitive = true
}

# ─── Generated secrets ─────────────────────────────────────────────────

resource "random_bytes" "seal_key" {
  length = 32

  # CRITICAL — see envs/scaleway/ci/main.tf:random_bytes.bao_seal_key for
  # the full postmortem. This key encrypts the OpenBao raft data under
  # static-seal mode; rotating it without first wiping bao data destroys
  # every secret in the bootstrap pod's bao instance (including local
  # tfstate via vault-backend). ignore_changes=all means even a `tofu
  # taint` or version bump can't trigger an automatic rotation.
  lifecycle {
    ignore_changes = all
  }
}

resource "random_password" "agent_secret" {
  length  = 64
  special = false

  lifecycle {
    ignore_changes = all
  }
}

# ─── ConfigMap YAML ────────────────────────────────────────────────────

locals {
  configmap_yaml = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: platform-config
    data:
      CI_GITEA_URL: "${local.gitea_url}"
      CI_OAUTH_URL: "${local.oauth_url}"
      CI_DOMAIN: "${var.domain}"
      CI_WP_HOST: "${local.wp_host}"
      CI_ADMIN: "${var.admin_user}"
      CI_GIT_REPO_URL: "${var.git_repo_url}"
      CI_SCW_PROJECT_ID: "${var.scw_project_id}"
    ---
    apiVersion: v1
    kind: Secret
    metadata:
      name: platform-secrets
    type: Opaque
    stringData:
      CI_PASSWORD: "${var.admin_password}"
      CI_AGENT_SECRET: "${random_password.agent_secret.result}"
      CI_SCW_IMAGE_ACCESS_KEY: "${var.scw_image_access_key}"
      CI_SCW_IMAGE_SECRET_KEY: "${var.scw_image_secret_key}"
      CI_SCW_CLUSTER_ACCESS_KEY: "${var.scw_cluster_access_key}"
      CI_SCW_CLUSTER_SECRET_KEY: "${var.scw_cluster_secret_key}"
    ---
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: bao-seal-key
    binaryData:
      unseal.key: ${random_bytes.seal_key.base64}
  YAML

  # URLs derivees des ports (surcharge explicite possible via les vars)
  gitea_url = coalesce(var.gitea_url, "http://host.containers.internal:${var.host_ports.gitea_http}")
  oauth_url = coalesce(var.oauth_url, "http://127.0.0.1:${var.host_ports.gitea_http}")
  wp_host   = coalesce(var.wp_host, "http://127.0.0.1:${var.host_ports.wp_http}")

  pod_yaml = templatefile("${path.module}/platform-pod.yaml", {
    vault_backend_image = var.vault_backend_image
    source_dir          = var.source_dir
    p_kms               = var.host_ports.kms
    p_kms_cluster       = var.host_ports.kms_cluster
    p_vb                = var.host_ports.vb
    p_gitea_http        = var.host_ports.gitea_http
    p_gitea_ssh         = var.host_ports.gitea_ssh
    p_wp_http           = var.host_ports.wp_http
    p_wp_grpc           = var.host_ports.wp_grpc
  })
}

# ─── Write generated files ─────────────────────────────────────────────

resource "local_file" "configmap" {
  content  = local.configmap_yaml
  filename = "${var.bootstrap_dir}/configmap.yaml"
}

resource "local_file" "pod" {
  content  = local.pod_yaml
  filename = "${var.bootstrap_dir}/platform-pod.yaml"
}

# ─── Launch pod ────────────────────────────────────────────────────────

resource "terraform_data" "platform_pod" {
  depends_on = [local_file.configmap, local_file.pod]

  input = sha256(local.configmap_yaml)

  provisioner "local-exec" {
    command = <<-EOT
      podman pod rm -f platform 2>/dev/null || true
      podman play kube ${local_file.pod.filename} \
        --configmap=${local_file.configmap.filename} 2>&1 \
        | grep -v 'executable file.*not found' || true
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "podman pod rm -f platform 2>/dev/null || true"
  }
}

# ─── Outputs ───────────────────────────────────────────────────────────

output "admin_user" {
  value = var.admin_user
}

# ─── Admin Gitea (host-side) ────────────────────────────────────────────
# Sur la VM CI, envs/scaleway/ci/setup.sh.tpl cree l'admin via podman
# exec ; en flux LOCAL personne ne le faisait et le sidecar attendait
# l'utilisateur 300 s pour rien (constate au E2E local 2026-07-14).
# Idempotent : "already exists" tolere.
resource "terraform_data" "gitea_admin" {
  depends_on = [terraform_data.platform_pod]

  input = var.admin_user

  provisioner "local-exec" {
    environment = {
      GITEA_ADMIN_PASSWORD = var.admin_password
    }
    command = <<-EOT
      set -eu
      echo "[gitea-admin] waiting for the gitea container..."
      ready=0
      for i in $(seq 1 120); do
        if podman exec -u git platform-gitea gitea admin user list >/dev/null 2>&1; then
          ready=1; break
        fi
        sleep 2
      done
      [ "$ready" -eq 1 ] || { echo "[gitea-admin] ERROR: gitea not exec-able after 240s" >&2; exit 1; }
      if podman exec -u git platform-gitea gitea admin user list 2>/dev/null | grep -q " ${var.admin_user} "; then
        echo "[gitea-admin] user '${var.admin_user}' already exists"
      else
        podman exec -u git -e GITEA_ADMIN_PASSWORD platform-gitea sh -c \
          'gitea admin user create --username ${var.admin_user} --password "$GITEA_ADMIN_PASSWORD" --email ${var.admin_user}@local.invalid --admin --must-change-password=false'
        echo "[gitea-admin] user '${var.admin_user}' created"
      fi
    EOT
  }
}


output "admin_password" {
  value     = var.admin_password
  sensitive = true
}

output "status" {
  value = <<-EOT
    =========================================
      Platform starting
    =========================================
      Setup:    podman logs -f platform-tofu-setup
      OpenBao:  http://127.0.0.1:8200
      Gitea:    http://${var.domain}:${var.host_ports.gitea_http} (${var.admin_user})
      WP:       ${local.wp_host}
      State:    http://127.0.0.1:${var.host_ports.vb}
      KMS out:  podman volume inspect platform-kms-output
      Stop:     make bootstrap-stop
    =========================================
  EOT
}
