mock_provider "scaleway" {
  mock_resource "scaleway_lb_ip" {
    defaults = {
      id         = "fr-par-1/11111111-1111-1111-1111-111111111111"
      ip_address = "51.159.100.1"
    }
  }

  mock_resource "scaleway_lb" {
    defaults = {
      id = "fr-par-1/22222222-2222-2222-2222-222222222222"
    }
  }

  mock_resource "scaleway_lb_backend" {
    defaults = {
      id = "fr-par-1/33333333-3333-3333-3333-333333333333"
    }
  }

  mock_resource "scaleway_lb_frontend" {
    defaults = {
      id = "fr-par-1/44444444-4444-4444-4444-444444444444"
    }
  }

  mock_resource "scaleway_instance_ip" {
    defaults = {
      id      = "fr-par-1/55555555-5555-5555-5555-555555555555"
      address = "51.159.100.10"
    }
  }

  mock_resource "scaleway_instance_server" {
    defaults = {
      id = "fr-par-1/66666666-6666-6666-6666-666666666666"
    }
  }

  mock_resource "scaleway_instance_volume" {
    defaults = {
      id = "fr-par-1/77777777-7777-7777-7777-777777777777"
    }
  }

  mock_resource "scaleway_instance_security_group" {
    defaults = {
      id = "fr-par-1/88888888-8888-8888-8888-888888888888"
    }
  }

  mock_resource "scaleway_vpc_private_network" {
    defaults = {
      id = "fr-par/99999999-9999-9999-9999-999999999999"
    }
  }

  mock_resource "scaleway_domain_record" {
    defaults = {
      id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    }
  }

  mock_data "scaleway_instance_image" {
    defaults = {
      id = "fr-par-1/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    }
  }
}

mock_provider "talos" {}

variables {
  zone               = "fr-par-1"
  region             = "fr-par"
  project_id         = "11111111-1111-1111-1111-111111111111"
  cluster_name       = "talos-test"
  talos_version      = "v1.12.4"
  kubernetes_version = "1.35.0"
  controlplane_count = 3
  worker_count       = 3
  cp_instance_type   = "DEV1-M"
  worker_instance_type = "DEV1-L"
  ephemeral_disk_size  = 25
  dns_zone           = "example.com"
  dns_subdomain      = "api.talos"
}

# ─── DNS Record (disabled by default) ────────────────────────────────────

run "dns_record_not_created_by_default" {
  command = plan

  assert {
    condition     = length(scaleway_domain_record.k8s_api) == 0
    error_message = "DNS record should not be created when enable_dns is false"
  }
}

# ─── Security Group ─────────────────────────────────────────────────────

run "security_group_defaults_to_drop" {
  command = plan

  assert {
    condition     = scaleway_instance_security_group.talos.inbound_default_policy == "drop"
    error_message = "Inbound default policy should be drop"
  }

  assert {
    condition     = scaleway_instance_security_group.talos.outbound_default_policy == "accept"
    error_message = "Outbound default policy should be accept"
  }
}

# ─── Load Balancer ───────────────────────────────────────────────────────

run "lb_is_small" {
  command = plan

  assert {
    condition     = scaleway_lb.k8s_api.type == "LB-S"
    error_message = "LB should be LB-S"
  }
}

# ─── Node Counts ────────────────────────────────────────────────────────

run "correct_node_counts" {
  command = plan

  assert {
    condition     = length(scaleway_instance_server.cp) == 3
    error_message = "Should have 3 control plane nodes"
  }

  assert {
    condition     = length(scaleway_instance_server.wrk) == 3
    error_message = "Should have 3 worker nodes"
  }
}

# ─── Instance Types ─────────────────────────────────────────────────────

run "correct_instance_types" {
  command = plan

  assert {
    condition     = alltrue([for s in scaleway_instance_server.cp : s.type == "DEV1-M"])
    error_message = "Control planes should be DEV1-M"
  }

  assert {
    condition     = alltrue([for s in scaleway_instance_server.wrk : s.type == "DEV1-L"])
    error_message = "Workers should be DEV1-L"
  }
}

# ─── Ephemeral Disks ────────────────────────────────────────────────────

run "ephemeral_disks_correct_size" {
  command = plan

  assert {
    condition     = alltrue([for v in scaleway_instance_volume.cp_ephemeral : v.size_in_gb == 25])
    error_message = "CP ephemeral disks should be 25 GiB"
  }

  assert {
    condition     = alltrue([for v in scaleway_instance_volume.wrk_ephemeral : v.size_in_gb == 25])
    error_message = "Worker ephemeral disks should be 25 GiB"
  }

  assert {
    condition     = alltrue([for v in scaleway_instance_volume.cp_ephemeral : v.type == "l_ssd"])
    error_message = "Ephemeral disks should be l_ssd"
  }
}

# ─── API Output ──────────────────────────────────────────────────────────

run "api_endpoint_uses_lb_ip_without_dns" {
  command = plan

  assert {
    condition     = output.api_endpoint == "https://51.159.100.1:6443"
    error_message = "API endpoint should use LB IP when DNS is disabled"
  }
}
