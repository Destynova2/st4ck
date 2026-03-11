terraform {
  backend "http" {
    address        = "http://localhost:8080/state/k8s-storage"
    lock_address   = "http://localhost:8080/state/k8s-storage"
    unlock_address = "http://localhost:8080/state/k8s-storage"
    username       = "TOKEN"
  }
}
