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
    # alekc/kubectl applies manifests lazily (no plan-time CRD validation).
    # Required for VMRule etc. that depend on CRDs installed by helm_release
    # in the same apply — vanilla kubernetes_manifest fails at plan time when
    # the CRD doesn't exist yet.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
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
  config_path = var.kubeconfig_path
}

# ─── Monitoring Namespace ────────────────────────────────────────────────

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# ─── Grafana admin credentials (seeded into OpenBao Infra) ───────────────
# Generated here so that ESO (day-2) becomes the authoritative source for
# the `grafana-admin` K8s Secret. The Grafana sub-chart is configured
# (values-vm-stack.yaml: grafana.admin.existingSecret) to consume that
# secret instead of generating its own random password — which previously
# rotated on every Helm re-install and invalidated all sessions.
#
# IDEMPOTENCY: lifecycle.ignore_changes=all keeps the password stable
# across state-loss + re-apply (mirrors the postmortem fix applied to
# stacks/pki/secrets.tf — see the comment block there).
resource "random_password" "grafana_admin" {
  length  = 24
  special = false

  lifecycle {
    ignore_changes = all
  }
}

# NOTE: Helm releases for monitoring (vm-k8s-stack, victoria-logs,
# victoria-logs-collector, headlamp) are owned by Flux — see
# stacks/monitoring/flux/helmrelease-*.yaml. Tofu only manages the
# bootstrap pieces below (namespace, grafana-admin Secret pre-seeded
# so the chart can mount it on first apply, OpenBao seed, dashboard
# ConfigMap, VMRule for Flux alerts).
#
# ADR-028 — Flux is owner par défaut for app-level helm releases;
# tofu only manages what must exist BEFORE Flux can reconcile.

