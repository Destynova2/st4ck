#cloud-config
package_update: true
packages:
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

runcmd:
  - echo "=== Downloading Talos ${talos_version} ==="
  - wget -q "https://factory.talos.dev/image/${schematic_id}/${talos_version}/scaleway-amd64.raw.zst" -O /tmp/scaleway-amd64.raw.zst
  - echo "=== Decompressing ==="
  - zstd --decompress /tmp/scaleway-amd64.raw.zst -o /tmp/scaleway-amd64.raw
  - rm -f /tmp/scaleway-amd64.raw.zst
  - echo "=== Converting to QCOW2 ==="
  - qemu-img convert -O qcow2 /tmp/scaleway-amd64.raw /tmp/scaleway-amd64.qcow2
  - rm -f /tmp/scaleway-amd64.raw
  - echo "=== Uploading to S3 bucket ${bucket_name} ==="
  - s3cmd put /tmp/scaleway-amd64.qcow2 s3://${bucket_name}/scaleway-amd64.qcow2
  - echo "done" > /tmp/.upload-complete
  - s3cmd put --acl-public /tmp/.upload-complete s3://${bucket_name}/.upload-complete
  - rm -f /tmp/scaleway-amd64.qcow2 /tmp/.upload-complete
  - echo "=== Image ready ==="
