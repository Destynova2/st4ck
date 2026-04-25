variable "kubeconfig_path" {
  description = "Path to kubeconfig file for the management cluster"
  type        = string
}

# ─── Gateway API upstream CRDs ────────────────────────────────────────
# Pinned to a kubernetes-sigs/gateway-api release tag. The `standard`
# channel bundle ships the stable v1 GA resources (GatewayClass, Gateway,
# HTTPRoute) plus the `experimental` TLSRoute we need for SNI passthrough
# (see gateway_api_channel).

variable "gateway_api_version" {
  description = "kubernetes-sigs/gateway-api release tag (CRDs)"
  type        = string
  default     = "v1.2.0"
}

variable "gateway_api_channel" {
  description = <<-EOT
    CRD channel — either "standard" (GA resources only) or "experimental"
    (includes TLSRoute). TLSRoute is still experimental in v1.2.x so we
    default to the experimental bundle.
  EOT
  type        = string
  default     = "experimental"

  validation {
    condition     = contains(["standard", "experimental"], var.gateway_api_channel)
    error_message = "gateway_api_channel must be either \"standard\" or \"experimental\"."
  }
}

# ─── Gateway resource ─────────────────────────────────────────────────

variable "gateway_name" {
  description = "Name of the shared tenant Gateway"
  type        = string
  default     = "tenant-api-gw"
}

variable "gateway_namespace" {
  description = "Namespace hosting the shared tenant Gateway (Kamaji system NS)"
  type        = string
  default     = "kamaji-system"
}

variable "gateway_class_name" {
  description = "Name of the Cilium GatewayClass (configured in stacks/cni)"
  type        = string
  default     = "cilium"
}

# ─── DNS / routing ────────────────────────────────────────────────────

variable "base_domain" {
  description = <<-EOT
    Base DNS domain — per-tenant apiserver hostnames will be formed as
    "<tenant>-api.<base_domain>". Used only in the TLSRoute template
    rendered by stacks/managed-cluster.
  EOT
  type        = string
  default     = "st4ck.local"
}

# ─── Scaleway LoadBalancer tuning ─────────────────────────────────────
# Reference: scaleway/scaleway-cloud-controller-manager annotations.
#   service.beta.kubernetes.io/scaleway-loadbalancer-type: LB-S | LB-M | LB-L | LB-XL | LB-GP-*

variable "loadbalancer_type" {
  description = "Scaleway LoadBalancer offer type (LB-S, LB-M, LB-L, LB-XL, ...)"
  type        = string
  default     = "LB-S"
}

variable "loadbalancer_extra_annotations" {
  description = <<-EOT
    Extra annotations to surface on the Service that Cilium materialises
    from this Gateway (via spec.infrastructure.annotations). Useful for
    further Scaleway tuning (proxy-protocol, zone, reserved IP, ...).
  EOT
  type        = map(string)
  default     = {}
}
