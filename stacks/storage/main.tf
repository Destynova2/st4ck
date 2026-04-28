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
    address  = var.pki_state_address
    username = var.pki_state_username
    password = var.pki_state_password
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

# local-path-provisioner → Flux owner (helmrelease-local-path.yaml). ADR-028.

# ─── Garage (S3-compatible object store) ──────────────────────────────

# Garage → Flux owner (ADR-028 wave 2). garage-secrets ExternalSecret
# in stacks/storage/flux/external-secrets.yaml renders the
# rpcSecret + admin.token values.yaml fragment from OpenBao
# secret/storage/garage. Flux HelmRelease consumes ConfigMap +
# Secret via valuesFrom (Secret wins on overlap).
#
# garage_layout + garage_buckets_keys terraform_data below previously
# used `triggers_replace = [sha256(file("${path.module}/flux/values-garage.yaml"))]`
# to re-run on chart upgrade. After the Flux handoff, that field is
# unreachable; we trigger on the values file hash instead, which
# changes on any chart-relevant config change.
resource "kubernetes_namespace" "garage" {
  metadata {
    name = "garage"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

# ─── Garage setup (split into 3 steps for reliability) ───────────────
# Uses kubectl exec + garage CLI (simpler than the admin API v2).

# Step 1: Wait for all 3 Garage nodes to register with each other (not Ready —
# Garage pods stay NotReady until the cluster layout is applied, which happens
# in step 2; so polling K8s readinessProbe is a deadlock. We poll the Garage
# RPC instead: `garage status` lists all nodes that have joined the cluster).
resource "terraform_data" "garage_wait" {
  depends_on = [kubernetes_namespace.garage]

  provisioner "local-exec" {
    environment = { KUBECONFIG = var.kubeconfig_path }
    command = <<-EOT
      set -eu
      echo "Waiting for all Garage pods to be in Running phase..."
      for i in $(seq 1 60); do
        RUNNING=$(kubectl -n garage get pods -l app.kubernetes.io/name=garage -o jsonpath='{.items[*].status.phase}' 2>/dev/null | tr ' ' '\n' | grep -c Running || echo 0)
        [ "$RUNNING" -ge 3 ] && break
        echo "  $RUNNING/3 running (attempt $i/60)..." && sleep 5
      done
      echo "Waiting for all 3 Garage nodes to register in the cluster (RPC)..."
      for i in $(seq 1 60); do
        NODES=$(kubectl -n garage exec garage-0 -c garage -- ./garage status 2>/dev/null | grep -cE '^[a-f0-9]{16}' || echo 0)
        [ "$NODES" -ge 3 ] && echo "All 3 Garage nodes registered." && exit 0
        echo "  $NODES/3 nodes registered (attempt $i/60)..." && sleep 5
      done
      echo "ERROR: Garage nodes not registered after 5 min" && exit 1
    EOT
  }
}

# Step 2: Configure layout (assign nodes + apply)
resource "terraform_data" "garage_layout" {
  depends_on = [terraform_data.garage_wait]

  # Re-run if Garage helm release changes
  triggers_replace = [sha256(file("${path.module}/flux/values-garage.yaml"))]

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

  # Re-run on helm revision change; scripts are idempotent (check before create)
  triggers_replace = [sha256(file("${path.module}/flux/values-garage.yaml"))]

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
      for BUCKET in velero-backups harbor-registry cnpg-backups; do
        $GARAGE ./garage bucket create "$BUCKET" 2>/dev/null || true
      done

      echo "Creating keys and K8s secrets..."
      for ENTRY in "velero-key:velero-backups:storage:velero-s3-credentials:ini" \
                    "harbor-key:harbor-registry:storage:harbor-s3-credentials:plain" \
                    "cnpg-key:cnpg-backups:identity:cnpg-s3-credentials:plain"; do
        KEY_NAME=$(echo "$ENTRY" | cut -d: -f1)
        BUCKET=$(echo "$ENTRY" | cut -d: -f2)
        SECRET_NS=$(echo "$ENTRY" | cut -d: -f3)
        SECRET_NAME=$(echo "$ENTRY" | cut -d: -f4)
        SECRET_FMT=$(echo "$ENTRY" | cut -d: -f5)

        if kubectl -n "$SECRET_NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
          echo "  Secret $SECRET_NAME exists, skipping."
          continue
        fi

        KEY_INFO=$($GARAGE ./garage key info "$KEY_NAME" 2>/dev/null || $GARAGE ./garage key create "$KEY_NAME" 2>/dev/null)
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

# velero → Flux owner (helmrelease-velero.yaml + values-velero.yaml with
# ${s3_url} + ${velero_bucket} substituted via Flux postBuild — defined
# in stacks/flux-bootstrap/main.tf Kustomization "management"). ADR-028.

# Harbor → Flux owner (ADR-028 wave 3).
# Three secrets enter Harbor at runtime, all via the harbor-secrets
# ExternalSecret which renders a values.yaml fragment from OpenBao:
#   - harborAdminPassword     ← seeded by tofu pki at secret/storage/harbor
#   - persistence.imageChartStorage.s3.accesskey
#   - persistence.imageChartStorage.s3.secretkey
#       ↑ both mirrored from harbor-s3-credentials K8s Secret to OpenBao
#       at secret/storage/harbor-s3 by the harbor-s3-mirror PushSecret
#       (see stacks/storage/flux/external-secrets.yaml).
# garage_buckets_keys terraform_data still creates harbor-s3-credentials
# (Garage CLI generates the API key); the PushSecret mirrors it.
