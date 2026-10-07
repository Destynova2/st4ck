output "namespace" {
  description = "Flux-owned autoscaling namespace"
  value       = "autoscaling"
}

output "helper_text" {
  description = "Ownership handoff status, not deployment readiness"
  value       = "Legacy state relinquished. Flux owns VPA, KEDA and prometheus-adapter. Native Scaleway capacity is opt-in: docs/how-to/scaleway-autoscaling.md."
}
