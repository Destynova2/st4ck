mock_provider "scaleway" {
  mock_resource "scaleway_instance_ip" {
    defaults = {
      id      = "11111111-1111-1111-1111-111111111111"
      address = "10.0.0.1"
    }
  }

  mock_resource "scaleway_instance_server" {
    defaults = {
      id = "22222222-2222-2222-2222-222222222222"
    }
  }

  mock_resource "scaleway_instance_snapshot" {
    defaults = {
      id = "33333333-3333-3333-3333-333333333333"
    }
  }

  mock_resource "scaleway_instance_image" {
    defaults = {
      id = "44444444-4444-4444-4444-444444444444"
    }
  }
}

variables {
  zone               = "fr-par-1"
  region             = "fr-par"
  project_id         = "11111111-1111-1111-1111-111111111111"
  talos_version      = "v1.12.4"
  talos_schematic_id = "18d0321d7fb289f707a76e1deeaa5c97e62209722cbf4bc533a5d51eb666885f"
  scw_access_key     = "SCW00000000000000000"
  scw_secret_key     = "00000000-0000-0000-0000-000000000000"
}

# ─── Bucket ──────────────────────────────────────────────────────────────

run "bucket_name_includes_region" {
  command = plan

  assert {
    condition     = scaleway_object_bucket.talos_image.name == "talos-image-fr-par"
    error_message = "Bucket name should include region"
  }
}

# ─── Builder VM ──────────────────────────────────────────────────────────

run "builder_is_dev1_s" {
  command = plan

  assert {
    condition     = scaleway_instance_server.builder.type == "DEV1-S"
    error_message = "Builder should be DEV1-S (cheapest)"
  }

  assert {
    condition     = scaleway_instance_server.builder.image == "ubuntu_jammy"
    error_message = "Builder should use Ubuntu Jammy"
  }
}

run "builder_has_tags" {
  command = plan

  assert {
    condition     = contains(scaleway_instance_server.builder.tags, "ephemeral")
    error_message = "Builder should be tagged as ephemeral"
  }
}

# ─── Snapshot ────────────────────────────────────────────────────────────

run "snapshot_name_includes_version" {
  command = plan

  assert {
    condition     = scaleway_instance_snapshot.talos.name == "talos-v1.12.4"
    error_message = "Snapshot name should include Talos version"
  }

  assert {
    condition     = scaleway_instance_snapshot.talos.type == "l_ssd"
    error_message = "Snapshot type should be l_ssd"
  }
}

# ─── Image ───────────────────────────────────────────────────────────────

run "image_name_includes_version" {
  command = plan

  assert {
    condition     = scaleway_instance_image.talos.name == "talos-v1.12.4"
    error_message = "Image name should include Talos version"
  }

  assert {
    condition     = scaleway_instance_image.talos.architecture == "x86_64"
    error_message = "Image architecture should be x86_64"
  }
}
