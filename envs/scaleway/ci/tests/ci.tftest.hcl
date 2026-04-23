# Plan-time tests for the Scaleway CI VM stage.
#
# Scope: assert on plan-time invariants only. `command = plan` only.
# No real Scaleway API calls (mock_provider). Keeps the test hermetic
# and free — the real stage runs a remote-exec provisioner that only
# makes sense against a live VM.
#
# SSH key fixtures live in ./fixtures — file() reads them at plan time
# (used by the null_resource.ci_bootstrap connection block and the
# resource "scaleway_instance_server" user_data template).

mock_provider "scaleway" {
  mock_resource "scaleway_instance_security_group" {
    defaults = {
      id = "fr-par-1/11111111-1111-1111-1111-111111111111"
    }
  }

  mock_resource "scaleway_instance_ip" {
    defaults = {
      id      = "fr-par-1/22222222-2222-2222-2222-222222222222"
      address = "10.0.0.1"
    }
  }

  mock_resource "scaleway_instance_server" {
    defaults = {
      id = "fr-par-1/33333333-3333-3333-3333-333333333333"
    }
  }
}

mock_provider "random" {}

variables {
  project_id             = "11111111-1111-1111-1111-111111111111"
  management_cidrs       = ["203.0.113.1/32"]
  ssh_public_key_path    = "./tests/fixtures/id_test.pub"
  ssh_private_key_path   = "./tests/fixtures/id_test"
  scw_project_id         = "11111111-1111-1111-1111-111111111111"
  scw_image_access_key   = "SCWTEST0000000000000"
  scw_image_secret_key   = "00000000-0000-0000-0000-000000000000"
  scw_cluster_access_key = "SCWTEST0000000000001"
  scw_cluster_secret_key = "00000000-0000-0000-0000-000000000001"
}

# ─── CI VM defaults ─────────────────────────────────────────────────────

run "ci_vm_defaults" {
  command = plan

  assert {
    condition     = scaleway_instance_server.ci.name == "woodpecker-ci"
    error_message = "Default VM name must be 'woodpecker-ci'"
  }

  assert {
    condition     = scaleway_instance_server.ci.type == "DEV1-M"
    error_message = "Default instance type must be DEV1-M"
  }

  assert {
    condition     = scaleway_instance_server.ci.image == "ubuntu_noble"
    error_message = "CI VM must use ubuntu_noble (stock, kernel supports podman rootless)"
  }

  assert {
    condition     = contains(scaleway_instance_server.ci.tags, "ci")
    error_message = "CI VM must carry 'ci' tag"
  }

  assert {
    condition     = contains(scaleway_instance_server.ci.tags, "woodpecker")
    error_message = "CI VM must carry 'woodpecker' tag"
  }

  assert {
    condition     = contains(scaleway_instance_server.ci.tags, "gitea")
    error_message = "CI VM must carry 'gitea' tag"
  }
}

# ─── Security group — deny by default ───────────────────────────────────

run "security_group_deny_by_default" {
  command = plan

  assert {
    condition     = scaleway_instance_security_group.ci.inbound_default_policy == "drop"
    error_message = "Default inbound policy must be 'drop' (deny-by-default)"
  }

  assert {
    condition     = scaleway_instance_security_group.ci.outbound_default_policy == "accept"
    error_message = "Default outbound policy must be 'accept' (VM needs to pull packages/images)"
  }
}

run "management_cidrs_generate_four_rules" {
  command = plan

  # Ports opened: 22 (SSH), 2222 (Gitea SSH), 3000 (Gitea UI), 8000 (Woodpecker UI).
  # One rule per port per CIDR → 4 rules for 1 CIDR.
  assert {
    condition     = length(scaleway_instance_security_group.ci.inbound_rule) == 4
    error_message = "Must emit one inbound rule per (port × CIDR) — 4 ports × 1 CIDR = 4 rules"
  }
}

# ─── Generated secrets ──────────────────────────────────────────────────

run "gitea_admin_password_generated" {
  command = plan

  assert {
    condition     = random_password.gitea_admin.length == 24
    error_message = "Gitea admin password must be 24 characters"
  }

  assert {
    condition     = random_password.gitea_admin.special == false
    error_message = "Gitea admin password must be shell-safe (no special chars)"
  }
}
