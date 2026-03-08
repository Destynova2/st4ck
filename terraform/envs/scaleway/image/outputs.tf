output "image_id" {
  description = "Scaleway image ID for Talos"
  value       = scaleway_instance_image.talos.id
}

output "image_name" {
  description = "Scaleway image name for Talos"
  value       = scaleway_instance_image.talos.name
}

output "snapshot_id" {
  description = "Scaleway snapshot ID for Talos"
  value       = scaleway_instance_snapshot.talos.id
}
