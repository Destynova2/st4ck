#cloud-config
package_update: true
packages:
  - ca-certificates
  - curl
  - git
  - jq
  - podman

ssh_authorized_keys:
  - ${ssh_public_key}

runcmd:
  - systemctl enable --now podman.socket
  - curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone --symlink-path /usr/local/bin
