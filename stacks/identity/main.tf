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
    address = "http://localhost:8080/state/pki"
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
      bootstrap:
        initdb:
          database: identity
          owner: identity
  YAML

  depends_on = [helm_release.cnpg_operator]
}

data "kubernetes_secret" "pg_app" {
  metadata {
    name      = "identity-pg-app"
    namespace = "identity"
  }
  depends_on = [kubectl_manifest.identity_pg_cluster]
}

locals {
  # CNPG uses postgresql:// but Ory expects postgres://, and needs sslmode=disable for in-cluster
  pg_dsn = "${replace(data.kubernetes_secret.pg_app.data["uri"], "postgresql://", "postgres://")}?sslmode=disable"
}

# ─── Ory Kratos (identity management) ─────────────────────────────

resource "helm_release" "kratos" {
  name             = "kratos"
  repository       = "https://k8s.ory.sh/helm/charts"
  chart            = "kratos"
  version          = var.kratos_version
  namespace        = "identity"
  create_namespace = false

  values = [templatefile("${path.module}/values-kratos.yaml", {
    dsn = local.pg_dsn
  })]

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

  values = [templatefile("${path.module}/values-hydra.yaml", {
    system_secret = local.secrets["hydra_system_secret"]
    dsn           = local.pg_dsn
  })]

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

  values = [templatefile("${path.module}/values-pomerium.yaml", {
    client_secret = local.secrets["pomerium_client_secret"]
    shared_secret = local.secrets["pomerium_shared_secret"]
    cookie_secret = local.secrets["pomerium_cookie_secret"]
  })]

  depends_on = [kubernetes_namespace.identity, helm_release.hydra]
}
