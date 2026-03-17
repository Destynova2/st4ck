terraform {
  backend "http" {
    address        = "http://localhost:8080/state/identity"
    lock_address   = "http://localhost:8080/state/identity"
    unlock_address = "http://localhost:8080/state/identity"
    username       = "TOKEN"
  }
}
