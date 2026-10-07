mock_provider "scaleway" {
  mock_resource "scaleway_vpc_private_network" {
    defaults = { id = "66666666-6666-6666-6666-666666666666" }
  }
  mock_resource "scaleway_instance_security_group" {
    defaults = { id = "fr-par-1/11111111-1111-1111-1111-111111111111" }
  }
  mock_resource "scaleway_instance_ip" {
    defaults = {
      id      = "fr-par-1/22222222-2222-2222-2222-222222222222"
      address = "10.0.0.1"
    }
  }
}
mock_provider "random" {}
mock_provider "local" {}
mock_provider "null" {}

variables {
  project_id             = "11111111-1111-1111-1111-111111111111"
  context_file           = "../../../contexts/dev-shared-fr-par.yaml"
  ssh_public_key_path    = "./tests/fixtures/id_test.pub"
  ssh_private_key_path   = "./tests/fixtures/id_test"
  scw_access_key         = "SCWTEST0000000000000"
  scw_secret_key         = "00000000-0000-0000-0000-000000000000"
  scw_project_id         = "11111111-1111-1111-1111-111111111111"
  scw_image_access_key   = "SCWTEST0000000000001"
  scw_image_secret_key   = "quote\"-backslash\\-newline\n: #secret"
  scw_cluster_access_key = "SCWTEST0000000000002"
  scw_cluster_secret_key = "quote\"-backslash\\-newline\n: #secret"
}

run "bootstrap_artifact_safety" {
  command = plan

  assert {
    condition = alltrue([
      local_file.platform_configmap.file_permission == "0600",
      local_file.platform_configmap.directory_permission == "0700",
      local_sensitive_file.platform_secrets.file_permission == "0600",
      local_sensitive_file.platform_secrets.directory_permission == "0700",
      local_sensitive_file.platform_unseal_key.directory_permission == "0700",
      local_file.platform_pod_yaml.directory_permission == "0700",
      local_file.platform_pod_yaml.file_permission == "0600",
      local_sensitive_file.bao_seal_key_backup.directory_permission == "0700",
    ])
    error_message = "Seal-bearing artifacts and their directories must be private."
  }

  assert {
    condition     = yamldecode(local.secrets_yaml).stringData.CI_SCW_IMAGE_SECRET_KEY == var.scw_image_secret_key
    error_message = "Secret values must survive quotes, backslashes and line breaks."
  }

  assert {
    condition = alltrue([
      null_resource.ci_bootstrap.triggers.preflight_sha == filesha256("../../../scripts/bootstrap-preflight.py"),
      null_resource.ci_bootstrap.triggers.source_sha == local.setup_source_sha,
    ])
    error_message = "Guard/source changes must retrigger the remote bootstrap."
  }
}
