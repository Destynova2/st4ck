output "context_id" {
  description = "Context identifier '{namespace}-{env}-{instance}-{region}'."
  value       = local.prefix
}

output "ci_id" {
  description = "CI VM name — '{context_id}-ci'."
  value       = local.ci_id
}

output "ci_ip" {
  description = "Public IP of the CI VM."
  value       = scaleway_instance_ip.ci.address
}

output "gitea_url" {
  description = "Gitea URL."
  value       = "http://${scaleway_instance_ip.ci.address}:3000"
}

output "woodpecker_url" {
  description = "Woodpecker CI URL."
  value       = "http://${scaleway_instance_ip.ci.address}:8000"
}

output "vault_backend_url" {
  description = "vault-backend HTTP endpoint on the CI VM."
  value       = "http://${scaleway_instance_ip.ci.address}:8080"
}

output "gitea_admin_password" {
  description = "Generated Gitea admin password."
  value       = random_password.gitea_admin.result
  sensitive   = true
}

output "ssh_host" {
  description = "SSH connection string — 'root@<ip>'. Use with `make bootstrap-tunnel BOOTSTRAP_HOST=<this>`."
  value       = "root@${scaleway_instance_ip.ci.address}"
}
