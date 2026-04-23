output "profile_name" {
  description = "Name of the Matchbox profile registered for this node."
  value       = matchbox_profile.talos.name
}

output "group_name" {
  description = "Name of the Matchbox group matching the node's MAC address."
  value       = matchbox_group.node.name
}

output "matchbox_url" {
  description = "Matchbox HTTP endpoint the node chain-boots against."
  value       = var.matchbox_url
}

output "ipxe_url" {
  description = "Per-MAC iPXE script URL — feed this to the DHCP next-server/boot-filename combo."
  value       = "${var.matchbox_url}/boot.ipxe?mac=${var.mac_address}"
}
