terraform {
  backend "http" {
    address        = "http://localhost:8080/state/k8s-cni"
    lock_address   = "http://localhost:8080/state/k8s-cni"
    unlock_address = "http://localhost:8080/state/k8s-cni"
    username       = "TOKEN"
  }
}
