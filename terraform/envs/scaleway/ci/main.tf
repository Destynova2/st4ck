terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

resource "random_password" "gitea_admin" {
  length  = 24
  special = false
}

provider "scaleway" {
  zone       = var.zone
  region     = var.region
  project_id = var.project_id
}

# ─── Security Group ───────────────────────────────────────────────────

resource "scaleway_instance_security_group" "ci" {
  name                    = "${var.name}-sg"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  # Gitea UI
  inbound_rule {
    action   = "accept"
    port     = 3000
    protocol = "TCP"
  }

  # Gitea SSH
  inbound_rule {
    action   = "accept"
    port     = 2222
    protocol = "TCP"
  }

  # Woodpecker UI
  inbound_rule {
    action   = "accept"
    port     = 8000
    protocol = "TCP"
  }

  # SSH
  inbound_rule {
    action   = "accept"
    port     = 22
    protocol = "TCP"
  }
}

# ─── Flex IP ──────────────────────────────────────────────────────────

resource "scaleway_instance_ip" "ci" {}

# ─── CI VM ────────────────────────────────────────────────────────────

resource "scaleway_instance_server" "ci" {
  name  = var.name
  type  = var.instance_type
  image = "ubuntu_noble"
  ip_id = scaleway_instance_ip.ci.id

  security_group_id = scaleway_instance_security_group.ci.id

  root_volume {
    size_in_gb = var.root_disk_size
  }

  user_data = {
    cloud-init = templatefile("${path.module}/cloud-init.yml.tpl", {
      ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
    })
  }

  tags = ["ci", "woodpecker", "gitea"]
}

# ─── Provisioner: bootstrap KMS + CI on the VM ───────────────────────

resource "null_resource" "ci_bootstrap" {
  depends_on = [scaleway_instance_server.ci]

  connection {
    type        = "ssh"
    host        = scaleway_instance_ip.ci.address
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  # Wait for cloud-init to finish (packages installed)
  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait || true",
      "mkdir -p /opt/talos/configs/openbao /opt/talos/configs/woodpecker /opt/talos/scripts",
      "mkdir -p /opt/woodpecker/gitea-data /opt/woodpecker/woodpecker-data",
    ]
  }

  # Copy config files
  provisioner "file" {
    source      = "${path.module}/../../../../configs/openbao/kms-pod.yaml"
    destination = "/opt/talos/configs/openbao/kms-pod.yaml"
  }

  provisioner "file" {
    source      = "${path.module}/../../../../configs/woodpecker/ci-pod.yaml"
    destination = "/opt/talos/configs/woodpecker/ci-pod.yaml"
  }

  provisioner "file" {
    source      = "${path.module}/../../../../scripts/openbao-kms-bootstrap.sh"
    destination = "/opt/talos/scripts/openbao-kms-bootstrap.sh"
  }

  # Copy setup script (generated from template)
  provisioner "file" {
    content = templatefile("${path.module}/setup.sh.tpl", {
      public_ip            = scaleway_instance_ip.ci.address
      gitea_admin_user     = var.gitea_admin_user
      gitea_admin_password = random_password.gitea_admin.result
      gitea_admin_email    = var.gitea_admin_email
      git_repo_url         = var.git_repo_url
      scw_project_id       = var.scw_project_id
      scw_image_access_key = var.scw_image_access_key
      scw_image_secret_key = var.scw_image_secret_key
      scw_cluster_access_key = var.scw_cluster_access_key
      scw_cluster_secret_key = var.scw_cluster_secret_key
    })
    destination = "/opt/woodpecker/setup.sh"
  }

  # Run bootstrap
  provisioner "remote-exec" {
    inline = [
      "chmod +x /opt/talos/scripts/openbao-kms-bootstrap.sh /opt/woodpecker/setup.sh",

      # Start KMS pod
      "echo '=== Starting KMS pod ==='",
      "podman play kube /opt/talos/configs/openbao/kms-pod.yaml",

      # Run KMS bootstrap
      "echo '=== Running KMS bootstrap ==='",
      "bash /opt/talos/scripts/openbao-kms-bootstrap.sh /opt/talos/kms-output",

      # Prepare and start CI pod
      "echo '=== Starting CI pod ==='",
      "cp /opt/talos/configs/woodpecker/ci-pod.yaml /opt/woodpecker/ci-pod.yaml",
      "sed -i 's|PLACEHOLDER_GITEA_URL|http://${scaleway_instance_ip.ci.address}:3000|g; s|PLACEHOLDER_DOMAIN|${scaleway_instance_ip.ci.address}|g' /opt/woodpecker/ci-pod.yaml",
      "podman play kube /opt/woodpecker/ci-pod.yaml",

      # Run setup (Gitea admin, OAuth, Woodpecker secrets, push repo)
      "echo '=== Running setup ==='",
      "bash /opt/woodpecker/setup.sh",
    ]
  }
}
