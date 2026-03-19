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
  - |
    curl -fsSL -o /tmp/tofu.deb "https://github.com/opentofu/opentofu/releases/download/v1.9.0/tofu_1.9.0_amd64.deb"
    dpkg -i /tmp/tofu.deb && rm /tmp/tofu.deb
