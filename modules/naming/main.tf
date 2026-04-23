terraform {
  required_version = ">= 1.6"
}

locals {
  context_id = join("-", compact([
    var.namespace,
    var.env,
    var.instance,
    var.region,
  ]))

  parts = compact(concat(
    [
      var.namespace,
      var.env,
      var.instance,
      var.region,
      var.component,
    ],
    var.attributes,
    var.index > 0 ? [format("%02d", var.index)] : [],
  ))

  id = join("-", local.parts)

  base_tags = [
    "app:${var.namespace}",
    "env:${var.env}",
    "instance:${var.instance}",
    "component:${var.component}",
    "owner:${var.owner}",
    "managed-by:opentofu",
    "context-id:${local.context_id}",
  ]

  tags_with_region = var.region == "" ? local.base_tags : concat(local.base_tags, ["region:${var.region}"])

  tags = concat(local.tags_with_region, var.extra_tags)
}

resource "terraform_data" "validate_length" {
  input = local.id

  lifecycle {
    precondition {
      condition     = length(local.id) <= 63
      error_message = "Computed name '${local.id}' exceeds 63 chars (Scaleway limit)."
    }
    precondition {
      condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", local.id))
      error_message = "Computed name '${local.id}' must start with a letter, end alphanumeric, and contain only lowercase/digits/hyphens."
    }
  }
}
