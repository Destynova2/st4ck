output "zot_admin_password" {
  description = "zot admin password (htpasswd user: admin)"
  value       = local.secrets["zot_admin_password"]
  sensitive   = true
}

output "garage_admin_token" {
  description = "Garage admin API token"
  value       = local.secrets["garage_admin_token"]
  sensitive   = true
}
