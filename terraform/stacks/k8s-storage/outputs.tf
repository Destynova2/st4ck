output "local_path_provisioner_version" {
  description = "Deployed local-path-provisioner version"
  value       = helm_release.local_path_provisioner.version
}
