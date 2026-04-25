output "project_id" {
  description = "Scaleway project ID hosting every env class."
  value       = scaleway_account_project.main.id
}

output "project_name" {
  description = "Scaleway project name (namespace)."
  value       = scaleway_account_project.main.name
}

output "ssh_key_id" {
  description = "Scaleway SSH key ID registered for every VM."
  value       = scaleway_account_ssh_key.deploy.id
}

# ─── Nested map of API keys: keys[env][role] = {access, secret} ─────────

output "keys" {
  description = "API keys indexed by [env][role]. Sensitive — consume via -raw / -json."
  sensitive   = true
  value = {
    for env in var.env_classes : env => {
      for role in keys(local.roles) : role => {
        access_key = scaleway_iam_api_key.app["${role}-${env}"].access_key
        secret_key = scaleway_iam_api_key.app["${role}-${env}"].secret_key
      }
    }
  }
}

# ─── Flat outputs for Makefile consumption (one per role+env+field) ─────
# Pattern: <role>_<env>_<field>  (e.g., cluster_dev_access_key)

output "image_builder_dev_access_key" {
  value     = scaleway_iam_api_key.app["image-builder-dev"].access_key
  sensitive = true
}
output "image_builder_dev_secret_key" {
  value     = scaleway_iam_api_key.app["image-builder-dev"].secret_key
  sensitive = true
}
output "cluster_dev_access_key" {
  value     = scaleway_iam_api_key.app["cluster-dev"].access_key
  sensitive = true
}
output "cluster_dev_secret_key" {
  value     = scaleway_iam_api_key.app["cluster-dev"].secret_key
  sensitive = true
}
output "ci_dev_access_key" {
  value     = scaleway_iam_api_key.app["ci-dev"].access_key
  sensitive = true
}
output "ci_dev_secret_key" {
  value     = scaleway_iam_api_key.app["ci-dev"].secret_key
  sensitive = true
}

output "image_builder_staging_access_key" {
  value     = scaleway_iam_api_key.app["image-builder-staging"].access_key
  sensitive = true
}
output "image_builder_staging_secret_key" {
  value     = scaleway_iam_api_key.app["image-builder-staging"].secret_key
  sensitive = true
}
output "cluster_staging_access_key" {
  value     = scaleway_iam_api_key.app["cluster-staging"].access_key
  sensitive = true
}
output "cluster_staging_secret_key" {
  value     = scaleway_iam_api_key.app["cluster-staging"].secret_key
  sensitive = true
}
output "ci_staging_access_key" {
  value     = scaleway_iam_api_key.app["ci-staging"].access_key
  sensitive = true
}
output "ci_staging_secret_key" {
  value     = scaleway_iam_api_key.app["ci-staging"].secret_key
  sensitive = true
}

output "image_builder_prod_access_key" {
  value     = scaleway_iam_api_key.app["image-builder-prod"].access_key
  sensitive = true
}
output "image_builder_prod_secret_key" {
  value     = scaleway_iam_api_key.app["image-builder-prod"].secret_key
  sensitive = true
}
output "cluster_prod_access_key" {
  value     = scaleway_iam_api_key.app["cluster-prod"].access_key
  sensitive = true
}
output "cluster_prod_secret_key" {
  value     = scaleway_iam_api_key.app["cluster-prod"].secret_key
  sensitive = true
}
output "ci_prod_access_key" {
  value     = scaleway_iam_api_key.app["ci-prod"].access_key
  sensitive = true
}
output "ci_prod_secret_key" {
  value     = scaleway_iam_api_key.app["ci-prod"].secret_key
  sensitive = true
}

# ─── Bare-metal keys (Phase B Karpenter provider — issue #1) ────────────

output "bare_metal_dev_access_key" {
  value     = try(scaleway_iam_api_key.app["bare-metal-dev"].access_key, null)
  sensitive = true
}
output "bare_metal_dev_secret_key" {
  value     = try(scaleway_iam_api_key.app["bare-metal-dev"].secret_key, null)
  sensitive = true
}
output "bare_metal_staging_access_key" {
  value     = try(scaleway_iam_api_key.app["bare-metal-staging"].access_key, null)
  sensitive = true
}
output "bare_metal_staging_secret_key" {
  value     = try(scaleway_iam_api_key.app["bare-metal-staging"].secret_key, null)
  sensitive = true
}
output "bare_metal_prod_access_key" {
  value     = try(scaleway_iam_api_key.app["bare-metal-prod"].access_key, null)
  sensitive = true
}
output "bare_metal_prod_secret_key" {
  value     = try(scaleway_iam_api_key.app["bare-metal-prod"].secret_key, null)
  sensitive = true
}

# ═══════════════════════════════════════════════════════════════════════
# Claude-scoped IAM outputs
# ═══════════════════════════════════════════════════════════════════════

output "claude_readonly_access_key" {
  description = "Claude read-only access key (scoped to st4ck project). Paste into ~/.config/scw/config.yaml as profile 'st4ck-readonly'."
  value       = try(scaleway_iam_api_key.claude["readonly"].access_key, null)
  sensitive   = true
}

output "claude_readonly_secret_key" {
  value     = try(scaleway_iam_api_key.claude["readonly"].secret_key, null)
  sensitive = true
}

output "claude_writeable_access_key" {
  description = "Claude read-write access key (scoped to st4ck project). Paste into ~/.config/scw/config.yaml as profile 'st4ck-admin'. Only emitted when enable_claude_writeable=true."
  value       = try(scaleway_iam_api_key.claude["writeable"].access_key, null)
  sensitive   = true
}

output "claude_writeable_secret_key" {
  value     = try(scaleway_iam_api_key.claude["writeable"].secret_key, null)
  sensitive = true
}

# ─── Ready-to-paste scw config snippet (multi-profile) ────────────────

output "scw_config_snippet" {
  description = "Paste this into ~/.config/scw/config.yaml to set up admin + st4ck-readonly (+ st4ck-admin if enabled) profiles. Retrieve via: tofu -chdir=envs/scaleway/iam output -raw scw_config_snippet"
  sensitive   = true
  value = templatefile("${path.module}/templates/scw-config.yaml.tpl", {
    org_id               = var.scw_organization_id
    project_id           = scaleway_account_project.main.id
    project_name         = scaleway_account_project.main.name
    region               = var.region
    readonly_enabled     = var.enable_claude_apps
    readonly_access_key  = try(scaleway_iam_api_key.claude["readonly"].access_key, "")
    readonly_secret_key  = try(scaleway_iam_api_key.claude["readonly"].secret_key, "")
    writeable_enabled    = var.enable_claude_apps && var.enable_claude_writeable
    writeable_access_key = try(scaleway_iam_api_key.claude["writeable"].access_key, "")
    writeable_secret_key = try(scaleway_iam_api_key.claude["writeable"].secret_key, "")
  })
}
