output "server_id" {
  description = "Scaleway server ID."
  value       = scaleway_baremetal_server.this.id
}

output "public_ip" {
  description = "Public IPv4 of the server (post-rescue + post-Talos boot)."
  value       = scaleway_baremetal_server.this.ips[0].address
}

output "talosctl_endpoint" {
  description = "Endpoint for follow-up talosctl commands (after the cluster is bootstrapped)."
  value       = "https://${scaleway_baremetal_server.this.ips[0].address}:50000"
}

output "name" {
  value = scaleway_baremetal_server.this.name
}

output "offer" {
  value = scaleway_baremetal_server.this.offer
}

output "zone" {
  value = scaleway_baremetal_server.this.zone
}
