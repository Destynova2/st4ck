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

variable "gitea_url" {
  description = "Gitea external URL (used by WP OAuth callback)"
  type        = string
  default     = "http://host.containers.internal:3000"
}

variable "oauth_url" {
  description = "OAuth URL (browser-accessible Gitea URL)"
  type        = string
  default     = "http://127.0.0.1:3000"
}

variable "domain" {
  description = "Domain for Gitea server"
  type        = string
  default     = "127.0.0.1"
}

variable "wp_host" {
  description = "Woodpecker external URL"
  type        = string
  default     = "http://127.0.0.1:8000"
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
      CI_GITEA_URL: "${var.gitea_url}"
      CI_OAUTH_URL: "${var.oauth_url}"
      CI_DOMAIN: "${var.domain}"
      CI_WP_HOST: "${var.wp_host}"
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

  pod_yaml = replace(
    replace(
      file("${path.module}/platform-pod.yaml"),
      "__VAULT_BACKEND_IMAGE__",
      var.vault_backend_image
    ),
    "__SOURCE_DIR__",
    var.source_dir
  )
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
      Gitea:    http://${var.domain}:3000 (${var.admin_user})
      WP:       ${var.wp_host}
      State:    http://127.0.0.1:8080
      KMS out:  podman volume inspect platform-kms-output
      Stop:     make bootstrap-stop
    =========================================
  EOT
}
