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
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
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
    hydra_system_secret    = data.terraform_remote_state.pki.outputs.hydra_system_secret
    pomerium_shared_secret = data.terraform_remote_state.pki.outputs.pomerium_shared_secret
    pomerium_cookie_secret = data.terraform_remote_state.pki.outputs.pomerium_cookie_secret
    pomerium_client_secret = data.terraform_remote_state.pki.outputs.pomerium_client_secret
    oidc_client_secret     = data.terraform_remote_state.pki.outputs.oidc_client_secret
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

provider "kubectl" {
  config_path      = var.kubeconfig_path
  load_config_file = true
}

# ─── Identity Namespace ────────────────────────────────────────────

resource "kubernetes_namespace" "identity" {
  metadata {
    name = "identity"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

# ─── CloudNativePG Operator ──────────────────────────────────────

resource "helm_release" "cnpg_operator" {
  name             = "cnpg"
  repository       = "https://cloudnative-pg.github.io/charts"
  chart            = "cloudnative-pg"
  version          = var.cnpg_version
  namespace        = "identity"
  create_namespace = false

  depends_on = [kubernetes_namespace.identity]
}

# ─── CNPG external certificates (Phase 1b-3) ───────────────────────
#
# Apply 4 Certificate CRs (server-ca, server, client-ca, replication)
# BEFORE the Cluster CR so cert-manager has time to materialize the
# Secrets. Without this ordering, CNPG would observe missing Secrets,
# log a confused error and fall back to its self-managed PKI for the
# initial bootstrap (then never switch).
data "kubectl_file_documents" "identity_pg_certs" {
  content = file("${path.module}/flux/identity-pg-certs.yaml")
}

resource "kubectl_manifest" "identity_pg_certs" {
  for_each = data.kubectl_file_documents.identity_pg_certs.manifests

  yaml_body = each.value

  depends_on = [kubernetes_namespace.identity]
}

# ─── PostgreSQL Cluster (CNPG CRD) ──────────────────────────────

resource "kubectl_manifest" "identity_pg_cluster" {
  yaml_body = <<-YAML
    apiVersion: postgresql.cnpg.io/v1
    kind: Cluster
    metadata:
      name: identity-pg
      namespace: identity
    spec:
      instances: 3
      storage:
        size: 2Gi
      # WAL archive against Garage S3 — barman-cloud uses boto3 which
      # defaults region_name to "us-east-1" when only AWS_REGION is set
      # (it reads AWS_DEFAULT_REGION first). Garage signs requests with
      # the bucket's actual region ("garage") and rejects sigv4 with
      # 400 Bad Request on HeadBucket if regions don't match. Setting
      # both env vars forces boto3 to use "garage" everywhere.
      # Postmortem 2026-04-28.
      env:
        - name: AWS_REGION
          value: "garage"
        - name: AWS_DEFAULT_REGION
          value: "garage"
      # Phase 1b-3: external certs from cert-manager (OpenBao PKI).
      # Replaces CNPG's self-managed PKI so every cert is auditable in
      # the OpenBao audit log. Replication CN MUST be streaming_replica
      # (enforced by the Certificate CR identity-pg-replication).
      certificates:
        serverCASecret: identity-pg-server-ca-tls
        serverTLSSecret: identity-pg-server-tls
        clientCASecret: identity-pg-client-ca-tls
        replicationTLSSecret: identity-pg-replication-tls
      bootstrap:
        initdb:
          database: identity
          owner: identity
          # Schema-per-app isolation: kratos.* and hydra.* live in dedicated
          # schemas instead of public.*. Recovery from a partial migration
          # is now scoped to the affected app — DROP SCHEMA kratos CASCADE
          # cleans Kratos without touching Hydra. See runbook W1.
          postInitApplicationSQL:
            - CREATE SCHEMA IF NOT EXISTS kratos AUTHORIZATION identity;
            - CREATE SCHEMA IF NOT EXISTS hydra AUTHORIZATION identity;
            - GRANT ALL ON SCHEMA kratos TO identity;
            - GRANT ALL ON SCHEMA hydra TO identity;
      backup:
        barmanObjectStore:
          destinationPath: "s3://cnpg-backups/identity-pg"
          endpointURL: "http://garage.garage.svc.cluster.local:3900"
          s3Credentials:
            accessKeyId:
              name: cnpg-s3-credentials
              key: access_key
            secretAccessKey:
              name: cnpg-s3-credentials
              key: secret_key
        retentionPolicy: "14d"
  YAML

  depends_on = [
    helm_release.cnpg_operator,
    # All 4 cert Secrets must exist before CNPG inspects spec.certificates
    # — otherwise CNPG falls back to self-PKI and never recovers.
    kubectl_manifest.identity_pg_certs,
  ]
}

# ─── CNPG ScheduledBackup (daily at 02:00 UTC) ──────────────────

resource "kubectl_manifest" "identity_pg_scheduled_backup" {
  yaml_body = <<-YAML
    apiVersion: postgresql.cnpg.io/v1
    kind: ScheduledBackup
    metadata:
      name: identity-pg-daily
      namespace: identity
    spec:
      schedule: "0 2 * * *"
      backupOwnerReference: self
      cluster:
        name: identity-pg
      method: barmanObjectStore
      immediate: true
  YAML

  depends_on = [kubectl_manifest.identity_pg_cluster]
}

# DSN composition formerly happened here (data.kubernetes_secret.pg_app +
# locals { pg_dsn_kratos / pg_dsn_hydra }). Now lives in ESO ExternalSecret
# templates (stacks/identity/flux/external-secrets.yaml) — single source of
# truth, rotates with the CNPG password without re-applying tofu.

# Kratos → Flux owner (helmrelease-kratos.yaml + values-kratos.yaml ConfigMap +
# kratos-secrets ExternalSecret which provides the DSN via ESO templating).
# ADR-028 — no double-apply.

# ─── Hydra TLS certificate (for apiServer OIDC) ───────────────────
# Requires: ClusterIssuer "internal-ca" from k8s-pki stack

resource "kubectl_manifest" "hydra_tls_cert" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: hydra-tls
      namespace: identity
    spec:
      secretName: hydra-tls
      issuerRef:
        name: internal-ca
        kind: ClusterIssuer
      # PKI role pki_int/cluster-issuer requires CN (require_cn defaults true).
      commonName: hydra-public.identity.svc.cluster.local
      dnsNames:
        - hydra-public
        - hydra-public.identity
        - hydra-public.identity.svc
        - hydra-public.identity.svc.cluster.local
      # ECDSA matches the OpenBao pki_int/roles/cluster-issuer key_type=ec
      # constraint (see stacks/pki/secrets.tf). Default cert-manager
      # algorithm is RSA-2048 → role rejects with "requires keys of type ec".
      privateKey:
        algorithm: ECDSA
        size: 256
  YAML

  depends_on = [kubernetes_namespace.identity]
}

# Hydra → Flux owner (helmrelease-hydra.yaml + values-hydra.yaml ConfigMap +
# hydra-secrets ExternalSecret providing DSN and system_secret via ESO).
# ADR-028 — no double-apply.

# ─── OIDC client registration (kubernetes → Hydra) ────────────────

resource "kubernetes_job_v1" "hydra_oidc_client" {
  metadata {
    name      = "hydra-oidc-register"
    namespace = "identity"
  }

  spec {
    template {
      metadata {
        labels = {
          app = "hydra-setup"
        }
      }
      spec {
        container {
          name    = "register"
          image   = "curlimages/curl:8.12.1"
          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            # Pattern 1 (Phase F-bis): sleep 1 vs 5, max 300 iterations
            # (5min). Hydra admin endpoint typically becomes ready within
            # 10-20s after the pod starts; polling 1s vs 5s catches the
            # transition ~5x faster. Add explicit timeout exit (was
            # implicit fall-through before, with the next curl POST then
            # failing on connection refused with a confusing error).
            echo "Waiting for Hydra admin..."
            READY=0
            for i in $(seq 1 300); do
              if curl -sf http://hydra-admin.identity.svc:4445/health/ready >/dev/null 2>&1; then
                READY=1
                break
              fi
              if [ $((i % 10)) -eq 0 ]; then
                echo "  attempt $i/300..."
              fi
              sleep 1
            done
            if [ "$READY" -ne 1 ]; then
              echo "ERROR: Hydra admin not ready after 5 min"
              exit 1
            fi
            echo "Registering kubernetes OIDC client..."
            # Postmortem 2026-04-29 (#19): curl -sf || true swallowed
            # every 4xx/5xx, not just 409-Conflict (idempotent re-run).
            # Bad client_secret format or Hydra startup failure surfaced
            # only at user login attempt. Capture HTTP status code
            # explicitly: 201 = created, 409 = already registered (both
            # OK), anything else = exit 1 with response body for triage.
            HTTP_CODE=$(curl -s -o /tmp/hydra-resp.txt -w "%%{http_code}" \
              -X POST http://hydra-admin.identity.svc:4445/admin/clients \
              -H 'Content-Type: application/json' \
              -d "{
                \"client_id\": \"kubernetes\",
                \"client_secret\": \"$OIDC_CLIENT_SECRET\",
                \"grant_types\": [\"authorization_code\", \"refresh_token\"],
                \"response_types\": [\"code\"],
                \"scope\": \"openid email profile\",
                \"redirect_uris\": [\"http://localhost:8000\", \"http://localhost:18000\"],
                \"token_endpoint_auth_method\": \"client_secret_basic\"
              }")
            case "$HTTP_CODE" in
              201) echo "  OIDC client created" ;;
              409) echo "  OIDC client already registered (409 — idempotent)" ;;
              *)
                echo "ERROR: Hydra returned HTTP $HTTP_CODE"
                cat /tmp/hydra-resp.txt
                exit 1
                ;;
            esac
            echo "Done."
          EOT
          ]

          env {
            name  = "OIDC_CLIENT_SECRET"
            value = local.secrets["oidc_client_secret"]
          }
        }

        restart_policy = "Never"
      }
    }

    backoff_limit = 3
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
  }

  # Hydra now Flux-owned; this Job waits for the admin endpoint via curl
  # retry loop, so depends_on becomes namespace-only.
  depends_on = [kubernetes_namespace.identity]
}

# Pomerium → Flux owner (ADR-028 wave 2). The 3 secrets (client/shared/
# cookie) come from the pomerium-secrets ExternalSecret which renders a
# values.yaml fragment that overrides the ${...} placeholders left in
# the ConfigMap-loaded values-pomerium.yaml. ESO is the single source.
