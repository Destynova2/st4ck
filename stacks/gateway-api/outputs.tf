output "gateway_name" {
  description = "Name of the shared tenant Gateway"
  value       = var.gateway_name
}

output "gateway_namespace" {
  description = "Namespace of the shared tenant Gateway"
  value       = var.gateway_namespace
}

output "gateway_class_name" {
  description = "GatewayClass referenced by the shared tenant Gateway"
  value       = var.gateway_class_name
}

output "gateway_api_version" {
  description = "Pinned kubernetes-sigs/gateway-api release tag used for CRDs"
  value       = var.gateway_api_version
}

output "base_domain" {
  description = "Base DNS domain — tenants are exposed at <tenant>-api.<base_domain>"
  value       = var.base_domain
}

output "public_ip_hint" {
  description = "Shell commands to retrieve the Gateway's public IP + wildcard DNS hint."
  value       = <<-EOT
    Cilium materialises a Service of type LoadBalancer for this Gateway.
    Retrieve the public IP (allocated by scaleway-cloud-controller-manager)
    after apply with:

        kubectl -n ${var.gateway_namespace} get gateway ${var.gateway_name} \
          -o jsonpath='{.status.addresses[0].value}'

    or, equivalently, on the backing Service:

        kubectl -n ${var.gateway_namespace} get svc -l \
          gateway.networking.k8s.io/gateway-name=${var.gateway_name} \
          -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'

    Point "*.${var.base_domain}" (wildcard A/AAAA) at that IP — each
    tenant-<T>-api.${var.base_domain} will then be SNI-routed by Cilium
    to the matching TenantControlPlane apiserver via TLSRoute.
  EOT
}
