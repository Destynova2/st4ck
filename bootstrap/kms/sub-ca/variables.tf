variable "name" {
  type = string
}

variable "common_name" {
  type = string
}

variable "mount_path" {
  type = string
}

variable "root_backend" {
  type = string
}

variable "root_ca_pem" {
  type = string
}

variable "domains" {
  type = list(string)
}

variable "output_dir" {
  type = string
}
