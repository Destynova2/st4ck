terraform {
  backend "http" {
    address        = "http://localhost:8080/state/monitoring"
    lock_address   = "http://localhost:8080/state/monitoring"
    unlock_address = "http://localhost:8080/state/monitoring"
    username       = "TOKEN"
  }
}
