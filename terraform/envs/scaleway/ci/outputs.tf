output "ci_ip" {
  description = "Public IP of the CI VM"
  value       = scaleway_instance_ip.ci.address
}

output "gitea_url" {
  description = "Gitea URL"
  value       = "http://${scaleway_instance_ip.ci.address}:3000"
}

output "woodpecker_url" {
  description = "Woodpecker CI URL"
  value       = "http://${scaleway_instance_ip.ci.address}:8000"
}

output "gitea_admin_password" {
  description = "Generated Gitea admin password"
  value       = random_password.gitea_admin.result
  sensitive   = true
}
