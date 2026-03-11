output "harbor_admin_password" {
  description = "Harbor admin password"
  value       = random_id.harbor_admin_password.hex
  sensitive   = true
}

output "garage_admin_token" {
  description = "Garage admin API token"
  value       = random_id.garage_admin_token.hex
  sensitive   = true
}
