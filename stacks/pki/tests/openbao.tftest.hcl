mock_provider "helm" {}
mock_provider "kubernetes" {
  mock_data "kubernetes_resources" {
    defaults = { objects = [] }
  }
}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "tls" {}
provider "local" {}

run "fixtures" {
  providers = { local = local }
  module {
    source = "./tests/setup"
  }
}

variables {
  kubeconfig_path = "/unused-by-mocked-providers"
}

run "new_cluster_bootstraps_one" {
  command = plan
  variables {
    kms_output_dir             = run.fixtures.directory
    openbao_bootstrap_releases = ["openbao-infra", "openbao-app"]
  }
  assert {
    condition = (
      yamldecode(helm_release.openbao_infra.values[1]).server.ha.replicas == 1 &&
      yamldecode(helm_release.openbao_app.values[1]).server.ha.replicas == 1
    )
    error_message = "A fresh cluster must initialize only one pod per release."
  }
  assert {
    condition = alltrue([
      for release in [helm_release.openbao_infra, helm_release.openbao_app] :
      strcontains(yamldecode(release.values[1]).server.ha.raft.config, "initialize \"")
    ])
    error_message = "Only the first, single-node phase must contain self-initialization."
  }
}

run "new_cluster_requires_bootstrap_phase" {
  command = plan
  variables {
    kms_output_dir = run.fixtures.directory
  }
  expect_failures = [helm_release.openbao_infra, helm_release.openbao_app]
}

run "ha_keeps_three_in_helm" {
  command = plan
  variables {
    kms_output_dir = run.fixtures.directory
  }
  override_data {
    target = data.kubernetes_resources.openbao_statefulsets
    values = { objects = [{ spec = { replicas = 3 } }] }
  }
  assert {
    condition = (
      yamldecode(helm_release.openbao_infra.values[1]).server.ha.replicas == 3 &&
      yamldecode(helm_release.openbao_app.values[1]).server.ha.replicas == 3
    )
    error_message = "Normal Helm state must keep three replicas, including after bootstrap."
  }
  assert {
    condition = alltrue([
      for release in [helm_release.openbao_infra, helm_release.openbao_app] :
      !strcontains(yamldecode(release.values[1]).server.ha.raft.config, "initialize \"")
    ])
    error_message = "HA followers and replacements must only join, never self-initialize."
  }
}

run "initialized_single_node_can_scale_without_self_init" {
  command = plan
  variables { kms_output_dir = run.fixtures.directory }
  override_data {
    target = data.kubernetes_resources.openbao_statefulsets
    values = { objects = [{ spec = { replicas = 1 } }] }
  }
  assert {
    condition     = yamldecode(helm_release.openbao_app.values[1]).server.ha.replicas == 3
    error_message = "The second apply must scale the initialized single-node cluster."
  }
}

run "bootstrap_cannot_downscale_existing_ha" {
  command = plan
  variables {
    kms_output_dir             = run.fixtures.directory
    openbao_bootstrap_releases = ["openbao-infra", "openbao-app"]
  }
  override_data {
    target = data.kubernetes_resources.openbao_statefulsets
    values = { objects = [{ spec = { replicas = 3 } }] }
  }
  expect_failures = [helm_release.openbao_infra, helm_release.openbao_app]
}

run "orphan_volumes_require_recovery" {
  command = plan
  variables {
    kms_output_dir             = run.fixtures.directory
    openbao_bootstrap_releases = ["openbao-infra", "openbao-app"]
  }
  override_data {
    target = data.kubernetes_resources.openbao_volumes
    values = { objects = [{ metadata = { name = "existing-volume" } }] }
  }
  expect_failures = [helm_release.openbao_infra, helm_release.openbao_app]
}
