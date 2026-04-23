terraform {
  required_version = ">= 1.6"
}

locals {
  defaults = var.defaults_file == "" ? {} : yamldecode(file(var.defaults_file))
  overlay  = yamldecode(file(var.context_file))

  merged = merge(local.defaults, local.overlay)

  required_keys = ["namespace", "env", "instance", "region"]

  missing = [for k in local.required_keys : k if !contains(keys(local.merged), k)]
}

resource "terraform_data" "validate" {
  input = local.merged

  lifecycle {
    precondition {
      condition     = length(local.missing) == 0
      error_message = "Missing required keys in context (merged from ${var.defaults_file} + ${var.context_file}): ${join(", ", local.missing)}"
    }
  }
}
