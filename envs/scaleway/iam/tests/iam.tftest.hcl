# Plan-time tests for the Scaleway IAM stage.
#
# Scope: assert on plan-time invariants only. No `command = apply`; no real
# Scaleway API calls (mock_provider). Keeps the test hermetic and free —
# critical because the real stage requires admin credentials.
#
# Tracks the Phase B refactor (commit d7d328e):
#   - scaleway_iam_application is now a map keyed by "{role}-{env_class}"
#   - bare-metal role added (ElasticMetalFullAccess for Karpenter custom provider)
#   - claude-readonly/writeable scoped apps for blast-radius containment

mock_provider "scaleway" {
  mock_resource "scaleway_account_project" {
    defaults = {
      id = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_resource "scaleway_iam_application" {
    defaults = {
      id = "22222222-2222-2222-2222-222222222222"
    }
  }

  mock_resource "scaleway_iam_policy" {
    defaults = {
      id = "33333333-3333-3333-3333-333333333333"
    }
  }

  mock_resource "scaleway_iam_api_key" {
    defaults = {
      access_key = "SCWTESTTESTTESTTESTT"
      secret_key = "44444444-4444-4444-4444-444444444444"
    }
  }

  mock_resource "scaleway_account_ssh_key" {
    defaults = {
      id = "55555555-5555-5555-5555-555555555555"
    }
  }
}

variables {
  scw_access_key          = "SCWTESTTESTTESTTESTT"
  scw_secret_key          = "66666666-6666-6666-6666-666666666666"
  scw_organization_id     = "77777777-7777-7777-7777-777777777777"
  region                  = "fr-par"
  namespace               = "st4ck-test"
  env_classes             = ["dev", "staging", "prod"]
  ssh_public_key_path     = "./tests/fixtures/id_test.pub"
  owner                   = "ci"
  enable_claude_apps      = true
  enable_claude_writeable = false
}

# ─── Project ────────────────────────────────────────────────────────────

run "project_name_follows_namespace" {
  command = plan

  assert {
    condition     = scaleway_account_project.main.name == "st4ck-test"
    error_message = "Project name must equal var.namespace"
  }
}

# ─── Role × env_class matrix ────────────────────────────────────────────

run "role_env_class_matrix_cardinality" {
  command = plan

  # 4 roles (image-builder, cluster, ci, bare-metal) × 3 env_classes (dev, staging, prod).
  assert {
    condition     = length(scaleway_iam_application.app) == 12
    error_message = "Expected 12 apps = 4 roles × 3 env_classes"
  }

  assert {
    condition     = length(scaleway_iam_policy.app) == 12
    error_message = "Every app must have exactly one policy"
  }

  assert {
    condition     = length(scaleway_iam_api_key.app) == 12
    error_message = "Every app must have exactly one API key"
  }
}

run "app_name_pattern" {
  command = plan

  assert {
    condition     = scaleway_iam_application.app["image-builder-dev"].name == "st4ck-test-dev-image-builder"
    error_message = "App name must be '{namespace}-{env_class}-{role}'"
  }

  assert {
    condition     = scaleway_iam_application.app["cluster-dev"].name == "st4ck-test-dev-cluster"
    error_message = "Cluster app name mismatch"
  }

  assert {
    condition     = scaleway_iam_application.app["ci-dev"].name == "st4ck-test-dev-ci"
    error_message = "CI app name mismatch"
  }

  assert {
    condition     = scaleway_iam_application.app["bare-metal-dev"].name == "st4ck-test-dev-bare-metal"
    error_message = "Bare-metal app name mismatch (Phase B EM autoscaling)"
  }
}

# ─── Policy permissions ─────────────────────────────────────────────────

run "image_builder_permissions" {
  command = plan

  assert {
    condition     = contains(scaleway_iam_policy.app["image-builder-dev"].rule[0].permission_set_names, "InstancesFullAccess")
    error_message = "Image builder must include InstancesFullAccess"
  }

  assert {
    condition     = contains(scaleway_iam_policy.app["image-builder-dev"].rule[0].permission_set_names, "ObjectStorageFullAccess")
    error_message = "Image builder must include ObjectStorageFullAccess"
  }
}

run "cluster_permissions" {
  command = plan

  assert {
    condition     = contains(scaleway_iam_policy.app["cluster-dev"].rule[0].permission_set_names, "LoadBalancersFullAccess")
    error_message = "Cluster must include LoadBalancersFullAccess"
  }

  assert {
    condition     = contains(scaleway_iam_policy.app["cluster-dev"].rule[0].permission_set_names, "VPCFullAccess")
    error_message = "Cluster must include VPCFullAccess"
  }

  assert {
    condition     = contains(scaleway_iam_policy.app["cluster-dev"].rule[0].permission_set_names, "DomainsDNSFullAccess")
    error_message = "Cluster must include DomainsDNSFullAccess"
  }
}

run "bare_metal_permissions" {
  command = plan

  assert {
    condition     = contains(scaleway_iam_policy.app["bare-metal-dev"].rule[0].permission_set_names, "ElasticMetalFullAccess")
    error_message = "Bare-metal must include ElasticMetalFullAccess (EM lifecycle)"
  }

  assert {
    condition     = contains(scaleway_iam_policy.app["bare-metal-dev"].rule[0].permission_set_names, "PrivateNetworksFullAccess")
    error_message = "Bare-metal must include PrivateNetworksFullAccess (tenant VPC attach)"
  }
}

# ─── Policy scope — blast-radius containment ────────────────────────────

run "policies_scoped_to_single_project" {
  command = plan

  assert {
    condition = alltrue([
      for k, p in scaleway_iam_policy.app : length(p.rule[0].project_ids) == 1
    ])
    error_message = "Every policy must be scoped to exactly one project (the st4ck project)"
  }
}

# ─── Shared SSH key ─────────────────────────────────────────────────────

run "deploy_ssh_key_name" {
  command = plan

  assert {
    condition     = scaleway_account_ssh_key.deploy.name == "st4ck-test-deploy"
    error_message = "Deploy SSH key name must be '{namespace}-deploy'"
  }
}

# ─── Claude scoped apps (blast-radius containment) ──────────────────────

run "claude_readonly_enabled_by_default" {
  command = plan

  assert {
    condition     = scaleway_iam_application.claude["readonly"].name == "st4ck-test-claude-readonly"
    error_message = "Claude readonly app name must be '{namespace}-claude-readonly'"
  }

  assert {
    condition     = contains(scaleway_iam_policy.claude["readonly"].rule[0].permission_set_names, "AllProductsReadOnly")
    error_message = "Claude readonly must include AllProductsReadOnly"
  }
}

run "claude_writeable_opt_in_only" {
  command = plan

  assert {
    condition     = length(scaleway_iam_application.claude) == 1
    error_message = "With enable_claude_writeable=false, only 'readonly' must exist"
  }
}
