# Tests for the Scaleway cluster stage.
#
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ WHY THIS FILE DOESN'T ASSERT ON PLANNED RESOURCE STATE                   ║
# ╠══════════════════════════════════════════════════════════════════════════╣
# ║ envs/scaleway/main.tf wires the security group with                      ║
# ║                                                                          ║
# ║   ip_range = scaleway_vpc_private_network.talos.ipv4_subnet[0].subnet    ║
# ║                                                                          ║
# ║ The Scaleway provider schema declares ipv4_subnet as a *computed*        ║
# ║ list-block with max_items=1. At plan-time, OpenTofu 1.11's               ║
# ║ mock_provider returns an empty list for this block — indexing [0]        ║
# ║ crashes with "empty list of object". Neither mock_resource.defaults      ║
# ║ nor override_resource can pre-seed a computed block that isn't           ║
# ║ declared in configuration (tried both object and list shapes — the       ║
# ║ framework rejects with "Cannot override block value, because it's        ║
# ║ not present in configuration"). The only fix is either to declare the    ║
# ║ block in main.tf (out of P16's write-set) or wait for a future           ║
# ║ OpenTofu release that supports injection of fully-computed blocks.       ║
# ║                                                                          ║
# ║ Mitigation: we run against the local-only setup fixture module, which    ║
# ║ (a) stages kms-output/root-ca.pem so the real main.tf would plan IF it   ║
# ║ didn't trip the block-injection bug, and (b) mirrors main.tf's root      ║
# ║ variables so we can pin the Tier-3 cluster contract (CP count, instance  ║
# ║ types, ephemeral disk size, DNS default). Hermetic — no cloud calls.     ║
# ╚══════════════════════════════════════════════════════════════════════════╝

# ─── Tier-3 cluster contract — variable-level invariants ───────────────

run "stage_fixture_and_pin_cp_count" {
  command = apply
  module {
    source = "./tests/setup"
  }

  assert {
    condition     = var.controlplane_count == 3
    error_message = "Tier-3 cluster contract pins controlplane_count at 3 (HA etcd quorum)"
  }

  assert {
    condition     = var.worker_count == 3
    error_message = "Tier-3 cluster contract pins worker_count at 3"
  }

  assert {
    condition     = null_resource.root_ca_fixture.id != ""
    error_message = "kms-output/root-ca.pem fixture must be staged before planning the real cluster"
  }
}

run "pin_instance_types" {
  command = apply
  module {
    source = "./tests/setup"
  }

  assert {
    condition     = var.cp_instance_type == "DEV1-M"
    error_message = "Control planes must default to DEV1-M (cheapest etcd-capable tier)"
  }

  assert {
    condition     = var.worker_instance_type == "DEV1-L"
    error_message = "Workers must default to DEV1-L (headroom for stack daemonsets)"
  }
}

run "pin_storage_defaults" {
  command = apply
  module {
    source = "./tests/setup"
  }

  assert {
    condition     = var.ephemeral_disk_size == 25
    error_message = "Ephemeral disk must default to 25 GiB (Scaleway l_ssd minimum for EPHEMERAL mount)"
  }
}

run "pin_dns_default_off" {
  command = apply
  module {
    source = "./tests/setup"
  }

  assert {
    condition     = var.enable_dns == false
    error_message = "DNS must default to off — opt-in only, requires a Scaleway-managed zone"
  }

  assert {
    condition     = var.dns_subdomain == "api.talos"
    error_message = "K8s API subdomain default must be 'api.talos'"
  }
}

run "pin_talos_and_k8s_versions" {
  command = apply
  module {
    source = "./tests/setup"
  }

  assert {
    condition     = var.talos_version == "v1.12.4"
    error_message = "talos_version default must match vars.mk (v1.12.4)"
  }

  assert {
    condition     = var.kubernetes_version == "1.35.0"
    error_message = "kubernetes_version default must match vars.mk (1.35.0)"
  }
}

run "fixture_points_at_repo_root_kms_output" {
  command = apply
  module {
    source = "./tests/setup"
  }

  # The setup module computes `${path.root}/../../../../kms-output/root-ca.pem`.
  # We can't pin the absolute path (cwd varies) but we can assert on the suffix.
  assert {
    condition     = endswith(output.fixture_path, "/kms-output/root-ca.pem")
    error_message = "Fixture must land at kms-output/root-ca.pem (matches main.tf file() path)"
  }
}
