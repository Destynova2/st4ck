#cloud-config
package_update: true
packages:
  - wget
  - qemu-utils
  - zstd
  - s3cmd

write_files:
  - path: /root/.s3cfg
    permissions: "0600"
    content: |
      [default]
      access_key = ${access_key}
      secret_key = ${secret_key}
      host_base = s3.${region}.scw.cloud
      host_bucket = %(bucket)s.s3.${region}.scw.cloud
      use_https = True
  - path: /usr/local/sbin/build-talos-image
    permissions: "0700"
    content: |
      #!/bin/bash
      set -euo pipefail
      umask 077
      workdir="$(mktemp -d "$${TMPDIR:-/var/tmp}/talos-image.XXXXXX")"
      trap 'rm -rf "$workdir"' EXIT

      # Bind completion to this VM, including retries of the same recipe.
      instance_id="$(cloud-init query v1.instance_id)"
      if [[ ! "$instance_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo "ERROR: cloud-init did not provide a Scaleway instance UUID" >&2
        exit 1
      fi

      echo "=== Downloading Talos ${talos_version} ==="
      wget -q --timeout=60 --tries=3 "https://factory.talos.dev/image/${schematic_id}/${talos_version}/scaleway-amd64.raw.zst" -O "$workdir/scaleway-amd64.raw.zst"
      test -s "$workdir/scaleway-amd64.raw.zst"
      zstd --decompress "$workdir/scaleway-amd64.raw.zst" -o "$workdir/scaleway-amd64.raw"
      test -s "$workdir/scaleway-amd64.raw"
      rm -f "$workdir/scaleway-amd64.raw.zst"
      qemu-img convert -f raw -O qcow2 "$workdir/scaleway-amd64.raw" "$workdir/scaleway-amd64.qcow2"
      test -s "$workdir/scaleway-amd64.qcow2"
      qemu-img check -f qcow2 "$workdir/scaleway-amd64.qcow2"
      rm -f "$workdir/scaleway-amd64.raw"

      echo "=== Uploading to S3 bucket ${bucket_name} ==="
      s3cmd put --acl-private "$workdir/scaleway-amd64.qcow2" "s3://${bucket_name}/${artifact_key}"
      printf '%s\n' '${artifact_key}' > "$workdir/.upload-complete"
      s3cmd put --acl-public "$workdir/.upload-complete" "s3://${bucket_name}/${artifact_prefix}/builders/$instance_id/.upload-complete"
      echo "=== Image ready ==="

runcmd:
  - [bash, /usr/local/sbin/build-talos-image]
