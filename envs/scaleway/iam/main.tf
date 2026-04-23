terraform {
  required_version = ">= 1.6"
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
  }
}

provider "scaleway" {
  access_key      = var.scw_access_key
  secret_key      = var.scw_secret_key
  organization_id = var.scw_organization_id
  region          = var.region
}

# ═══════════════════════════════════════════════════════════════════════
# Single project hosts every env class × instance × region.
# IAM apps are scoped per (role × env class) — not per instance.
# ═══════════════════════════════════════════════════════════════════════

resource "scaleway_account_project" "main" {
  name        = var.namespace
  description = "${var.namespace} — Talos multi-env infrastructure"
}

# ─── Role × env class matrix ────────────────────────────────────────────

locals {
  roles = {
    image-builder = {
      description = "Builds Talos images: VM + S3 upload + snapshot import"
      permissions = [
        "InstancesFullAccess",
        "ObjectStorageFullAccess",
        "BlockStorageFullAccess",
      ]
    }
    cluster = {
      description = "Deploys Talos cluster: instances, LB, VPC, security groups"
      permissions = [
        "InstancesFullAccess",
        "BlockStorageFullAccess",
        "LoadBalancersFullAccess",
        "VPCFullAccess",
        "PrivateNetworksFullAccess",
        "IPAMReadOnly",
        "DomainsDNSFullAccess",
        "ObjectStorageFullAccess",
      ]
    }
    ci = {
      description = "CI VM: Gitea + Woodpecker + platform pod"
      permissions = [
        "InstancesFullAccess",
        "BlockStorageFullAccess",
        "VPCFullAccess",
        "ObjectStorageFullAccess",
      ]
    }
    bare-metal = {
      description = "Karpenter custom provider — Scaleway Elastic Metal lifecycle (Phase B)"
      permissions = [
        "ElasticMetalFullAccess",       # CreateServer / RebootRescue / Delete
        "PrivateNetworksFullAccess",    # attach EM to a tenant Private Network
        "ObjectStorageReadOnly",        # pull Talos RAW image from Garage S3 mirror
        "IPAMReadOnly",                 # introspect flexible IPs
      ]
    }
  }

  # Cartesian product: one entry per (role, env_class).
  apps = {
    for pair in setproduct(keys(local.roles), var.env_classes) :
    "${pair[0]}-${pair[1]}" => {
      role     = pair[0]
      env      = pair[1]
      app_name = "${var.namespace}-${pair[1]}-${pair[0]}" # e.g., st4ck-dev-image-builder
      role_def = local.roles[pair[0]]
    }
  }

  # Scaleway IAM tags allow charset [a-zA-Z0-9._\-/=+@ ] only — no ':'.
  # Use '=' as key/value separator (still readable, common AWS-style).
  base_tags = [
    "app=${var.namespace}",
    "managed-by=opentofu",
    "owner=${var.owner}",
  ]
}

# ─── IAM apps ────────────────────────────────────────────────────────────

resource "scaleway_iam_application" "app" {
  for_each = local.apps

  name        = each.value.app_name
  description = "[${each.value.env}] ${each.value.role_def.description}"
  tags        = concat(local.base_tags, ["env=${each.value.env}", "role=${each.value.role}"])
}

resource "scaleway_iam_policy" "app" {
  for_each = local.apps

  name           = each.value.app_name
  description    = "[${each.value.env}] ${each.value.role_def.description}"
  application_id = scaleway_iam_application.app[each.key].id
  tags           = concat(local.base_tags, ["env=${each.value.env}", "role=${each.value.role}"])

  rule {
    project_ids          = [scaleway_account_project.main.id]
    permission_set_names = each.value.role_def.permissions
  }
}

resource "scaleway_iam_api_key" "app" {
  for_each = local.apps

  application_id     = scaleway_iam_application.app[each.key].id
  description        = "OpenTofu — ${each.value.app_name}"
  default_project_id = scaleway_account_project.main.id
}

# ─── Shared SSH key (project-scoped, used by every VM) ───────────────────

resource "scaleway_account_ssh_key" "deploy" {
  name       = "${var.namespace}-deploy"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  project_id = scaleway_account_project.main.id
}

# ═══════════════════════════════════════════════════════════════════════
# Claude/AI scoped IAM apps
#
# The organization holds several projects (default, openclaw-production,
# fmj, client-agence-liard-tanguy, ...) — Claude must NEVER reach them.
# These apps are project-scoped to st4ck only; IAM policies bind them to
# this project's ID exclusively.
#
# - claude-readonly  : always created when enable_claude_apps=true
# - claude-writeable : opt-in via enable_claude_writeable=true
# ═══════════════════════════════════════════════════════════════════════

locals {
  claude_readonly_perms = concat(
    ["AllProductsReadOnly"],
    var.claude_readonly_include_iam ? ["IAMReadOnly"] : [],
  )

  claude_writeable_perms = [
    "InstancesFullAccess",
    "BlockStorageFullAccess",
    "ObjectStorageFullAccess",
    "VPCFullAccess",
    "PrivateNetworksFullAccess",
    "LoadBalancersFullAccess",
    "DomainsDNSFullAccess",
    "IPAMReadOnly",
  ]

  claude_apps_map = {
    readonly = {
      enabled     = var.enable_claude_apps
      description = "Read-only access for Claude/AI tooling — scoped to st4ck project ONLY. Cannot reach other org projects."
      permissions = local.claude_readonly_perms
    }
    writeable = {
      enabled     = var.enable_claude_apps && var.enable_claude_writeable
      description = "Read-write access for Claude/AI tooling — scoped to st4ck project ONLY. Use with denylist enforcement in .claude/settings.json."
      permissions = local.claude_writeable_perms
    }
  }

  claude_apps = { for k, v in local.claude_apps_map : k => v if v.enabled }
}

resource "scaleway_iam_application" "claude" {
  for_each = local.claude_apps

  name        = "${var.namespace}-claude-${each.key}"
  description = each.value.description
  tags        = concat(local.base_tags, ["role=claude-${each.key}", "scope=${var.namespace}-only"])
}

resource "scaleway_iam_policy" "claude" {
  for_each = local.claude_apps

  name           = "${var.namespace}-claude-${each.key}"
  description    = each.value.description
  application_id = scaleway_iam_application.claude[each.key].id
  tags           = concat(local.base_tags, ["role=claude-${each.key}", "scope=${var.namespace}-only"])

  rule {
    project_ids          = [scaleway_account_project.main.id]
    permission_set_names = each.value.permissions
  }
}

resource "scaleway_iam_api_key" "claude" {
  for_each = local.claude_apps

  application_id     = scaleway_iam_application.claude[each.key].id
  description        = "OpenTofu — claude-${each.key} (st4ck-scoped)"
  default_project_id = scaleway_account_project.main.id
}
