# Offline tests for the Scaleway Talos image build stage.
#
# Applies below use only mock_provider and the built-in terraform_data.
# No real Scaleway API calls. Keeps the test hermetic
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

run "bucket_name_follows_naming_convention" {
  command = plan

  assert {
    condition     = scaleway_object_bucket.talos_image.name == "st4ck-talos-image-fr-par-18d0321"
    error_message = "Bucket name must be '{namespace}-talos-image-{region}-{schematic7}' (see locals.bucket_name)"
  }

  assert {
    condition     = scaleway_object_bucket.talos_image.force_destroy == true
    error_message = "Bucket must be force_destroy=true — it is an ephemeral artifact store"
  }
}

run "targeted_builder_contract" {
  command = apply

  plan_options {
    target = [scaleway_instance_server.builder]
  }

  assert {
    condition     = output.image_build.bucket == scaleway_object_bucket.talos_image.name && output.image_build.region == var.region
    error_message = "The upload contract must be available after phase 1 without importing snapshots."
  }

  assert {
    condition     = output.image_build.marker_key == "${local.artifact_prefix}/builders/22222222-2222-2222-2222-222222222222/.upload-complete"
    error_message = "The marker must identify the current builder UUID, not a previous attempt."
  }
}

run "baseline" {
  command = apply

  assert {
    condition = (
      scaleway_instance_snapshot.talos.import[0].key == output.image_build.artifact_key &&
      scaleway_block_snapshot.talos.import[0].key == output.image_build.artifact_key &&
      startswith(output.image_build.artifact_key, "talos/${var.talos_version}/${var.talos_schematic_id}/") &&
      endswith(output.image_build.artifact_key, "/scaleway-amd64.qcow2")
    )
    error_message = "Both snapshot variants must import the same full-versioned artifact."
  }

  assert {
    condition     = output.image_build.marker_url == "https://${output.image_build.bucket}.s3.fr-par.scw.cloud/${output.image_build.marker_key}"
    error_message = "The polling URL must use the bucket, region and current marker from the build contract."
  }
}

run "unchanged_inputs" {
  command = plan
}

run "version_change" {
  command = plan

  variables {
    talos_version = "v1.12.5"
  }

  assert {
    condition = (
      startswith(scaleway_instance_snapshot.talos.import[0].key, "talos/v1.12.5/") &&
      startswith(scaleway_block_snapshot.talos.import[0].key, "talos/v1.12.5/")
    )
    error_message = "A Talos version change must change both import keys, not just image names."
  }
}

run "schematic_change_same_short_prefix" {
  command = plan

  variables {
    talos_schematic_id = "18d0321d7fb289f707a76e1deeaa5c97e62209722cbf4bc533a5d51eb6668850"
  }

  assert {
    condition = (
      scaleway_object_bucket.talos_image.name == "st4ck-talos-image-fr-par-18d0321" &&
      startswith(scaleway_instance_snapshot.talos.import[0].key, "talos/v1.12.4/${var.talos_schematic_id}/") &&
      scaleway_block_snapshot.talos.import[0].key == scaleway_instance_snapshot.talos.import[0].key
    )
    error_message = "A schematic change beyond the first seven characters must still rebuild the artifact."
  }
}

run "credential_rotation" {
  command = plan

  variables {
    scw_secret_key = "11111111-1111-1111-1111-111111111111"
  }
}

run "owner_tag_change" {
  command = plan

  variables {
    owner = "image-review"
  }
}

run "invalid_version" {
  command = plan

  variables {
    talos_version = "v1.12.9/../../other"
  }

  expect_failures = [var.talos_version]
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

run "builder_tagged_by_convention" {
  command = plan

  assert {
    condition     = contains(scaleway_instance_server.builder.tags, "component:talos-image")
    error_message = "Builder must carry 'component:talos-image' tag (base_tags convention)"
  }

  assert {
    condition     = contains(scaleway_instance_server.builder.tags, "managed-by:opentofu")
    error_message = "Builder must carry 'managed-by:opentofu' tag (base_tags convention)"
  }
}

# ─── Snapshots ──────────────────────────────────────────────────────────

run "snapshot_name_includes_version" {
  command = plan

  assert {
    condition     = scaleway_instance_snapshot.talos.name == "st4ck-talos-v1.12.4-18d0321"
    error_message = "Instance snapshot name must be '{namespace}-talos-{version}-{schematic7}' (locals.image_base)"
  }

  assert {
    condition     = scaleway_instance_snapshot.talos.type == "l_ssd"
    error_message = "Instance snapshot type must be l_ssd (DEV/GP bootable)"
  }

  assert {
    condition     = scaleway_block_snapshot.talos.name == "st4ck-talos-v1.12.4-18d0321-block"
    error_message = "Block snapshot name must be '{image_base}-block'"
  }
}

# ─── Both image variants (local SSD + block) ────────────────────────────

run "image_variants" {
  command = plan

  assert {
    condition     = scaleway_instance_image.talos.name == "st4ck-talos-v1.12.4-18d0321"
    error_message = "Local SSD image name must be '{image_base}'"
  }

  assert {
    condition     = scaleway_instance_image.talos_block.name == "st4ck-talos-v1.12.4-18d0321-block"
    error_message = "Block image name must be '{image_base}-block' (needed for GPU instances)"
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
