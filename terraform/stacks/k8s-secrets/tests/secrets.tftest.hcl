mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "tls" {}

variables {
  kubernetes_host               = "https://127.0.0.1:6443"
  kubernetes_client_certificate = "dGVzdA=="
  kubernetes_client_key         = "dGVzdA=="
  kubernetes_ca_certificate     = "dGVzdA=="
}

run "root_ca_created" {
  command = plan

  assert {
    condition     = tls_self_signed_cert.root_ca.is_ca_certificate == true
    error_message = "Root CA should be a CA certificate"
  }
}

run "intermediate_ca_created" {
  command = plan

  assert {
    condition     = tls_locally_signed_cert.intermediate_ca.is_ca_certificate == true
    error_message = "Intermediate CA should be a CA certificate"
  }
}

run "openbao_infra_in_secrets_namespace" {
  command = plan

  assert {
    condition     = helm_release.openbao_infra.namespace == "secrets"
    error_message = "OpenBao infra should be in secrets namespace"
  }
}

run "openbao_app_in_secrets_namespace" {
  command = plan

  assert {
    condition     = helm_release.openbao_app.namespace == "secrets"
    error_message = "OpenBao app should be in secrets namespace"
  }
}

run "secrets_namespace_restricted" {
  command = plan

  assert {
    condition     = kubernetes_namespace.secrets.metadata[0].labels["pod-security.kubernetes.io/enforce"] == "baseline"
    error_message = "Secrets namespace should enforce baseline pod security"
  }
}
