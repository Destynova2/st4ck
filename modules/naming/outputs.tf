output "id" {
  description = "Final resource name — '{namespace}-{env}-{instance}-{region?}-{component}[-{attr}...][-{NN}]'."
  value       = local.id
  depends_on  = [terraform_data.validate_length]
}

output "context_id" {
  description = "Context identifier — '{namespace}-{env}-{instance}[-{region}]'. Useful as a tag value or state path segment."
  value       = local.context_id
}

output "tags" {
  description = "Scaleway-style tag list ('key:value' strings) derived from context + extra_tags."
  value       = local.tags
}

output "parts" {
  description = "Raw components of the id, post-filter. Useful for constructing related names (e.g., bucket suffix)."
  value       = local.parts
}
