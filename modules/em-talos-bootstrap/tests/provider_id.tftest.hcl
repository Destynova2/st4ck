# Golden proof of the providerID contract (re-review Major R6/R7/R9):
# the rendered provider_id must be byte-identical to what
# pool.FormatProviderID produces in Go — the golden literal below is the
# SAME string pinned by TestFormatProviderID in
# karpenter-provider-scaleway/pkg/pool/providerid_test.go.
#
# Runs offline (pure submodule, no provider, no credentials):
#   tofu init -backend=false && tofu test

run "provider_id_golden_from_zoned_tf_id" {
  command = apply

  module {
    source = "./modules/provider-id"
  }

  variables {
    zone      = "fr-par-2"
    server_id = "fr-par-2/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = output.provider_id == "scaleway-em://fr-par-2/11111111-2222-3333-4444-555555555555"
    error_message = "provider_id drifted from the pool.FormatProviderID contract (scaleway-em://<zone>/<server-id>)"
  }
}

run "provider_id_golden_from_bare_uuid" {
  command = apply

  module {
    source = "./modules/provider-id"
  }

  variables {
    zone      = "fr-par-2"
    server_id = "11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = output.provider_id == "scaleway-em://fr-par-2/11111111-2222-3333-4444-555555555555"
    error_message = "provider_id must be identical whether the TF provider ID is zone-prefixed or bare"
  }
}