# ─── Bootstrap K8s Secret for chart consumption (pre-Flux/ESO) ───────────
# The Grafana sub-chart requires `grafana-admin` to exist BEFORE the
# Deployment can start (mounts envFrom). On initial tofu apply, ESO is not
# yet reconciling, so we create the Secret here. Once Flux rolls out, the
# ExternalSecret in flux/external-secret-grafana.yaml takes ownership and
# refreshes the values from OpenBao every refreshInterval. Because OpenBao
# was seeded from the same random_password.grafana_admin (see
# terraform_data.seed_grafana_to_openbao below), the data is identical and
# ESO's first reconciliation is a no-op — no rotation, no session loss.
resource "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = "monitoring"
    # Hint to ESO that it's allowed to take this Secret over even though
    # it wasn't the original creator (ESO honours this since v0.9).
    annotations = {
      "external-secrets.io/force-sync" = "true"
    }
  }

  type = "Opaque"

  data = {
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin.result
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# ─── Seed Grafana admin credentials into in-cluster OpenBao Infra ────────
# Mirrors the bash pattern in stacks/pki/secrets.tf. We keep this in the
# monitoring stack (rather than extending pki/secrets.tf) because:
#  • monitoring is deployed AFTER pki (so OpenBao Infra is already up);
#  • cross-stack remote_state coupling stays one-directional (monitoring
#    → pki, never pki → monitoring), avoiding circular reads.
#
# Reads the OpenBao admin password directly from the K8s Secret created
# by stacks/pki (`openbao-admin-password` in `secrets` ns) — same approach
# the seed in pki/secrets.tf uses, just without the local-only reference.
resource "terraform_data" "seed_grafana_to_openbao" {
  # Triggers re-run if the password changes (which, with ignore_changes=all,
  # only happens on a deliberate `tofu state rm` rotation).
  input = sha256(random_password.grafana_admin.result)

  provisioner "local-exec" {
    environment = {
      KUBECONFIG             = var.kubeconfig_path
      GRAFANA_ADMIN_PASSWORD = random_password.grafana_admin.result
    }
    command = <<-EOT
      set -eu

      # OpenBao listener is HTTPS (cert-manager cert via openbao-infra-tls).
      # BAO_SKIP_VERIFY because we hit 127.0.0.1 from inside the pod —
      # the cert is for the cluster-internal DNS name, not the loopback.
      BAO="kubectl -n secrets exec openbao-infra-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true"

      # Resolve the OpenBao admin password from the K8s Secret seeded by
      # stacks/pki/main.tf:kubernetes_secret.openbao_admin_password.
      BAO_ADMIN_PASSWORD=$(kubectl -n secrets get secret openbao-admin-password \
        -o jsonpath='{.data.password}' | base64 -d)

      echo "Waiting for OpenBao Infra API..."
      for i in $(seq 1 60); do
        $BAO bao status >/dev/null 2>&1 && break
        echo "  attempt $i/60..." && sleep 5
      done

      echo "Logging in..."
      $BAO bao login -method=userpass username=admin password="$BAO_ADMIN_PASSWORD" >/dev/null 2>&1 || \
        { echo "ERROR: OpenBao login failed"; exit 1; }

      # Idempotent re-run: skip when the same key+value already present.
      EXISTING=$($BAO bao kv get -field=admin-password secret/monitoring/grafana 2>/dev/null || true)
      if [ "$EXISTING" = "$GRAFANA_ADMIN_PASSWORD" ]; then
        echo "secret/monitoring/grafana already current, skipping."
        exit 0
      fi

      echo "Seeding monitoring/grafana..."
      $BAO bao kv put secret/monitoring/grafana \
        admin-user="admin" \
        admin-password="$GRAFANA_ADMIN_PASSWORD"

      echo "OpenBao Infra: monitoring/grafana seeded."
    EOT
  }
}

# victoria-logs + victoria-logs-collector → Flux owner (see header note)

# ─── Platform Overview Dashboard (ConfigMap auto-loaded by Grafana sidecar) ─

resource "kubernetes_config_map" "platform_dashboard" {
  metadata {
    name      = "grafana-dashboard-platform-overview"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "platform-overview.json" = file("${path.module}/dashboards/platform-overview.json")
  }

  depends_on = [kubernetes_namespace.monitoring]
}

# headlamp → Flux owner (see header note)

# ─── Flux alerting rules (VMRule for VictoriaMetrics) ──────────────────
# kubectl_manifest (alekc) instead of kubernetes_manifest because the latter
# validates against the live K8s API at PLAN time — fails when the VMRule
# CRD doesn't exist yet (installed by helm_release.vm_k8s_stack in the same
# apply). kubectl_manifest is lazy: validation happens at apply time only.

resource "kubectl_manifest" "flux_alerts" {
  yaml_body = yamlencode({
    apiVersion = "operator.victoriametrics.com/v1beta1"
    kind       = "VMRule"
    metadata = {
      name      = "flux-alerts"
      namespace = "monitoring"
    }
    spec = {
      groups = [{
        name = "flux"
        rules = [
          {
            alert = "FluxGitRepositoryNotReady"
            expr  = "gotk_resource_info{type=\"GitRepository\", ready=\"False\"} == 1"
            for   = "10m"
            labels = {
              severity = "warning"
            }
            annotations = {
              summary     = "Flux GitRepository {{ $labels.name }} not ready"
              description = "GitRepository {{ $labels.name }} in {{ $labels.exported_namespace }} has been not ready for 10 minutes."
            }
          },
          {
            alert = "FluxKustomizationNotReady"
            expr  = "gotk_resource_info{type=\"Kustomization\", ready=\"False\"} == 1"
            for   = "10m"
            labels = {
              severity = "warning"
            }
            annotations = {
              summary     = "Flux Kustomization {{ $labels.name }} not ready"
              description = "Kustomization {{ $labels.name }} in {{ $labels.exported_namespace }} has been not ready for 10 minutes."
            }
          },
          {
            alert = "FluxHelmReleaseNotReady"
            expr  = "gotk_resource_info{type=\"HelmRelease\", ready=\"False\"} == 1"
            for   = "15m"
            labels = {
              severity = "warning"
            }
            annotations = {
              summary     = "Flux HelmRelease {{ $labels.name }} not ready"
              description = "HelmRelease {{ $labels.name }} in {{ $labels.exported_namespace }} has been not ready for 15 minutes."
            }
          },
        ]
      }]
    }
  })

  # vm-k8s-stack now owned by Flux — depends on namespace only.
  # The VMRule CRD is installed by Flux's vm-k8s-stack HelmRelease at
  # bootstrap; on first-ever apply this manifest may transiently fail
  # until Flux finishes reconciling. Retry-on-error is acceptable here.
  depends_on = [kubernetes_namespace.monitoring]
}
