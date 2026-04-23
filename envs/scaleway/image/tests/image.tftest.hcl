# Plan-time tests for the Scaleway Talos image build stage.
#
# Scope: assert on plan-time invariants only. `command = plan` only.
# No real Scaleway API calls (mock_provider). Keeps the test hermetic
# and free — the real stage requires image-builder credentials.
#
# Covers the current two-path artifact layout:
#   - local SSD images  : scaleway_instance_snapshot + scaleway_instance_image.talos
#   - block snapshot    : scaleway_block_snapshot + scaleway_instance_image.talos_block
#     (needed for GPU instances: L4, H100, etc. — they refuse local SSD)

mock_provider "scaleway" {
  mock_resource "scaleway_object_bucket" {
    defaults = {
      id = "fr-par/talos-image-test"
    }
  }

  mock_resource "scaleway_instance_ip" {
    defaults = {
      id      = "fr-par-1/11111111-1111-1111-1111-111111111111"
      address = "10.0.0.1"
    }
  }

  mock_resource "scaleway_instance_server" {
    defaults = {
      id = "fr-par-1/22222222-2222-2222-2222-222222222222"
    }
  }

  mock_resource "scaleway_instance_snapshot" {
    defaults = {
      id = "fr-par-1/33333333-3333-3333-3333-333333333333"
    }
  }

  mock_resource "scaleway_instance_image" {
    defaults = {
      id = "fr-par-1/44444444-4444-4444-4444-444444444444"
    }
  }

  mock_resource "scaleway_block_snapshot" {
    defaults = {
      id = "fr-par-1/55555555-5555-5555-5555-555555555555"
    }
  }
}

variables {
  zone               = "fr-par-1"
  region             = "fr-par"
  project_id         = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  talos_version      = "v1.12.4"
  talos_schematic_id = "18d0321d7fb289f707a76e1deeaa5c97e62209722cbf4bc533a5d51eb666885f"
  scw_access_key     = "SCWTESTTESTTESTTESTT"
  scw_secret_key     = "00000000-0000-0000-0000-000000000000"
}

# ─── S3 bucket naming ───────────────────────────────────────────────────

run "bucket_name_includes_project_id" {
  command = plan

  assert {
    condition     = scaleway_object_bucket.talos_image.name == "talos-image-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    error_message = "Bucket name must be 'talos-image-{project_id}' to ensure per-project uniqueness"
  }

  assert {
    condition     = scaleway_object_bucket.talos_image.force_destroy == true
    error_message = "Bucket must be force_destroy=true — it's a build artifact store, recreated on every image rev"
  }
}

# ─── Ephemeral builder VM ───────────────────────────────────────────────

run "builder_is_cheapest_dev_instance" {
  command = plan

  assert {
    condition     = scaleway_instance_server.builder.type == "DEV1-S"
    error_message = "Builder must be DEV1-S (cheapest tier) — it's ephemeral, no need for more"
  }

  assert {
    condition     = scaleway_instance_server.builder.image == "ubuntu_jammy"
    error_message = "Builder must use ubuntu_jammy (stock, kernel supports qemu-img)"
  }
}

run "builder_tagged_ephemeral" {
  command = plan

  assert {
    condition     = contains(scaleway_instance_server.builder.tags, "ephemeral")
    error_message = "Builder must carry 'ephemeral' tag — makes sweep/teardown scripts safe"
  }

  assert {
    condition     = contains(scaleway_instance_server.builder.tags, "builder")
    error_message = "Builder must carry 'builder' tag — filters in sweep scripts"
  }
}

# ─── Snapshots ──────────────────────────────────────────────────────────

run "snapshot_name_includes_version" {
  command = plan

  assert {
    condition     = scaleway_instance_snapshot.talos.name == "talos-v1.12.4"
    error_message = "Instance snapshot name must be 'talos-{version}'"
  }

  assert {
    condition     = scaleway_instance_snapshot.talos.type == "l_ssd"
    error_message = "Instance snapshot type must be l_ssd (DEV/GP bootable)"
  }

  assert {
    condition     = scaleway_block_snapshot.talos.name == "talos-v1.12.4-block"
    error_message = "Block snapshot name must be 'talos-{version}-block'"
  }
}

# ─── Both image variants (local SSD + block) ────────────────────────────

run "image_variants" {
  command = plan

  assert {
    condition     = scaleway_instance_image.talos.name == "talos-v1.12.4"
    error_message = "Local SSD image name must be 'talos-{version}'"
  }

  assert {
    condition     = scaleway_instance_image.talos_block.name == "talos-v1.12.4-block"
    error_message = "Block image name must be 'talos-{version}-block' (needed for GPU instances)"
  }

  assert {
    condition     = scaleway_instance_image.talos.architecture == "x86_64"
    error_message = "Image architecture must be x86_64"
  }

  assert {
    condition     = scaleway_instance_image.talos_block.architecture == "x86_64"
    error_message = "Block image architecture must be x86_64"
  }
}
