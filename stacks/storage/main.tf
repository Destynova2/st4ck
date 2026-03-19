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
    address = "http://localhost:8080/state/pki"
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

# ─── Garage setup (split into 3 steps for reliability) ───────────────
# Uses kubectl exec + garage CLI (simpler than the admin API v2).

# Step 1: Wait for all 3 Garage pods to be Running
resource "terraform_data" "garage_wait" {
  depends_on = [helm_release.garage]

  provisioner "local-exec" {
    environment = { KUBECONFIG = var.kubeconfig_path }
    command = <<-EOT
      set -eu
      echo "Waiting for Garage pods..."
      for i in $(seq 1 60); do
        READY=$(kubectl -n garage get pods -l app.kubernetes.io/name=garage -o jsonpath='{.items[*].status.phase}' 2>/dev/null | tr ' ' '\n' | grep -c Running || echo 0)
        [ "$READY" -ge 3 ] && echo "All 3 Garage pods running." && exit 0
        echo "  $READY/3 running (attempt $i/60)..." && sleep 5
      done
      echo "ERROR: Garage pods not ready after 5 min" && exit 1
    EOT
  }
}

# Step 2: Configure layout (assign nodes + apply)
resource "terraform_data" "garage_layout" {
  depends_on = [terraform_data.garage_wait]

  provisioner "local-exec" {
    environment = { KUBECONFIG = var.kubeconfig_path }
    command = <<-EOT
      set -eu
      GARAGE="kubectl -n garage exec garage-0 -c garage --"

      # Wait for nodes to discover each other via RPC
      echo "Waiting for node discovery..."
      for i in $(seq 1 30); do
        COUNT=$($GARAGE ./garage status 2>/dev/null | grep -c "HEALTHY\|NO ROLE" || echo 0)
        [ "$COUNT" -ge 3 ] && break
        echo "  $COUNT/3 nodes (attempt $i/30)..." && sleep 5
      done

      NODES=$($GARAGE ./garage status 2>/dev/null | grep "NO ROLE" | awk '{print $1}')
      if [ -n "$NODES" ]; then
        echo "Assigning layout..."
        for NODE_ID in $NODES; do
          $GARAGE ./garage layout assign -z dc1 -c 5G "$NODE_ID" 2>&1 | tail -1
        done
        CURRENT_VER=$($GARAGE ./garage layout show 2>/dev/null | grep "layout version" | awk '{print $NF}' || echo 0)
        NEXT_VER=$((CURRENT_VER + 1))
        $GARAGE ./garage layout apply --version $NEXT_VER 2>&1 | tail -2
      else
        echo "Layout already configured."
      fi
    EOT
  }
}

# Step 3: Create buckets, API keys, and K8s secrets
resource "terraform_data" "garage_buckets_keys" {
  depends_on = [terraform_data.garage_layout, kubernetes_namespace.storage]

  provisioner "local-exec" {
    environment = { KUBECONFIG = var.kubeconfig_path }
    command = <<-EOT
      set -eu
      GARAGE="kubectl -n garage exec garage-0 -c garage --"

      echo "Waiting for Garage ready (post-layout)..."
      for i in $(seq 1 60); do
        READY=$(kubectl -n garage get pods -l app.kubernetes.io/name=garage -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c true || echo 0)
        [ "$READY" -ge 3 ] && echo "All 3 Garage pods ready." && break
        echo "  $READY/3 ready (attempt $i/60)..." && sleep 5
      done

      echo "Creating buckets..."
      for BUCKET in velero-backups harbor-registry; do
        $GARAGE ./garage bucket create "$BUCKET" 2>/dev/null || true
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

        KEY_INFO=$($GARAGE ./garage key create "$KEY_NAME" 2>/dev/null)
        ACCESS=$(echo "$KEY_INFO" | grep "Key ID" | awk '{print $NF}')
        SECRET=$(echo "$KEY_INFO" | grep "Secret key" | awk '{print $NF}')

        $GARAGE ./garage bucket allow --read --write --owner "$BUCKET" --key "$KEY_NAME"

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

  depends_on = [kubernetes_namespace.storage, terraform_data.garage_buckets_keys]
}

# ─── Harbor (container registry with Garage S3 backend) ──────────────

data "kubernetes_secret" "harbor_s3" {
  depends_on = [terraform_data.garage_buckets_keys]

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

  depends_on = [kubernetes_namespace.storage, terraform_data.garage_buckets_keys]
}
