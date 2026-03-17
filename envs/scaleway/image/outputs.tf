output "image_id" {
  description = "Scaleway image ID for Talos (local SSD)"
  value       = scaleway_instance_image.talos.id
}

output "image_name" {
  description = "Scaleway image name for Talos (local SSD)"
  value       = scaleway_instance_image.talos.name
}

output "snapshot_id" {
  description = "Scaleway snapshot ID for Talos (local SSD)"
  value       = scaleway_instance_snapshot.talos.id
}

output "block_image_name" {
  description = "Scaleway image name for Talos (block storage — GPU instances)"
  value       = "talos-${var.talos_version}-block"
}
