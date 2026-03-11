output "root_ca_cert" {
  description = "Root CA certificate (PEM) from KMS"
  value       = local.root_ca_cert
  sensitive   = true
}

output "infra_ca_cert" {
  description = "Infra sub-CA certificate (PEM) from KMS"
  value       = local.infra_ca_cert
  sensitive   = true
}

output "app_ca_cert" {
  description = "App sub-CA certificate (PEM) from KMS"
  value       = local.app_ca_cert
  sensitive   = true
}

output "openbao_infra_version" {
  description = "Deployed OpenBao Infra version"
  value       = helm_release.openbao_infra.version
}

output "openbao_app_version" {
  description = "Deployed OpenBao App version"
  value       = helm_release.openbao_app.version
}

output "cert_manager_version" {
  description = "Deployed cert-manager version"
  value       = helm_release.cert_manager.version
}
