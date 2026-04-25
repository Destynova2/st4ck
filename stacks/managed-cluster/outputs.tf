output "tenant_namespace" {
  description = "Kubernetes namespace containing every resource rendered for this tenant."
  value       = local.tenant_namespace
}

output "tenant_name" {
  description = "Tenant identifier (from context.instance)."
  value       = local.tenant_name
}

output "context_id" {
  description = "st4ck context id — 'st4ck-tenant-<name>-<region>'."
  value       = "st4ck-tenant-${local.tenant_name}-${local.region}"
}

output "apiserver_host" {
  description = "Public hostname for the tenant apiserver (DNS wildcard → Scaleway LB → Cilium Gateway → TCP)."
  value       = "${local.tenant_name}-api.${try(local.ctx.ingress.base_domain, "st4ck.local")}"
}

output "kubeconfig_retrieve_cmd" {
  description = "Copy-paste command that writes the tenant's admin kubeconfig to ~/.kube/tenant-<name>."
  value = format(
    "kubectl get secret %s-tenant-kubeconfig -n %s -o jsonpath='{.data.admin\\.conf}' | base64 -d > ~/.kube/tenant-%s",
    local.tenant_name,
    local.tenant_namespace,
    local.tenant_name,
  )
}

output "chart_values" {
  description = "Effective Helm values passed to the chart (useful for debugging)."
  value       = local.chart_values
  sensitive   = false
}
