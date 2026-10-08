variable "openbao_bootstrap_releases" {
  description = "First-install phase only, selected by scripts/apply-pki.sh; normal Helm ownership stays at three replicas."
  type        = set(string)
  default     = []
  validation {
    condition     = length(setsubtract(var.openbao_bootstrap_releases, ["openbao-infra", "openbao-app"])) == 0
    error_message = "Only openbao-infra and openbao-app can enter bootstrap mode."
  }
}

# Read before changing Helm values: bootstrap must never downscale an HA cluster.
data "kubernetes_resources" "openbao_statefulsets" {
  for_each       = toset(["openbao-infra", "openbao-app"])
  api_version    = "apps/v1"
  kind           = "StatefulSet"
  namespace      = "secrets"
  field_selector = "metadata.name=${each.key}"
}

data "kubernetes_resources" "openbao_volumes" {
  for_each       = toset(["openbao-infra", "openbao-app"])
  api_version    = "v1"
  kind           = "PersistentVolumeClaim"
  namespace      = "secrets"
  label_selector = "app.kubernetes.io/instance=${each.key}"
}

locals {
  openbao_apply_allowed = {
    for name in ["openbao-infra", "openbao-app"] : name => (
      contains(var.openbao_bootstrap_releases, name)
      ? (try(data.kubernetes_resources.openbao_statefulsets[name].objects[0].spec.replicas, 0) <= 1 &&
        (length(data.kubernetes_resources.openbao_statefulsets[name].objects) > 0 ||
      length(data.kubernetes_resources.openbao_volumes[name].objects) == 0))
      : try(contains([1, 3], data.kubernetes_resources.openbao_statefulsets[name].objects[0].spec.replicas), false)
    )
  }
}
