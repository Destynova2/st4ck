# trivy/tetragon/kyverno Flux-owned (ADR-028); output pinned var values.
output "trivy_operator_version" {
  description = "Pinned Trivy Operator chart version (applied by Flux)"
  value       = var.trivy_operator_version
}

output "tetragon_version" {
  description = "Pinned Tetragon chart version (applied by Flux)"
  value       = var.tetragon_version
}

output "kyverno_version" {
  description = "Pinned Kyverno chart version (applied by Flux)"
  value       = var.kyverno_version
}
