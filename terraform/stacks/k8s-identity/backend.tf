terraform {
  backend "http" {
    address        = "http://localhost:8080/state/k8s-identity"
    lock_address   = "http://localhost:8080/state/k8s-identity"
    unlock_address = "http://localhost:8080/state/k8s-identity"
    username       = "TOKEN"
  }
}
