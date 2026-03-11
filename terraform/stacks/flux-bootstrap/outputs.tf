output "flux_ssh_public_key" {
  description = "SSH public key to add as a deploy key in Gitea (Settings → Deploy Keys)"
  value       = tls_private_key.flux_ssh.public_key_openssh
}
