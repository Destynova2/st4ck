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

# Private VPC IPv4 — always populated (CI owns the PN, NIC is unconditional).
# Use this in flux-bootstrap so cluster pods reach Gitea over the VPC
# (the public IP is locked to management_cidrs by the SG).
#
# Provider 2.73 populates scaleway_instance_server.private_ips as a list
# of {id, address} entries — both IPv4 and IPv6 are allocated when the
# private NIC attaches. We filter to the IPv4 in 172.16.0.0/16 (the
# shared PN's subnet) since the cluster's nodeIP is also IPv4.
output "ci_vpc_ip" {
  description = "Private IPv4 IPAM IP of the CI VM on the shared PN."
  value = try(
    [
      for ip in scaleway_instance_server.ci.private_ips :
      split("/", ip.address)[0]
      if length(regexall("^172\\.16\\.", ip.address)) > 0
    ][0],
    "",
  )
}

# ─── Shared PN (consumed by cluster stack via data source lookup) ────────
output "shared_pn_id" {
  description = "Private Network ID owned by CI stack — shared with cluster stack."
  value       = scaleway_vpc_private_network.shared.id
}

output "shared_pn_name" {
  description = "Private Network name (used by cluster data source lookup)."
  value       = scaleway_vpc_private_network.shared.name
}

output "shared_pn_subnet" {
  description = "Private Network IPv4 subnet (CIDR) of the shared PN."
  value       = try(scaleway_vpc_private_network.shared.ipv4_subnet[0].subnet, "")
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
