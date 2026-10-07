mock_provider "gitea" {}
mock_provider "vault" {}
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "local" {}

variables {
  bao_admin_password = "mock-bootstrap-password"
  ci_password        = "mock-gitea-password"
}

# Plan only: no provisioner, API, filesystem resource or Git push is run.
run "repository_starts_empty_for_non_force_snapshot_push" {
  command = plan

  assert {
    condition     = gitea_repository.talos.auto_init == false
    error_message = "The repository must start empty, without an unrelated provider-generated initial commit."
  }

}
