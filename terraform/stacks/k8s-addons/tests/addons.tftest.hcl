mock_provider "helm" {}

variables {
  kubernetes_host               = "https://51.159.100.1:6443"
  kubernetes_client_certificate = "dGVzdA=="
  kubernetes_client_key         = "dGVzdA=="
  kubernetes_ca_certificate     = "dGVzdA=="
  cilium_version                = "1.17.0"
  alloy_version                 = "1.6.1"
  victoriametrics_version       = "0.18.0"
  loki_version                  = "6.53.0"
  grafana_version               = "10.5.15"
  alertmanager_version          = "1.33.1"
}

# ─── Cilium ────────────────────────────────────────────────────────────

run "cilium_in_kube_system" {
  command = plan

  assert {
    condition     = helm_release.cilium.namespace == "kube-system"
    error_message = "Cilium should be deployed to kube-system"
  }
}

# ─── Observability stack in monitoring namespace ───────────────────────

run "victoriametrics_in_monitoring" {
  command = plan

  assert {
    condition     = helm_release.victoriametrics.namespace == "monitoring"
    error_message = "VictoriaMetrics should be in monitoring namespace"
  }
}

run "loki_in_monitoring" {
  command = plan

  assert {
    condition     = helm_release.loki.namespace == "monitoring"
    error_message = "Loki should be in monitoring namespace"
  }
}

run "grafana_in_monitoring" {
  command = plan

  assert {
    condition     = helm_release.grafana.namespace == "monitoring"
    error_message = "Grafana should be in monitoring namespace"
  }
}

run "alertmanager_in_monitoring" {
  command = plan

  assert {
    condition     = helm_release.alertmanager.namespace == "monitoring"
    error_message = "Alertmanager should be in monitoring namespace"
  }
}

run "alloy_in_monitoring" {
  command = plan

  assert {
    condition     = helm_release.alloy.namespace == "monitoring"
    error_message = "Alloy should be in monitoring namespace"
  }
}
