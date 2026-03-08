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

  mock_resource "scaleway_iam_api_key" {
    defaults = {
      access_key = "SCW00000000000000000"
      secret_key = "00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  scw_access_key      = "SCW00000000000000000"
  scw_secret_key      = "00000000-0000-0000-0000-000000000000"
  scw_organization_id = "00000000-0000-0000-0000-000000000000"
  region              = "fr-par"
  project_name        = "talos-test"
  prefix              = "talos-test"
}

# ─── Project ────────────────────────────────────────────────────────────

run "project_is_created" {
  command = plan

  assert {
    condition     = scaleway_account_project.talos.name == "talos-test"
    error_message = "Project name should be 'talos-test'"
  }

  assert {
    condition     = scaleway_account_project.talos.description == "Talos Kubernetes cluster - POC"
    error_message = "Project description mismatch"
  }
}

# ─── Image Builder IAM ──────────────────────────────────────────────────

run "image_builder_app_name" {
  command = plan

  assert {
    condition     = scaleway_iam_application.image_builder.name == "talos-test-image-builder"
    error_message = "Image builder app name should use prefix"
  }
}

run "image_builder_policy_permissions" {
  command = plan

  assert {
    condition     = contains(scaleway_iam_policy.image_builder.rule[0].permission_set_names, "InstancesFullAccess")
    error_message = "Image builder policy must include InstancesFullAccess"
  }

  assert {
    condition     = contains(scaleway_iam_policy.image_builder.rule[0].permission_set_names, "ObjectStorageFullAccess")
    error_message = "Image builder policy must include ObjectStorageFullAccess"
  }

  assert {
    condition     = length(scaleway_iam_policy.image_builder.rule[0].permission_set_names) == 3
    error_message = "Image builder should have exactly 3 permission sets"
  }
}

# ─── Cluster IAM ────────────────────────────────────────────────────────

run "cluster_app_name" {
  command = plan

  assert {
    condition     = scaleway_iam_application.cluster.name == "talos-test-cluster"
    error_message = "Cluster app name should use prefix"
  }
}

run "cluster_policy_permissions" {
  command = plan

  assert {
    condition     = contains(scaleway_iam_policy.cluster.rule[0].permission_set_names, "InstancesFullAccess")
    error_message = "Cluster policy must include InstancesFullAccess"
  }

  assert {
    condition     = contains(scaleway_iam_policy.cluster.rule[0].permission_set_names, "LoadBalancersFullAccess")
    error_message = "Cluster policy must include LoadBalancersFullAccess"
  }

  assert {
    condition     = contains(scaleway_iam_policy.cluster.rule[0].permission_set_names, "VPCFullAccess")
    error_message = "Cluster policy must include VPCFullAccess"
  }

  assert {
    condition     = contains(scaleway_iam_policy.cluster.rule[0].permission_set_names, "PrivateNetworksFullAccess")
    error_message = "Cluster policy must include PrivateNetworksFullAccess"
  }

  assert {
    condition     = contains(scaleway_iam_policy.cluster.rule[0].permission_set_names, "DomainsDNSFullAccess")
    error_message = "Cluster policy must include DomainsDNSFullAccess"
  }

  assert {
    condition     = length(scaleway_iam_policy.cluster.rule[0].permission_set_names) == 6
    error_message = "Cluster should have exactly 6 permission sets"
  }
}
