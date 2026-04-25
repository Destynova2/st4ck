output "image_id" {
  description = "Scaleway image ID for Talos (local SSD — DEV/GP instances)."
  value       = scaleway_instance_image.talos.id
}

output "image_name" {
  description = "Scaleway image name — '{namespace}-talos-{semver}-{schematic7}'."
  value       = scaleway_instance_image.talos.name
}

output "block_image_id" {
  description = "Scaleway image ID for Talos (block storage — GPU instances)."
  value       = scaleway_instance_image.talos_block.id
}

output "block_image_name" {
  description = "Scaleway block image name."
  value       = scaleway_instance_image.talos_block.name
}

output "snapshot_id" {
  description = "Scaleway snapshot ID (l_ssd) backing the image."
  value       = scaleway_instance_snapshot.talos.id
}

output "schematic7" {
  description = "First 7 chars of the schematic SHA — pinned into image names."
  value       = local.schematic7
}

output "region" {
  description = "Region where the image was built."
  value       = var.region
}
