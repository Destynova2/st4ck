terraform {
  backend "http" {
    address        = "http://localhost:8080/state/cni"
    lock_address   = "http://localhost:8080/state/cni"
    unlock_address = "http://localhost:8080/state/cni"
  }
}
