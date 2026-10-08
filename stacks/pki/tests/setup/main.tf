terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

# Deliberately invalid, non-secret fixtures. Plan tests never contact a cluster.
resource "local_file" "certificates" {
  for_each = toset([
    "root-ca.pem", "infra-ca.pem", "infra-ca-key.pem", "infra-ca-chain.pem",
    "app-ca.pem", "app-ca-key.pem", "app-ca-chain.pem",
  ])
  filename        = "${path.module}/.fixtures/${each.key}"
  content         = "NOT-A-CERTIFICATE-OR-KEY: local plan fixture only\n"
  file_permission = "0600"
}

output "directory" {
  value      = abspath("${path.module}/.fixtures")
  depends_on = [local_file.certificates]
}
