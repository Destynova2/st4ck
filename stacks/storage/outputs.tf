output "harbor_admin_password" {
  description = "Harbor admin password"
  value       = local.secrets["harbor_admin_password"]
  sensitive   = true
}

output "garage_admin_token" {
  description = "Garage admin API token"
  value       = local.secrets["garage_admin_token"]
  sensitive   = true
}
