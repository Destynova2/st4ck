variable "enabled" {
  type    = bool
  default = false
}

variable "machine_config" {
  type      = string
  sensitive = true
}

locals {
  # Fail closed on multi-document/invalid input in this opt-in EM path.
  # VM bootstrap supports multiple documents independently.
  config  = try(yamldecode(var.enabled ? var.machine_config : "{}"), {})
  machine = try(local.config.machine, {})
  kubelet = try(local.machine.kubelet, {})
  args    = try(local.kubelet.extraArgs, {})
  extra   = try(local.kubelet.extraConfig, {})
  taints  = try(local.extra.registerWithTaints, [])
  hard = {
    "memory.available"   = "100Mi"
    "nodefs.available"   = "10%"
    "imagefs.available"  = "15%"
    "nodefs.inodesFree"  = "5%"
    "imagefs.inodesFree" = "5%"
  }
  forbidden_args = [
    "kube-reserved", "system-reserved", "reserved-cpus", "max-pods", "pods-per-core",
    "eviction-hard", "eviction-soft", "eviction-soft-grace-period", "eviction-minimum-reclaim",
    "merge-default-eviction-settings", "register-with-taints", "config", "config-dir",
  ]
  valid = !var.enabled || try(
    local.machine.type == "worker" &&
    alltrue([for key in local.forbidden_args : !contains(keys(local.args), key)]) &&
    try(local.extra.maxPods == 110, true) &&
    try(local.extra.podsPerCore == 0, true) &&
    try(local.extra.reservedSystemCPUs == "", true) &&
    try(jsonencode(local.extra.systemReserved) == "{}", true) &&
    try(jsonencode(local.extra.kubeReserved) == jsonencode({ cpu = "500m", memory = "1Gi" }), true) &&
    try(jsonencode(local.extra.evictionHard) == jsonencode(local.hard), true) &&
    try(local.extra.mergeDefaultEvictionSettings == false, true) &&
    alltrue([for key in ["evictionSoft", "evictionSoftGracePeriod", "evictionMinimumReclaim"] : try(jsonencode(local.extra[key]) == "{}", true)]) &&
    alltrue([for t in local.taints : t.key != "karpenter.sh/unregistered" || (t.effect == "NoExecute" && try(t.value == "", true))]) &&
    length([for t in local.taints : t if t.key == "karpenter.sh/unregistered"]) <= 1,
  false)
  extra_config = merge(local.extra, {
    maxPods                      = 110
    kubeReserved                 = { cpu = "500m", memory = "1Gi" }
    evictionHard                 = local.hard
    mergeDefaultEvictionSettings = false
    registerWithTaints = concat(
      try([for t in local.taints : t if t.key != "karpenter.sh/unregistered"], []),
      [{ key = "karpenter.sh/unregistered", effect = "NoExecute" }],
    )
  })
  rendered = yamlencode(merge(local.config, {
    machine = merge(local.machine, {
      kubelet = merge(local.kubelet, { extraConfig = local.extra_config })
    })
  }))
}

output "machine_config" {
  value     = var.enabled ? local.rendered : var.machine_config
  sensitive = true
  precondition {
    condition     = local.valid
    error_message = "Karpenter EM requires a single-document worker config with matching reserves/eviction thresholds and no conflicting resource flags or initial taint."
  }
}
