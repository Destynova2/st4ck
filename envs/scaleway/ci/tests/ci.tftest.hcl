mock_provider "scaleway" {}
mock_provider "random" {}

variables {
  project_id             = "00000000-0000-0000-0000-000000000000"
  scw_project_id         = "00000000-0000-0000-0000-000000000000"
  scw_image_access_key   = "SCWTEST0000000000000"
  scw_image_secret_key   = "00000000-0000-0000-0000-000000000000"
  scw_cluster_access_key = "SCWTEST0000000000001"
  scw_cluster_secret_key = "00000000-0000-0000-0000-000000000001"
}

run "ci_vm_created" {
  command = plan

  assert {
    condition     = scaleway_instance_server.ci.name == "woodpecker-ci"
    error_message = "CI VM should be named woodpecker-ci"
  }

  assert {
    condition     = scaleway_instance_server.ci.type == "DEV1-M"
    error_message = "CI VM should use DEV1-M instance type"
  }

  assert {
    condition     = contains(scaleway_instance_server.ci.tags, "gitea")
    error_message = "CI VM should have gitea tag"
  }
}

run "security_group_config" {
  command = plan

  assert {
    condition     = scaleway_instance_security_group.ci.inbound_default_policy == "drop"
    error_message = "Default inbound policy should be drop"
  }
}

run "password_generated" {
  command = plan

  assert {
    condition     = random_password.gitea_admin.length == 24
    error_message = "Gitea admin password should be 24 characters"
  }
}
