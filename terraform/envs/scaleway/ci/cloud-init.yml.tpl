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
