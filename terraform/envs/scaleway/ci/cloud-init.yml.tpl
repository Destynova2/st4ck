#cloud-config
package_update: true
packages:
  - ca-certificates
  - curl
  - git
  - jq
  - podman

write_files:
  - path: /etc/containers/systemd/ci.kube
    permissions: "0644"
    content: |
      [Unit]
      Description=CI Pod (Gitea + Woodpecker)
      After=network-online.target
      Wants=network-online.target

      [Kube]
      Yaml=/opt/woodpecker/ci-pod.yaml

      [Install]
      WantedBy=multi-user.target

  - path: /opt/woodpecker/setup.sh
    permissions: "0755"
    content: |
      #!/bin/bash
      set -euo pipefail
      set -a && . /opt/woodpecker/secrets.env && set +a

      GITEA_URL="http://${public_ip}:3000"
      WOODPECKER_HOST="http://${public_ip}:8000"
      GITEA_ADMIN="${gitea_admin_user}"
      GITEA_PASSWORD="${gitea_admin_password}"
      AGENT_SECRET=$$(openssl rand -hex 32)

      echo "=== Waiting for Gitea to be ready ==="
      for i in $$(seq 1 60); do
        curl -sf "$$GITEA_URL/api/v1/version" && break
        sleep 5
      done

      echo "=== Creating Gitea admin user ==="
      podman exec ci-gitea gitea admin user create \
        --admin --username "$$GITEA_ADMIN" \
        --password "$$GITEA_PASSWORD" \
        --email "${gitea_admin_email}" \
        --must-change-password=false || true

      echo "=== Creating OAuth app for Woodpecker ==="
      OAUTH_RESPONSE=$$(curl -sf -X POST "$$GITEA_URL/api/v1/user/applications/oauth2" \
        -u "$$GITEA_ADMIN:$$GITEA_PASSWORD" \
        -H "Content-Type: application/json" \
        -d "{
          \"name\": \"woodpecker\",
          \"redirect_uris\": [\"$$WOODPECKER_HOST/authorize\"]
        }")

      CLIENT_ID=$$(echo "$$OAUTH_RESPONSE" | jq -r '.client_id')
      CLIENT_SECRET=$$(echo "$$OAUTH_RESPONSE" | jq -r '.client_secret')

      echo "=== Restarting pod with real env vars ==="
      systemctl stop ci

      sed -i \
        -e "s|PLACEHOLDER_GITEA_URL|$$GITEA_URL|g" \
        -e "s|PLACEHOLDER_DOMAIN|${public_ip}|g" \
        -e "s|PLACEHOLDER_WP_HOST|$$WOODPECKER_HOST|g" \
        -e "s|PLACEHOLDER_ADMIN|$$GITEA_ADMIN|g" \
        -e "s|PLACEHOLDER_CLIENT|$$CLIENT_ID|g" \
        -e "s|PLACEHOLDER_SECRET|$$CLIENT_SECRET|g" \
        -e "s|PLACEHOLDER_AGENT_SECRET|$$AGENT_SECRET|g" \
        /opt/woodpecker/ci-pod.yaml

      systemctl daemon-reload
      systemctl start ci

      echo "=== Waiting for Woodpecker to be ready ==="
      for i in $$(seq 1 30); do
        curl -sf "$$WOODPECKER_HOST/api/version" && break
        sleep 5
      done

      echo "=== Getting Woodpecker API token ==="
      WP_TOKEN=$$(curl -sf -X POST "$$WOODPECKER_HOST/api/user/token" \
        -H "Content-Type: application/json" \
        -u "$$GITEA_ADMIN:$$GITEA_PASSWORD" | jq -r '.')

      echo "=== Injecting Scaleway secrets into Woodpecker ==="
      for SECRET_NAME in scw_project_id scw_image_access_key scw_image_secret_key scw_cluster_access_key scw_cluster_secret_key; do
        eval SECRET_VALUE="\$$$$SECRET_NAME"
        curl -sf -X POST "$$WOODPECKER_HOST/api/secrets" \
          -H "Authorization: Bearer $$WP_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"name\": \"$$SECRET_NAME\", \"value\": \"$$SECRET_VALUE\", \"event\": [\"push\"]}"
      done

      echo "=== Cloning and pushing repo to Gitea ==="
      cd /tmp
      git clone --bare ${git_repo_url} talos.git

      curl -sf -X POST "$$GITEA_URL/api/v1/user/repos" \
        -u "$$GITEA_ADMIN:$$GITEA_PASSWORD" \
        -H "Content-Type: application/json" \
        -d '{"name": "talos", "description": "Talos Linux platform", "private": false}'

      cd talos.git
      git push --mirror "http://$$GITEA_ADMIN:$$GITEA_PASSWORD@${public_ip}:3000/$$GITEA_ADMIN/talos.git"

      echo "=== Activating repo in Woodpecker ==="
      curl -sf -X POST "$$WOODPECKER_HOST/api/repos" \
        -H "Authorization: Bearer $$WP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"id\": 0, \"full_name\": \"$$GITEA_ADMIN/talos\"}" || true

      echo "=== Done ==="

  - path: /opt/woodpecker/secrets.env
    permissions: "0600"
    content: |
      scw_project_id=${scw_project_id}
      scw_image_access_key=${scw_image_access_key}
      scw_image_secret_key=${scw_image_secret_key}
      scw_cluster_access_key=${scw_cluster_access_key}
      scw_cluster_secret_key=${scw_cluster_secret_key}

runcmd:
  # ─── Enable Podman socket (for Woodpecker agent) ───────────────────
  - systemctl enable --now podman.socket

  # ─── Clone infra repo ──────────────────────────────────────────────
  - git clone ${git_repo_url} /opt/talos

  # ─── Prepare pod manifest ──────────────────────────────────────────
  - mkdir -p /opt/woodpecker/gitea-data /opt/woodpecker/woodpecker-data
  - cp /opt/talos/configs/woodpecker/ci-pod.yaml /opt/woodpecker/ci-pod.yaml
  - sed -i "s|PLACEHOLDER_GITEA_URL|http://${public_ip}:3000|g; s|PLACEHOLDER_DOMAIN|${public_ip}|g" /opt/woodpecker/ci-pod.yaml

  # ─── Start CI pod via systemd (Quadlet) ────────────────────────────
  - systemctl daemon-reload
  - systemctl enable --now ci

  # ─── Run setup (admin, OAuth, restart with real env, push repo) ────
  - bash /opt/woodpecker/setup.sh
