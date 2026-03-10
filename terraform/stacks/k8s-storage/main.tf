terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════
# Auto-generated secrets (stored in Terraform state, never on disk)
# ═══════════════════════════════════════════════════════════════════════

resource "random_id" "garage_rpc_secret" {
  byte_length = 32
}

resource "random_id" "garage_admin_token" {
  byte_length = 32
}

provider "kubernetes" {
  host                   = var.kubernetes_host
  client_certificate     = base64decode(var.kubernetes_client_certificate)
  client_key             = base64decode(var.kubernetes_client_key)
  cluster_ca_certificate = base64decode(var.kubernetes_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = var.kubernetes_host
    client_certificate     = base64decode(var.kubernetes_client_certificate)
    client_key             = base64decode(var.kubernetes_client_key)
    cluster_ca_certificate = base64decode(var.kubernetes_ca_certificate)
  }
}

# ─── Kubernetes connection info (reusable for terraform_data.input) ──

locals {
  k8s_conn = {
    host = var.kubernetes_host
    ca   = var.kubernetes_ca_certificate
    cert = var.kubernetes_client_certificate
    key  = var.kubernetes_client_key
  }
}

# ─── Storage Namespace ───────────────────────────────────────────────

resource "kubernetes_namespace" "storage" {
  metadata {
    name = "storage"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# ─── local-path-provisioner (default StorageClass) ───────────────────

resource "helm_release" "local_path_provisioner" {
  name             = "local-path-provisioner"
  repository       = "https://charts.containeroo.ch"
  chart            = "local-path-provisioner"
  version          = var.local_path_provisioner_version
  namespace        = "storage"
  create_namespace = false

  values = [file("${path.module}/../../../configs/local-path-provisioner/values.yaml")]

  depends_on = [kubernetes_namespace.storage]
}

# ─── Garage (S3-compatible object store) ──────────────────────────────
# Lightweight Rust-based S3, uses local-path PVCs for persistence

resource "terraform_data" "garage" {
  depends_on = [helm_release.local_path_provisioner]

  input = local.k8s_conn

  triggers_replace = [
    filemd5("${path.module}/../../../configs/garage/garage.yaml"),
    random_id.garage_rpc_secret.hex,
    random_id.garage_admin_token.hex,
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      set -e
      CA=$(mktemp) && CERT=$(mktemp) && KEY=$(mktemp) && MANIFEST=$(mktemp)
      echo "$K8S_CA" | base64 -d > "$CA"
      echo "$K8S_CERT" | base64 -d > "$CERT"
      echo "$K8S_KEY" | base64 -d > "$KEY"
      echo "$GARAGE_MANIFEST" > "$MANIFEST"
      kubectl --server="$K8S_HOST" --certificate-authority="$CA" --client-certificate="$CERT" --client-key="$KEY" \
        apply -f "$MANIFEST"
      rm -f "$CA" "$CERT" "$KEY" "$MANIFEST"
    EOT
    environment = {
      K8S_HOST         = var.kubernetes_host
      K8S_CA           = var.kubernetes_ca_certificate
      K8S_CERT         = var.kubernetes_client_certificate
      K8S_KEY          = var.kubernetes_client_key
      GARAGE_MANIFEST  = templatefile("${path.module}/../../../configs/garage/garage.yaml", {
        garage_rpc_secret  = random_id.garage_rpc_secret.hex
        garage_admin_token = random_id.garage_admin_token.hex
      })
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      CA=$(mktemp) && CERT=$(mktemp) && KEY=$(mktemp)
      echo "${self.input.ca}" | base64 -d > "$CA"
      echo "${self.input.cert}" | base64 -d > "$CERT"
      echo "${self.input.key}" | base64 -d > "$KEY"
      KC="kubectl --server=${self.input.host} --certificate-authority=$CA --client-certificate=$CERT --client-key=$KEY"
      # Delete StatefulSet first (releases PVCs)
      $KC delete statefulset garage -n garage --ignore-not-found --timeout=60s || true
      # Wait for pods to terminate
      $KC wait --for=delete pod -l app=garage -n garage --timeout=60s 2>/dev/null || true
      # Delete PVCs
      $KC delete pvc -n garage --all --timeout=60s || true
      # Delete remaining resources (services, configmap)
      $KC delete svc garage garage-s3 -n garage --ignore-not-found || true
      $KC delete configmap garage-config -n garage --ignore-not-found || true
      # Delete namespace
      $KC delete namespace garage --ignore-not-found --timeout=120s || true
      rm -f "$CA" "$CERT" "$KEY"
    EOT
  }
}

# ─── Garage setup (layout, buckets, API keys, K8s secrets) ───────────
# Creates: velero-s3-credentials (storage)

resource "terraform_data" "garage_setup" {
  depends_on = [terraform_data.garage, kubernetes_namespace.storage]

  input = local.k8s_conn

  triggers_replace = [
    filemd5("${path.module}/../../../scripts/garage-setup.sh"),
    filemd5("${path.module}/../../../configs/garage/garage.yaml"),
  ]

  provisioner "local-exec" {
    command     = "bash ${path.module}/../../../scripts/garage-setup.sh"
    environment = {
      K8S_HOST           = var.kubernetes_host
      K8S_CA             = var.kubernetes_ca_certificate
      K8S_CERT           = var.kubernetes_client_certificate
      K8S_KEY            = var.kubernetes_client_key
      GARAGE_ADMIN_TOKEN = random_id.garage_admin_token.hex
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      CA=$(mktemp) && CERT=$(mktemp) && KEY=$(mktemp)
      echo "${self.input.ca}" | base64 -d > "$CA"
      echo "${self.input.cert}" | base64 -d > "$CERT"
      echo "${self.input.key}" | base64 -d > "$KEY"
      KC="kubectl --server=${self.input.host} --certificate-authority=$CA --client-certificate=$CERT --client-key=$KEY"
      $KC delete secret velero-s3-credentials -n storage --ignore-not-found || true
      rm -f "$CA" "$CERT" "$KEY"
    EOT
  }
}

# ─── Velero (backup & DR → Garage S3) ────────────────────────────────

resource "helm_release" "velero" {
  name             = "velero"
  repository       = "https://vmware-tanzu.github.io/helm-charts"
  chart            = "velero"
  version          = var.velero_version
  namespace        = "storage"
  create_namespace = false
  timeout          = 600

  values = [templatefile("${path.module}/../../../configs/velero/values.yaml", {
    velero_bucket = var.velero_bucket
    s3_url        = var.s3_url
  })]

  depends_on = [kubernetes_namespace.storage, terraform_data.garage_setup]
}

# ─── Harbor (container registry with Garage S3 backend) ──────────────

data "kubernetes_secret" "harbor_s3" {
  depends_on = [terraform_data.garage_setup]

  metadata {
    name      = "harbor-s3-credentials"
    namespace = "storage"
  }
}

resource "helm_release" "harbor" {
  name             = "harbor"
  repository       = "https://helm.goharbor.io"
  chart            = "harbor"
  version          = var.harbor_version
  namespace        = "storage"
  create_namespace = false
  timeout          = 600

  values = [
    file("${path.module}/../../../configs/harbor/values.yaml"),
    sensitive(yamlencode({
      harborAdminPassword = var.harbor_admin_password
      persistence = {
        imageChartStorage = {
          s3 = {
            accesskey = data.kubernetes_secret.harbor_s3.data["access_key"]
            secretkey = data.kubernetes_secret.harbor_s3.data["secret_key"]
          }
        }
      }
    })),
  ]

  depends_on = [kubernetes_namespace.storage, terraform_data.garage_setup]
}
