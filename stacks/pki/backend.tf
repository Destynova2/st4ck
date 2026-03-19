terraform {
  backend "http" {
    address        = "http://localhost:8080/state/pki"
    lock_address   = "http://localhost:8080/state/pki"
    unlock_address = "http://localhost:8080/state/pki"
  }
}
