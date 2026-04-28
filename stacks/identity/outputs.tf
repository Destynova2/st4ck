# kratos + hydra Flux-owned (ADR-028); output the pinned var values
# instead of the helm_release attribute (which no longer exists in tofu).
output "kratos_version" {
  description = "Pinned Kratos chart version (applied by Flux)"
  value       = var.kratos_version
}

output "hydra_version" {
  description = "Pinned Hydra chart version (applied by Flux)"
  value       = var.hydra_version
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
