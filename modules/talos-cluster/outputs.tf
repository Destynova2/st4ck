# ─── Machine Configs (to be used as user-data by the infra layer) ──────────

output "controlplane_machine_configurations" {
  description = "Map of control plane node name => machine configuration YAML"
  value = {
    for name, cfg in data.talos_machine_configuration.controlplane :
    name => cfg.machine_configuration
  }
  sensitive = true
}

output "worker_machine_configurations" {
  description = "Map of worker node name => machine configuration YAML"
  value = {
    for name, cfg in data.talos_machine_configuration.worker :
    name => cfg.machine_configuration
  }
  sensitive = true
}

# ─── Client Configuration ──────────────────────────────────────────────────

output "client_configuration" {
  description = "Talos client configuration (for talosctl)"
  value       = data.talos_client_configuration.this
  sensitive   = true
}

output "talosconfig" {
  description = "Talosconfig YAML content"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

# ─── Secrets (for reuse / bootstrap) ───────────────────────────────────────

output "machine_secrets" {
  description = "Talos machine secrets (needed for bootstrap and kubeconfig resources)"
  value       = talos_machine_secrets.this
  sensitive   = true
}

output "client_configuration_raw" {
  description = "Raw client configuration (needed for bootstrap and kubeconfig resources)"
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
}
