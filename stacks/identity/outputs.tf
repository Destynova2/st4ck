# kratos + hydra Flux-owned (ADR-028); output the pinned var values
# instead of the helm_release attribute (which no longer exists in tofu).
output "kratos_version" {
  description = "Pinned Kratos chart version (applied by Flux)"
  value       = coalesce(var.kratos_version, local.platform_versions.kratos_version)
}

output "hydra_version" {
  description = "Pinned Hydra chart version (applied by Flux)"
  value       = coalesce(var.hydra_version, local.platform_versions.hydra_version)
}

output "pomerium_version" {
  description = "Pinned Pomerium chart version (applied by Flux)"
  value       = coalesce(var.pomerium_version, local.platform_versions.pomerium_version)
}
