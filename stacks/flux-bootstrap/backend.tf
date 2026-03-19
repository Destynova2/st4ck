terraform {
  backend "http" {
    address        = "http://localhost:8080/state/flux-bootstrap"
    lock_address   = "http://localhost:8080/state/flux-bootstrap"
    unlock_address = "http://localhost:8080/state/flux-bootstrap"
  }
}
