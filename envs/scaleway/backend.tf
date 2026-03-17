terraform {
  backend "http" {
    address        = "http://localhost:8080/state/scaleway"
    lock_address   = "http://localhost:8080/state/scaleway"
    unlock_address = "http://localhost:8080/state/scaleway"
    username       = "TOKEN"
  }
}
