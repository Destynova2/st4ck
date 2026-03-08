output "talosconfig" {
  description = "Talosconfig content (write to file for talosctl)"
  value       = module.talos.talosconfig
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubeconfig content"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "controlplane_ips" {
  description = "IPs assigned to control plane nodes"
  value       = { for name, node in local.controlplane_nodes : name => node.ip }
}

output "worker_ips" {
  description = "IPs assigned to worker nodes"
  value       = { for name, node in local.worker_nodes : name => node.ip }
}

output "vip" {
  description = "Virtual IP for the Kubernetes API endpoint"
  value       = local.vip
}
