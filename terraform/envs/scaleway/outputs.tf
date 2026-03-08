output "talosconfig" {
  description = "Talosconfig content"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubeconfig content"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "lb_ip" {
  description = "IP of the Kubernetes API load balancer"
  value       = scaleway_lb_ip.k8s_api.ip_address
}

output "api_endpoint" {
  description = "Kubernetes API endpoint"
  value       = var.enable_dns ? "https://${var.dns_subdomain}.${var.dns_zone}:6443" : "https://${scaleway_lb_ip.k8s_api.ip_address}:6443"
}

output "kubernetes_host" {
  description = "Kubernetes API server URL"
  value       = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
}

output "kubernetes_client_certificate" {
  description = "Base64-encoded client certificate"
  value       = talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate
  sensitive   = true
}

output "kubernetes_client_key" {
  description = "Base64-encoded client key"
  value       = talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key
  sensitive   = true
}

output "kubernetes_ca_certificate" {
  description = "Base64-encoded CA certificate"
  value       = talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate
  sensitive   = true
}

output "controlplane_ips" {
  description = "Public IPs of control plane nodes"
  value = {
    for name, ip in scaleway_instance_ip.cp :
    name => ip.address
  }
}

output "worker_ips" {
  description = "Public IPs of worker nodes"
  value = {
    for name, ip in scaleway_instance_ip.wrk :
    name => ip.address
  }
}
