terraform {
  backend "http" {
    address        = "http://localhost:8080/state/k8s-monitoring"
    lock_address   = "http://localhost:8080/state/k8s-monitoring"
    unlock_address = "http://localhost:8080/state/k8s-monitoring"
    username       = "TOKEN"
  }
}
