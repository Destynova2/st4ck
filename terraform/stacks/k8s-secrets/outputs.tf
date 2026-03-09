output "root_ca_cert" {
  description = "Root CA certificate (PEM)"
  value       = tls_self_signed_cert.root_ca.cert_pem
  sensitive   = true
}

output "intermediate_ca_cert" {
  description = "Intermediate CA certificate (PEM)"
  value       = tls_locally_signed_cert.intermediate_ca.cert_pem
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

output "kratos_version" {
  description = "Deployed Ory Kratos version"
  value       = helm_release.kratos.version
}

output "hydra_version" {
  description = "Deployed Ory Hydra version"
  value       = helm_release.hydra.version
}

output "pomerium_version" {
  description = "Deployed Pomerium version"
  value       = helm_release.pomerium.version
}

output "oidc_client_secret" {
  description = "OIDC client secret for kubernetes client (for kubelogin)"
  value       = random_id.oidc_client_secret.hex
  sensitive   = true
}

output "harbor_admin_password" {
  description = "Harbor admin password"
  value       = random_id.harbor_admin_password.hex
  sensitive   = true
}
