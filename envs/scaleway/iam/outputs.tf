# ─── Project ────────────────────────────────────────────────────────────

output "project_id" {
  description = "Scaleway project ID"
  value       = scaleway_account_project.talos.id
}

# ─── Image Builder credentials ───────────────────────────────────────────

output "image_builder_access_key" {
  description = "Access key for the image builder application"
  value       = scaleway_iam_api_key.image_builder.access_key
  sensitive   = true
}

output "image_builder_secret_key" {
  description = "Secret key for the image builder application"
  value       = scaleway_iam_api_key.image_builder.secret_key
  sensitive   = true
}

# ─── Cluster credentials ────────────────────────────────────────────────

output "cluster_access_key" {
  description = "Access key for the cluster application"
  value       = scaleway_iam_api_key.cluster.access_key
  sensitive   = true
}

output "cluster_secret_key" {
  description = "Secret key for the cluster application"
  value       = scaleway_iam_api_key.cluster.secret_key
  sensitive   = true
}

# ─── Helper: export commands ────────────────────────────────────────────

output "export_image_builder" {
  description = "Shell commands to export image builder credentials"
  value       = <<-EOT
    export SCW_ACCESS_KEY=$(terraform -chdir=envs/scaleway/iam output -raw image_builder_access_key)
    export SCW_SECRET_KEY=$(terraform -chdir=envs/scaleway/iam output -raw image_builder_secret_key)
  EOT
}

# ─── Terraform State Bucket ──────────────────────────────────────────

output "tfstate_bucket" {
  description = "S3 bucket name for Terraform state"
  value       = scaleway_object_bucket.tfstate.name
}

# ─── CI credentials ───────────────────────────────────────────────────

output "ci_access_key" {
  description = "Access key for the CI application"
  value       = scaleway_iam_api_key.ci.access_key
  sensitive   = true
}

output "ci_secret_key" {
  description = "Secret key for the CI application"
  value       = scaleway_iam_api_key.ci.secret_key
  sensitive   = true
}

output "export_cluster" {
  description = "Shell commands to export cluster credentials"
  value       = <<-EOT
    export SCW_ACCESS_KEY=$(terraform -chdir=envs/scaleway/iam output -raw cluster_access_key)
    export SCW_SECRET_KEY=$(terraform -chdir=envs/scaleway/iam output -raw cluster_secret_key)
  EOT
}

# ─── Velero Backup Bucket ──────────────────────────────────────────

output "velero_bucket" {
  description = "S3 bucket name for Velero backups"
  value       = scaleway_object_bucket.velero.name
}
