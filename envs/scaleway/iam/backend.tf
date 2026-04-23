terraform {
  # vault-backend → OpenBao KV v2 (consistent with envs/scaleway/backend.tf
  # and stacks/*/backend.tf). IAM is org-scoped (one-shot per organization),
  # so the state path is not parameterized per env/instance/region.
  backend "http" {
    address        = "http://localhost:8080/state/scaleway-iam"
    lock_address   = "http://localhost:8080/state/scaleway-iam"
    unlock_address = "http://localhost:8080/state/scaleway-iam"
  }
}
