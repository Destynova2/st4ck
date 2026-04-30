output "registry_namespace_id" {
  description = "Scaleway resource ID of the SCR namespace."
  value       = scaleway_registry_namespace.mirror.id
}

output "registry_namespace_name" {
  description = "Name of the SCR namespace (path component after the host)."
  value       = scaleway_registry_namespace.mirror.name
}

output "registry_endpoint" {
  description = "Pullable endpoint URL: rg.{region}.scw.cloud/{namespace_name}. Use as <REGISTRY> in skopeo/docker push and as the Talos registry mirror endpoint."
  value       = scaleway_registry_namespace.mirror.endpoint
}

output "registry_region" {
  description = "Region of the SCR namespace — must match the cluster's region for free intra-region bandwidth."
  value       = var.region
}

output "is_public" {
  description = "True if the namespace uses the 75 GB free public tier."
  value       = scaleway_registry_namespace.mirror.is_public
}
