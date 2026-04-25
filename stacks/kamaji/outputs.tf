output "kamaji_namespace" {
  description = "Namespace where the Kamaji operator runs"
  value       = kubernetes_namespace.kamaji.metadata[0].name
}

output "etcd_operator_namespace" {
  description = "Namespace where the Ænix etcd-operator runs"
  value       = kubernetes_namespace.etcd_operator.metadata[0].name
}

output "kamaji_version" {
  description = "Deployed Kamaji Helm chart version"
  value       = helm_release.kamaji.version
}

output "etcd_operator_version" {
  description = "Deployed Ænix etcd-operator Helm chart version"
  value       = helm_release.etcd_operator.version
}
