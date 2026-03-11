terraform {
  backend "http" {
    address        = "http://localhost:8080/state/k8s-pki"
    lock_address   = "http://localhost:8080/state/k8s-pki"
    unlock_address = "http://localhost:8080/state/k8s-pki"
    username       = "TOKEN"
  }
}
