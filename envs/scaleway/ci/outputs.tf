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

# Private VPC IPv4 — populated only when var.vpc_attach_instance is set.
# Use this in flux-bootstrap so cluster pods reach Gitea over the VPC
# (the public IP is locked to management_cidrs by the SG).
#
# Provider 2.73 populates scaleway_instance_server.private_ips as a list
# of {id, address} entries — both IPv4 and IPv6 are allocated when the
# private NIC attaches. We filter to the IPv4 in 172.16.0.0/16 (the
# cluster VPC's subnet) since the cluster's nodeIP is also IPv4.
output "ci_vpc_ip" {
  description = "Private IPv4 IPAM IP of the CI VM in the attached cluster VPC. Empty if no attachment."
  value = try(
    [
      for ip in scaleway_instance_server.ci.private_ips :
      split("/", ip.address)[0]
      if length(regexall("^172\\.16\\.", ip.address)) > 0
    ][0],
    "",
  )
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
