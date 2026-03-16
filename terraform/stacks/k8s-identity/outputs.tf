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
  value       = local.secrets["oidc_client_secret"]
  sensitive   = true
}
