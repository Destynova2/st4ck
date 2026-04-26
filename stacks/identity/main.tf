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
          endpointURL: "http://garage-s3.garage.svc.cluster.local:3900"
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

data "kubernetes_secret" "pg_app" {
  metadata {
    name      = "identity-pg-app"
    namespace = "identity"
  }
  depends_on = [kubectl_manifest.identity_pg_cluster]
}

locals {
  # CNPG uses postgresql:// but Ory expects postgres://, and needs sslmode=disable for in-cluster.
  # Schema-per-app: each Helm release gets its own search_path so Kratos lives
  # in `kratos.*`, Hydra in `hydra.*`. A failed Kratos migration can be cleaned
  # by `DROP SCHEMA kratos CASCADE` without affecting Hydra (and vice-versa).
  # Schemas are pre-created by CNPG postInitApplicationSQL above.
  pg_dsn_base = "${replace(data.kubernetes_secret.pg_app.data["uri"], "postgresql://", "postgres://")}?sslmode=disable"
  pg_dsn_kratos = "${local.pg_dsn_base}&search_path=kratos"
  pg_dsn_hydra  = "${local.pg_dsn_base}&search_path=hydra"
}

# ─── Ory Kratos (identity management) ─────────────────────────────

resource "helm_release" "kratos" {
  name             = "kratos"
  repository       = "https://k8s.ory.sh/helm/charts"
  chart            = "kratos"
  version          = var.kratos_version
  namespace        = "identity"
  create_namespace = false

  # Two-source values: the static file (no ${dsn} placeholder anymore —
  # Flux uses ESO templating to inject DSN) + an inline yamlencode that
  # adds the DSN computed by tofu. Both modes (tofu day-1, Flux day-2)
  # converge on the same chart values.
  values = [
    file("${path.module}/flux/values-kratos.yaml"),
    yamlencode({
      kratos = {
        config = {
          dsn = local.pg_dsn_kratos
        }
      }
    }),
  ]

  depends_on = [kubernetes_namespace.identity, kubectl_manifest.identity_pg_cluster]
}

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
      dnsNames:
        - hydra-public
        - hydra-public.identity
        - hydra-public.identity.svc
        - hydra-public.identity.svc.cluster.local
  YAML

  depends_on = [kubernetes_namespace.identity]
}

# ─── Ory Hydra (OAuth2 / OIDC) ────────────────────────────────────

resource "helm_release" "hydra" {
  name             = "hydra"
  repository       = "https://k8s.ory.sh/helm/charts"
  chart            = "hydra"
  version          = var.hydra_version
  namespace        = "identity"
  create_namespace = false

  # Two-source values: static file (no ${dsn} or ${system_secret}
  # placeholders anymore — Flux uses ESO templating; tofu adds them via
  # the inline yamlencode below). Both modes converge on the same chart
  # values without duplication.
  values = [
    file("${path.module}/flux/values-hydra.yaml"),
    yamlencode({
      hydra = {
        config = {
          dsn = local.pg_dsn_hydra
          secrets = {
            system = [local.secrets["hydra_system_secret"]]
          }
        }
      }
    }),
  ]

  depends_on = [kubernetes_namespace.identity, kubectl_manifest.hydra_tls_cert, kubectl_manifest.identity_pg_cluster]
}

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
          name  = "register"
          image = "curlimages/curl:8.12.1"
          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            echo "Waiting for Hydra admin..."
            for i in $(seq 1 60); do
              curl -sf http://hydra-admin.identity.svc:4445/health/ready && break
              echo "  attempt $i/60..."
              sleep 5
            done
            echo "Registering kubernetes OIDC client..."
            curl -sf -X POST http://hydra-admin.identity.svc:4445/admin/clients \
              -H 'Content-Type: application/json' \
              -d "{
                \"client_id\": \"kubernetes\",
                \"client_secret\": \"$OIDC_CLIENT_SECRET\",
                \"grant_types\": [\"authorization_code\", \"refresh_token\"],
                \"response_types\": [\"code\"],
                \"scope\": \"openid email profile\",
                \"redirect_uris\": [\"http://localhost:8000\", \"http://localhost:18000\"],
                \"token_endpoint_auth_method\": \"client_secret_basic\"
              }" || true
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

  depends_on = [helm_release.hydra]
}

# ─── Pomerium (zero-trust access proxy) ───────────────────────────

resource "helm_release" "pomerium" {
  name             = "pomerium"
  repository       = "https://helm.pomerium.io"
  chart            = "pomerium"
  version          = var.pomerium_version
  namespace        = "identity"
  create_namespace = false

  values = [templatefile("${path.module}/flux/values-pomerium.yaml", {
    client_secret = local.secrets["pomerium_client_secret"]
    shared_secret = local.secrets["pomerium_shared_secret"]
    cookie_secret = local.secrets["pomerium_cookie_secret"]
  })]

  depends_on = [kubernetes_namespace.identity, helm_release.hydra]
}
