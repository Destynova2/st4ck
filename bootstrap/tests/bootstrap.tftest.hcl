mock_provider "random" {}
mock_provider "local" {}

run "self_contained_pod_manifest" {
  command = plan

  variables {
    source_dir     = "/tmp/st4ck-bootstrap-render"
    admin_password = "bootstrap-\"quotes\"-\\slashes\nline-two: #yaml"
  }

  assert {
    condition = alltrue([
      yamldecode(split("\n---\n", local.configmap_yaml)[1]).kind == "Secret",
      yamldecode(split("\n---\n", local.configmap_yaml)[0]).metadata.name == "platform-config",
      strcontains(local_file.pod.content, "kind: Pod"),
      strcontains(local_file.pod.content, "claimName: platform-tofu-state"),
    ])
    error_message = "Podman must receive configuration, secrets, state volume and pod together."
  }

  assert {
    condition     = local_file.pod.file_permission == "0600" && local_file.configmap.file_permission == "0600"
    error_message = "Generated bootstrap manifests contain secrets and must not be world-readable."
  }

  assert {
    condition     = yamldecode(split("\n---\n", local.configmap_yaml)[1]).stringData.CI_PASSWORD == var.admin_password
    error_message = "Arbitrary password characters must survive YAML encoding unchanged."
  }

  assert {
    condition = alltrue([
      local_file.pod.directory_permission == "0700",
      local_file.configmap.directory_permission == "0700",
      terraform_data.platform_pod.triggers_replace[1] == sha256(local.pod_yaml),
      terraform_data.platform_pod.triggers_replace[2] == local.setup_source_sha,
      terraform_data.platform_pod.triggers_replace[3] == filesha256("../scripts/bootstrap-preflight.py"),
    ])
    error_message = "Bootstrap must protect artifact directories and replace on template/source/guard changes."
  }
}
