output "context" {
  description = "Merged context (defaults <- context_file). Keys: namespace, env, instance, region, owner, talos_version, + any project-specific keys."
  value       = local.merged
  depends_on  = [terraform_data.validate]
}

output "namespace" {
  value = local.merged.namespace
}

output "env" {
  value = local.merged.env
}

output "instance" {
  value = local.merged.instance
}

output "region" {
  value = local.merged.region
}

output "owner" {
  value = lookup(local.merged, "owner", "unknown")
}

output "context_id" {
  description = "Short identifier '{namespace}-{env}-{instance}-{region}'."
  value       = join("-", [local.merged.namespace, local.merged.env, local.merged.instance, local.merged.region])
}

output "state_path" {
  description = "Hierarchical state path '/state/{namespace}/{env}/{instance}/{region}' (no trailing stage)."
  value       = "/state/${local.merged.namespace}/${local.merged.env}/${local.merged.instance}/${local.merged.region}"
}
