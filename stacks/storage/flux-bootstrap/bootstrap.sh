#!/usr/bin/env bash
set -euo pipefail
umask 077

garage() { kubectl -n garage exec garage-0 -c garage -- /garage "$@"; }

# Readiness depends on the layout; wait for RPC membership first.
ready=0
for ((attempt=0; attempt<240; attempt++)); do
  if status=$(garage status); then
    count=$(printf '%s\n' "$status" | awk '/^[a-f0-9]{16}/ { n++ } END { print n+0 }')
    if [ "$count" -eq 3 ]; then ready=1; break; fi
  fi
  sleep 5
done
[ "$ready" -eq 1 ] || { echo 'Garage RPC membership timeout' >&2; exit 1; }

nodes=$(printf '%s\n' "$status" | awk '/NO ROLE/ { print $1 }')
if [ -n "$nodes" ]; then
  # Initial installation only. Day-2 topology changes require a reviewed layout.
  layout=$(garage layout show)
  version=$(printf '%s\n' "$layout" | awk '/[Ll]ayout version/ { print $NF; exit }')
  [ "$version" = 0 ] || { echo 'Unassigned nodes in an existing layout: review required' >&2; exit 1; }
  for node in $nodes; do garage layout assign -z dc1 -c 5G "$node"; done
  garage layout apply --version 1
fi
kubectl -n garage wait pod -l app.kubernetes.io/name=garage --for=condition=Ready --timeout=300s

# Only storage owns these source Secrets. Consumers use namespace-scoped ESO.
for entry in velero-key:velero-backups:velero-s3-credentials:ini \
             zot-key:zot-registry:zot-s3-credentials:plain \
             cnpg-key:cnpg-backups:cnpg-s3-credentials:plain; do
  IFS=: read -r key bucket name format <<< "$entry"
  if ! garage bucket info "$bucket" >/dev/null; then
    garage bucket create "$bucket"
  fi
  if ! garage key info "$key" >/dev/null; then
    garage key create "$key" >/dev/null
  fi
  garage bucket allow --read --write --owner "$bucket" --key "$key"
  info=$(garage key info --show-secret "$key")
  access=$(printf '%s\n' "$info" | awk '/^Key ID:/ { print $NF }')
  secret=$(printf '%s\n' "$info" | awk '/^Secret key:/ { print $NF }')
  [[ "$access" =~ ^GK[0-9a-f]{24}$ && "$secret" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Invalid Garage credentials for $key" >&2; exit 1;
  }
  # Avoid putting credentials in process arguments or kubectl's last-applied annotation.
  export GARAGE_ACCESS="$access" GARAGE_SECRET="$secret"
  jq -n --arg name "$name" --arg format "$format" '{
    apiVersion: "v1", kind: "Secret", metadata: {name: $name, namespace: "storage"},
    type: "Opaque", stringData: (if $format == "ini" then
      {cloud: ("[default]\naws_access_key_id=" + env.GARAGE_ACCESS +
        "\naws_secret_access_key=" + env.GARAGE_SECRET + "\n")}
      else {access_key: env.GARAGE_ACCESS, secret_key: env.GARAGE_SECRET} end)
  }' | kubectl apply --server-side --field-manager=garage-bootstrap -f - >/dev/null
  unset GARAGE_ACCESS GARAGE_SECRET
done
