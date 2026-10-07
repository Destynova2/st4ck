variables {
  enabled        = true
  machine_config = "machine:\n  type: worker\ncluster:\n  clusterName: test\n"
}

run "shared_vm_em_contract" {
  command = apply
  assert {
    condition     = jsonencode(yamldecode(output.machine_config).machine.kubelet.extraConfig) == jsonencode(jsondecode(file("../../../../karpenter-provider-scaleway/pkg/cloudprovider/testdata/bootstrap-extra.json")))
    error_message = "EM differs from the VM bootstrap/resource contract."
  }
}

run "preserve_unrelated_configuration" {
  command = plan
  variables {
    machine_config = "machine:\n  type: worker\n  kubelet:\n    extraArgs: {rotate-server-certificates: 'true'}\n    extraConfig:\n      registerWithTaints: [{key: dedicated, value: elastic, effect: NoSchedule}]\ncluster:\n  clusterName: test\n"
  }
  assert {
    condition     = length(yamldecode(output.machine_config).machine.kubelet.extraConfig.registerWithTaints) == 2 && yamldecode(output.machine_config).machine.kubelet.extraArgs.rotate-server-certificates == "true" && yamldecode(output.machine_config).cluster.clusterName == "test"
    error_message = "Normalization lost unrelated bootstrap fields."
  }
}

run "idempotent" {
  command = plan
  variables {
    machine_config = yamlencode({ machine = { type = "worker", kubelet = { extraConfig = jsondecode(file("../../../../karpenter-provider-scaleway/pkg/cloudprovider/testdata/bootstrap-extra.json")) } } })
  }
  assert {
    condition     = output.machine_config == var.machine_config
    error_message = "Normalizing a compliant bootstrap must be idempotent."
  }
}

run "unmanaged_unchanged" {
  command = plan
  variables {
    enabled        = false
    machine_config = "unchanged even if not YAML"
  }
  assert {
    condition     = output.machine_config == "unchanged even if not YAML"
    error_message = "Non-Karpenter bootstrap changed."
  }
}

run "reject_controlplane" {
  command = plan
  variables { machine_config = "machine: {type: controlplane}" }
  expect_failures = [output.machine_config]
}

run "reject_conflicting_taint" {
  command = plan
  variables { machine_config = "machine: {type: worker, kubelet: {extraConfig: {registerWithTaints: [{key: karpenter.sh/unregistered, effect: NoSchedule}]}}}" }
  expect_failures = [output.machine_config]
}

run "reject_resource_override" {
  command = plan
  variables { machine_config = "machine: {type: worker, kubelet: {extraConfig: {systemReserved: {memory: 2Gi}}}}" }
  expect_failures = [output.machine_config]
}

run "reject_flag_override" {
  command = plan
  variables { machine_config = "machine: {type: worker, kubelet: {extraArgs: {register-with-taints: 'other:NoSchedule'}}}" }
  expect_failures = [output.machine_config]
}

run "reject_eviction_override" {
  command = plan
  variables { machine_config = "machine: {type: worker, kubelet: {extraConfig: {evictionHard: {memory.available: 2Gi}}}}" }
  expect_failures = [output.machine_config]
}

run "reject_multiple_documents" {
  command = plan
  variables { machine_config = "machine: {type: worker}\n---\nkind: VolumeConfig\nname: EPHEMERAL\n" }
  expect_failures = [output.machine_config]
}
