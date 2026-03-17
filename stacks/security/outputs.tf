output "trivy_operator_version" {
  description = "Deployed Trivy Operator version"
  value       = helm_release.trivy_operator.version
}

output "tetragon_version" {
  description = "Deployed Tetragon version"
  value       = helm_release.tetragon.version
}

output "kyverno_version" {
  description = "Deployed Kyverno version"
  value       = helm_release.kyverno.version
}
