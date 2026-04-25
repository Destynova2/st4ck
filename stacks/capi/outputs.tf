output "capi_namespace" {
  description = "Namespace hosting cluster-api-operator + provider manifests"
  value       = kubernetes_namespace.capi_system.metadata[0].name
}

output "capi_operator_version" {
  description = "Deployed cluster-api-operator Helm chart version"
  value       = helm_release.capi_operator.version
}

output "capi_core_version" {
  description = "Pinned CAPI core provider version"
  value       = var.capi_core_version
}

output "capi_bootstrap_talos_version" {
  description = "Pinned CABPT (Talos bootstrap provider) version"
  value       = var.capi_bootstrap_talos_version
}

output "capi_controlplane_kamaji_version" {
  description = "Pinned Kamaji control plane provider version"
  value       = var.capi_controlplane_kamaji_version
}

output "capi_infrastructure_scaleway_version" {
  description = "Pinned Scaleway infrastructure provider (CAPS) version"
  value       = var.capi_infrastructure_scaleway_version
}

output "scaleway_credentials_secret" {
  description = "Name of the Kubernetes Secret holding Scaleway credentials for CAPS"
  value       = "${kubernetes_secret.scaleway_credentials.metadata[0].namespace}/${kubernetes_secret.scaleway_credentials.metadata[0].name}"
}

# Provider readiness indicators — materialised as CR names that downstream
# stacks (kamaji, managed-cluster) can use to build `depends_on` via
# `data "kubectl_manifest"` lookups or `kubectl_wait` modules.
output "core_provider_name" {
  description = "CoreProvider CR name (cluster.x-k8s.io)"
  value       = kubectl_manifest.core_provider.name
}

output "bootstrap_talos_provider_name" {
  description = "BootstrapProvider CR name (CABPT / Talos)"
  value       = kubectl_manifest.bootstrap_talos.name
}

output "controlplane_kamaji_provider_name" {
  description = "ControlPlaneProvider CR name (Kamaji)"
  value       = kubectl_manifest.controlplane_kamaji.name
}

output "infrastructure_scaleway_provider_name" {
  description = "InfrastructureProvider CR name (Scaleway / CAPS)"
  value       = kubectl_manifest.infrastructure_scaleway.name
}
