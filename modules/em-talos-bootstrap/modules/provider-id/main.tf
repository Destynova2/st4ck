# Pure derivation of the Karpenter EM provider ID — no provider, no
# resource. Extracted as a submodule so the EXACT production expression is
# exercised by `tofu test` (tests/provider_id.tftest.hcl) against the same
# golden literal as the Go side (pkg/pool/providerid_test.go).
#
# Contract (MUST stay byte-identical to pool.FormatProviderID in
# karpenter-provider-scaleway/pkg/pool/providerid.go):
#   scaleway-em://<zone>/<server-id>
# Karpenter matches Nodes to NodeClaims by strict string equality of
# spec.providerID (LLD C3): one byte of drift = registration timeout loop.

variable "zone" {
  description = "Scaleway zone (e.g. fr-par-2)."
  type        = string
}

variable "server_id" {
  description = "Server ID as exposed by the scaleway TF provider — zone-prefixed (\"fr-par-2/<uuid>\") or bare UUID; only the last path segment is used."
  type        = string
}

locals {
  server_uuid = element(split("/", var.server_id), length(split("/", var.server_id)) - 1)
  provider_id = "scaleway-em://${var.zone}/${local.server_uuid}"
}

output "provider_id" {
  description = "Canonical Karpenter provider ID for this server."
  value       = local.provider_id
}
