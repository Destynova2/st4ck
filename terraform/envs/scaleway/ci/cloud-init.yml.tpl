#cloud-config
package_update: true
packages:
  - ca-certificates
  - curl
  - gnupg
  - git
  - jq

write_files:
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
      docker compose exec -T gitea gitea admin user create \
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

      echo "=== Writing .env ==="
      cat > /opt/woodpecker/.env <<-DOTENV
      GITEA_URL=$$GITEA_URL
      GITEA_DOMAIN=${public_ip}
      GITEA_ADMIN_USER=$$GITEA_ADMIN
      WOODPECKER_HOST=$$WOODPECKER_HOST
      WOODPECKER_GITEA_CLIENT=$$CLIENT_ID
      WOODPECKER_GITEA_SECRET=$$CLIENT_SECRET
      WOODPECKER_AGENT_SECRET=$$AGENT_SECRET
      DOTENV

      echo "=== Starting Woodpecker ==="
      docker compose up -d woodpecker-server woodpecker-agent

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
  # ─── Install Docker ──────────────────────────────────────────────────
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - echo "deb [arch=$$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $$( . /etc/os-release && echo $$VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # ─── Clone infra repo ────────────────────────────────────────────────
  - git clone ${git_repo_url} /opt/talos

  # ─── Prepare and start Gitea first ──────────────────────────────────
  - mkdir -p /opt/woodpecker/gitea-data /opt/woodpecker/woodpecker-data
  - cp /opt/talos/configs/woodpecker/docker-compose.yml /opt/woodpecker/
  - touch /opt/woodpecker/.env
  - cd /opt/woodpecker && docker compose up -d gitea

  # ─── Run setup script (creates admin, OAuth, pushes repo, injects secrets) ──
  - cd /opt/woodpecker && bash /opt/woodpecker/setup.sh
