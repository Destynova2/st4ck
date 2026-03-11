terraform {
  backend "http" {
    address        = "http://localhost:8080/state/k8s-security"
    lock_address   = "http://localhost:8080/state/k8s-security"
    unlock_address = "http://localhost:8080/state/k8s-security"
    username       = "TOKEN"
  }
}
