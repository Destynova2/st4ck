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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════
# Auto-generated secrets (stored in Terraform state, never on disk)
# ═══════════════════════════════════════════════════════════════════════

resource "random_id" "hydra_system_secret" {
  byte_length = 32
}

resource "random_id" "pomerium_shared_secret" {
  byte_length = 32
}

resource "random_id" "pomerium_cookie_secret" {
  byte_length = 32
}

resource "random_id" "pomerium_client_secret" {
  byte_length = 32
}

resource "random_id" "oidc_client_secret" {
  byte_length = 32
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

# ─── Ory Kratos (identity management) ─────────────────────────────

resource "helm_release" "kratos" {
  name             = "kratos"
  repository       = "https://k8s.ory.sh/helm/charts"
  chart            = "kratos"
  version          = var.kratos_version
  namespace        = "identity"
  create_namespace = false

  values = [file("${path.module}/../../../configs/kratos/values.yaml")]

  depends_on = [kubernetes_namespace.identity]
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

  values = [templatefile("${path.module}/../../../configs/hydra/values.yaml", {
    system_secret = random_id.hydra_system_secret.hex
  })]

  depends_on = [kubernetes_namespace.identity, kubectl_manifest.hydra_tls_cert]
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
            value = random_id.oidc_client_secret.hex
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

  lifecycle {
    replace_triggered_by = [random_id.oidc_client_secret]
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

  values = [templatefile("${path.module}/../../../configs/pomerium/values.yaml", {
    client_secret = random_id.pomerium_client_secret.hex
    shared_secret = random_id.pomerium_shared_secret.b64_std
    cookie_secret = random_id.pomerium_cookie_secret.b64_std
  })]

  depends_on = [kubernetes_namespace.identity, helm_release.hydra]
}
