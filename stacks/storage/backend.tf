terraform {
  backend "http" {
    address        = "http://localhost:8080/state/storage"
    lock_address   = "http://localhost:8080/state/storage"
    unlock_address = "http://localhost:8080/state/storage"
  }
}
