terraform {
  backend "http" {
    address        = "http://localhost:8080/state/security"
    lock_address   = "http://localhost:8080/state/security"
    unlock_address = "http://localhost:8080/state/security"
    username       = "TOKEN"
  }
}
