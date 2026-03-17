output "talosconfig" {
  description = "Talosconfig content"
  value       = module.talos.talosconfig
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubeconfig content"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "lb_dns_name" {
  description = "DNS name of the Kubernetes API load balancer"
  value       = outscale_load_balancer.k8s_api.dns_name
}

output "controlplane_ips" {
  description = "Private IPs of control plane nodes"
  value = {
    for name, vm in outscale_vm.control_plane :
    name => vm.private_ip
  }
}

output "worker_ips" {
  description = "Private IPs of worker nodes"
  value = {
    for name, vm in outscale_vm.worker :
    name => vm.private_ip
  }
}
