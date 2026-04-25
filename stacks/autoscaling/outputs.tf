output "namespace" {
  description = "Namespace hosting all autoscaling components"
  value       = kubernetes_namespace.autoscaling.metadata[0].name
}

output "karpenter_version" {
  description = "Deployed Karpenter core version"
  value       = helm_release.karpenter.version
}

output "karpenter_capi_provider_version" {
  description = "Deployed Karpenter Cluster-API provider version (experimental)"
  value       = helm_release.karpenter_capi_provider.version
}

output "prometheus_adapter_version" {
  description = "Deployed prometheus-adapter version"
  value       = helm_release.prometheus_adapter.version
}

output "vpa_version" {
  description = "Deployed vertical-pod-autoscaler version"
  value       = helm_release.vpa.version
}

output "keda_version" {
  description = "Deployed KEDA version"
  value       = helm_release.keda.version
}

output "helper_text" {
  description = "Useful post-deploy helper text for operators"
  value       = <<-EOT
    Autoscaling stack deployed.

    Components:
      - Karpenter core                         (v${helm_release.karpenter.version})
      - Karpenter CAPI provider (EXPERIMENTAL) (v${helm_release.karpenter_capi_provider.version})
      - prometheus-adapter                     (v${helm_release.prometheus_adapter.version})
      - vertical-pod-autoscaler (updateMode=Auto by default) (v${helm_release.vpa.version})
      - KEDA                                   (v${helm_release.keda.version})

    NodePool templates (NOT applied — rendered per tenant by
    stacks/managed-cluster):
      - templates/nodepool-example.yaml        (general, weight 50)
      - templates/nodepool-burst.yaml          (burstable, weight 60)
      - templates/nodepool-compute.yaml        (compute, weight 40)
      - templates/nodepool-memory.yaml         (memory,  weight 40)
      - templates/nodepool-gpu-l4.yaml         (gpu L4,  weight 10)
      - templates/nodepool-gpu-h100.yaml       (gpu H100,weight 10)

    HPA custom metrics:
      Verify with:
        kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | jq .

    VPA override per workload (takes precedence over global Auto):
      spec.updatePolicy.updateMode: "Off" | "Initial" | "Auto" | "Recreate"
  EOT
}
