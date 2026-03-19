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
  }
}

# ═══════════════════════════════════════════════════════════════════════
# Secrets from k8s-pki stack (generated + seeded into OpenBao Infra)
# ═══════════════════════════════════════════════════════════════════════

data "terraform_remote_state" "pki" {
  backend = "http"
  config = {
    address  = "http://localhost:8080/state/pki"
    username = "TOKEN"
  }
}

locals {
  secrets = {
    garage_rpc_secret     = data.terraform_remote_state.pki.outputs.garage_rpc_secret
    garage_admin_token    = data.terraform_remote_state.pki.outputs.garage_admin_token
    harbor_admin_password = data.terraform_remote_state.pki.outputs.harbor_admin_password
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
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

  values = [file("${path.module}/values-local-path.yaml")]

  depends_on = [kubernetes_namespace.storage]
}

# ─── Garage (S3-compatible object store) ──────────────────────────────

resource "helm_release" "garage" {
  name             = "garage"
  chart            = "${path.module}/chart"
  namespace        = "garage"
  create_namespace = true
  wait             = false # Garage returns 503 until layout is configured

  values = [templatefile("${path.module}/values-garage.yaml", {
    garage_rpc_secret  = local.secrets["garage_rpc_secret"]
    garage_admin_token = local.secrets["garage_admin_token"]
  })]

  depends_on = [helm_release.local_path_provisioner]
}

# ─── Garage setup (layout, buckets, API keys, K8s secrets) ───────────
# Uses kubectl exec + garage CLI (simpler than the admin API v2).

resource "terraform_data" "garage_setup" {
  depends_on = [helm_release.garage, kubernetes_namespace.storage]

  input = local.secrets["garage_admin_token"]

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = var.kubeconfig_path
    }
    command = <<-EOT
      set -eu

      echo "Waiting for Garage pods..."
      for i in $(seq 1 60); do
        kubectl -n garage get pod garage-0 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running && break
        echo "  attempt $i/60..." && sleep 5
      done

      echo "Configuring layout..."
      NODES=$(kubectl -n garage exec garage-0 -c garage -- ./garage status 2>/dev/null | grep "NO ROLE" | awk '{print $1}')
      if [ -n "$NODES" ]; then
        for NODE_ID in $NODES; do
          kubectl -n garage exec garage-0 -c garage -- ./garage layout assign -z dc1 -c 5G "$NODE_ID"
        done
        NEXT_VER=$(kubectl -n garage exec garage-0 -c garage -- ./garage layout show 2>/dev/null | grep -oP 'version \K\d+' || echo "1")
        kubectl -n garage exec garage-0 -c garage -- ./garage layout apply --version "$${NEXT_VER:-1}"
      else
        echo "Layout already configured."
      fi

      echo "Waiting for Garage ready..."
      for i in $(seq 1 30); do
        kubectl -n garage exec garage-0 -c garage -- ./garage status 2>/dev/null | grep -q "HEALTHY" && break
        sleep 5
      done

      echo "Creating buckets..."
      for BUCKET in velero-backups harbor-registry; do
        kubectl -n garage exec garage-0 -c garage -- ./garage bucket create "$BUCKET" 2>/dev/null || true
      done

      echo "Creating keys and K8s secrets..."
      for ENTRY in "velero-key:velero-backups:storage:velero-s3-credentials:ini" \
                    "harbor-key:harbor-registry:storage:harbor-s3-credentials:plain"; do
        KEY_NAME=$(echo "$ENTRY" | cut -d: -f1)
        BUCKET=$(echo "$ENTRY" | cut -d: -f2)
        SECRET_NS=$(echo "$ENTRY" | cut -d: -f3)
        SECRET_NAME=$(echo "$ENTRY" | cut -d: -f4)
        SECRET_FMT=$(echo "$ENTRY" | cut -d: -f5)

        if kubectl -n "$SECRET_NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
          echo "  Secret $SECRET_NAME exists, skipping."
          continue
        fi

        KEY_INFO=$(kubectl -n garage exec garage-0 -c garage -- ./garage key create "$KEY_NAME" 2>/dev/null)
        ACCESS=$(echo "$KEY_INFO" | grep "Key ID" | awk '{print $NF}')
        SECRET=$(echo "$KEY_INFO" | grep "Secret key" | awk '{print $NF}')

        kubectl -n garage exec garage-0 -c garage -- ./garage bucket allow --read --write --owner "$BUCKET" --key "$KEY_NAME"

        if [ "$SECRET_FMT" = "ini" ]; then
          kubectl -n "$SECRET_NS" create secret generic "$SECRET_NAME" \
            --from-literal=cloud="$(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$ACCESS" "$SECRET")"
        else
          kubectl -n "$SECRET_NS" create secret generic "$SECRET_NAME" \
            --from-literal=access_key="$ACCESS" --from-literal=secret_key="$SECRET"
        fi
        echo "  Key $KEY_NAME → secret $SECRET_NAME created."
      done

      echo "Garage setup complete."
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

  values = [templatefile("${path.module}/values-velero.yaml", {
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
    file("${path.module}/values-harbor.yaml"),
    sensitive(yamlencode({
      harborAdminPassword = local.secrets["harbor_admin_password"]
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
