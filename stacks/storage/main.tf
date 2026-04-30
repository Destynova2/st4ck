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
#
# Moved to stacks/cni/ (tofu-owned) on 2026-04-29 — chicken/egg with pki
# (Flux runs after pki, but pki needs StorageClass). See cni/main.tf.

# ─── Garage (S3-compatible object store) ──────────────────────────────

# Garage → tofu owner (postmortem 2026-04-29 #12). Reverted from the
# ADR-028 wave 2 Flux ownership: garage_wait + garage_layout +
# garage_buckets_keys terraform_data resources below depend on Garage
# pods existing, but Flux only runs AFTER flux-bootstrap (which is
# AFTER the storage stack). Same chicken/egg as local-path-provisioner
# (#4) and Cilium — provisioning steps that other stacks consume must
# happen during the same `tofu apply` that creates the dependency.
#
# Same pattern as helm_release.local_path_provisioner in stacks/cni/main.tf:
# install via tofu, mirror values from the same flux/values-garage.yaml
# (kept as the single source of truth via templatefile), let Flux take
# over for day-2 chart updates only if explicitly migrated later.
resource "kubernetes_namespace" "garage" {
  metadata {
    name = "garage"
    # PSA labels MUST mirror what stacks/storage/flux/namespace.yaml
    # declares (if it still applies the namespace on day-2). Postmortem
    # 2026-04-29 — drift caused garage pods to lose enforce: baseline
    # silently between Flux reconciles.
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

resource "helm_release" "garage" {
  name             = "garage"
  chart            = "${path.module}/chart"
  namespace        = kubernetes_namespace.garage.metadata[0].name
  create_namespace = false

  # Same values-garage.yaml file Flux used to consume via configMapGenerator,
  # rendered with the same secrets the garage-secrets ExternalSecret was
  # composing from OpenBao. Both substitutions land in the chart values
  # under garage.rpcSecret and the GARAGE_ADMIN_TOKEN env var.
  values = [
    templatefile("${path.module}/flux/values-garage.yaml", {
      garage_rpc_secret  = local.secrets["garage_rpc_secret"]
      garage_admin_token = local.secrets["garage_admin_token"]
    }),
  ]

  # Postmortem 2026-04-29 (#23, Phase C resume): Helm wait=true (default)
  # blocks for 5min waiting for pod Ready, but Garage pods stay NotReady
  # until layout is applied — which happens in terraform_data.garage_wait
  # below. Chicken/egg deadlock → helm release timeout. Garage_wait does
  # the proper readiness check via the Garage RPC port (`garage status`
  # lists all nodes that have joined the cluster, no auth required).
  wait = false

  depends_on = [kubernetes_namespace.garage]
}

# ─── Garage setup (split into 3 steps for reliability) ───────────────
# Uses kubectl exec + garage CLI (simpler than the admin API v2).

# Step 1: Wait for all 3 Garage nodes to register with each other (not Ready —
# Garage pods stay NotReady until the cluster layout is applied, which happens
# in step 2; so polling K8s readinessProbe is a deadlock. We poll the Garage
# RPC instead: `garage status` lists all nodes that have joined the cluster).
resource "terraform_data" "garage_wait" {
  depends_on = [helm_release.garage]

  provisioner "local-exec" {
    environment = { KUBECONFIG = var.kubeconfig_path }
    # Pattern 2 (Phase F-bis): fuse the 2 sequential waits (pods Running →
    # nodes registered RPC) into 1 parallel loop. Both conditions are
    # observable independently and typically converge within 30-60s. Polling
    # at 1s intervals (vs 5s) catches the transition ~5x faster.
    #
    # Pattern 1 (Phase F-bis): drop `|| echo 0` — Bug #18 in the postmortem
    # notes that `grep -c` always exits 1 when no match, AND emits "0\n0"
    # via the `||` fallback (count line + fallback line), giving wrong
    # arithmetic. Use `${VAR:-0}` at use site, with explicit timeout exit.
    command = <<-EOT
      set -eu
      echo "Waiting for 3 Garage pods Running AND 3 nodes registered (RPC)..."
      for i in $(seq 1 300); do
        RUNNING=$(kubectl -n garage get pods -l app.kubernetes.io/name=garage -o jsonpath='{.items[*].status.phase}' 2>/dev/null | tr ' ' '\n' | grep -c Running)
        # garage status only callable once garage-0 is Running; tolerate the
        # exec failure during the first ~10s by suppressing stderr.
        NODES=$(kubectl -n garage exec garage-0 -c garage -- ./garage status 2>/dev/null | grep -cE '^[a-f0-9]{16}')
        if [ "$${RUNNING:-0}" -ge 3 ] && [ "$${NODES:-0}" -ge 3 ]; then
          echo "All 3 Garage pods Running and 3 nodes registered."
          exit 0
        fi
        # Reduce log noise: print a heartbeat every 10s instead of every iteration
        if [ $((i % 10)) -eq 0 ]; then
          echo "  pods=$${RUNNING:-0}/3 nodes=$${NODES:-0}/3 (attempt $i/300)..."
        fi
        sleep 1
      done
      echo "ERROR: Garage not ready after 5 min (pods=$${RUNNING:-0}/3 nodes=$${NODES:-0}/3)"
      exit 1
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
    command     = <<-EOT
      set -eu
      GARAGE="kubectl -n garage exec garage-0 -c garage --"

      # Wait for nodes to discover each other via RPC.
      # Pattern 1 (Phase F-bis): sleep 1 vs 5, drop `|| echo 0`, explicit
      # timeout. After garage_wait succeeded, this loop usually converges
      # within ~5s; polling 1s catches it almost immediately.
      echo "Waiting for node discovery..."
      for i in $(seq 1 150); do
        COUNT=$($GARAGE ./garage status 2>/dev/null | grep -c "HEALTHY\|NO ROLE")
        [ "$${COUNT:-0}" -ge 3 ] && break
        if [ $((i % 10)) -eq 0 ]; then
          echo "  $${COUNT:-0}/3 nodes (attempt $i/150)..."
        fi
        sleep 1
      done
      [ "$${COUNT:-0}" -ge 3 ] || { echo "ERROR: node discovery timeout (got $${COUNT:-0}/3 after 150s)"; exit 1; }

      NODES=$($GARAGE ./garage status 2>/dev/null | grep "NO ROLE" | awk '{print $1}')
      if [ -n "$NODES" ]; then
        echo "Assigning layout..."
        for NODE_ID in $NODES; do
          $GARAGE ./garage layout assign -z dc1 -c 5G "$NODE_ID" 2>&1 | tail -1
        done
        CURRENT_VER=$($GARAGE ./garage layout show 2>/dev/null | grep "layout version" | awk '{print $NF}' || echo 0)
        # Postmortem 2026-04-29 (#18): the `|| echo 0` fallback only fires
        # when the WHOLE pipeline fails (grep+awk). awk happily emits an
        # empty string when grep matches no line (output format change
        # between Garage versions or parse failure), giving CURRENT_VER=""
        # → NEXT_VER=$((+1))=1. On a cluster already at version > 1
        # Garage rejects layout apply --version 1, the script aborts
        # mid-provisioner, and the cluster is left in an inconsistent
        # state. Surface the parse failure explicitly.
        if [ -z "$CURRENT_VER" ]; then
          echo "ERROR: could not parse 'layout version' from garage layout show output"
          echo "       check Garage version compatibility — output format may have changed"
          exit 1
        fi
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
    command     = <<-EOT
      set -eu
      GARAGE="kubectl -n garage exec garage-0 -c garage --"

      # Pattern 1 (Phase F-bis): sleep 1 vs 5, drop `|| echo 0`, explicit
      # timeout. After garage_layout, readinessProbe flips to ready in <10s.
      echo "Waiting for Garage ready (post-layout)..."
      for i in $(seq 1 300); do
        READY=$(kubectl -n garage get pods -l app.kubernetes.io/name=garage -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c true)
        if [ "$${READY:-0}" -ge 3 ]; then
          echo "All 3 Garage pods ready."
          break
        fi
        if [ $((i % 10)) -eq 0 ]; then
          echo "  $${READY:-0}/3 ready (attempt $i/300)..."
        fi
        sleep 1
      done
      [ "$${READY:-0}" -ge 3 ] || { echo "ERROR: Garage pods not ready after 5 min (got $${READY:-0}/3)"; exit 1; }

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

        # ─── Ensure target namespace exists ─────────────────────────────
        # Some entries write into namespaces owned by OTHER stacks
        # (cnpg-s3-credentials -> identity ns, owned by stacks/identity).
        # The storage stack's depends_on only references storage's own
        # resources, so a fresh rebuild or isolated `tofu apply` of just
        # the storage stack reaches this loop before the identity stack
        # has created its namespace, and `kubectl create secret -n
        # identity` exits non-zero (`set -eu` aborts the whole script,
        # leaving the Garage keys in an inconsistent state).
        #
        # We don't add a tofu-level cross-stack data.kubernetes_namespace
        # dependency because that would FAIL plan when the namespace
        # doesn't yet exist, deadlocking the storage <-> identity stack
        # ordering. An idempotent `kubectl create namespace` is the
        # right level — namespaces are cheap, the identity stack will
        # later adopt it (server-side-apply doesn't conflict on an
        # already-existing namespace with no labels).
        if ! kubectl get ns "$SECRET_NS" >/dev/null 2>&1; then
          echo "  Namespace $SECRET_NS missing — creating (will be adopted by its owning stack later)."
          kubectl create namespace "$SECRET_NS"
        fi

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
