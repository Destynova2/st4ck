output "cilium_version" {
  description = "Deployed Cilium version"
  value       = helm_release.cilium.version
}

output "alloy_version" {
  description = "Deployed Alloy version"
  value       = helm_release.alloy.version
}

output "victoriametrics_version" {
  description = "Deployed VictoriaMetrics version"
  value       = helm_release.victoriametrics.version
}

output "loki_version" {
  description = "Deployed Loki version"
  value       = helm_release.loki.version
}

output "grafana_version" {
  description = "Deployed Grafana version"
  value       = helm_release.grafana.version
}

output "alertmanager_version" {
  description = "Deployed Alertmanager version"
  value       = helm_release.alertmanager.version
}