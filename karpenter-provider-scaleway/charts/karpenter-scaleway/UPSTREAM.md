# Embedded CRDs

`karpenter.sh_*` and `autoscaling.x-k8s.io_*` are copied unchanged from
`sigs.k8s.io/karpenter@v1.14.0/pkg/apis/crds`. Apache-2.0 license is in
`LICENSE.karpenter`. Keep this version aligned with `go.mod` and the platform
version registry. Core CRDs are cluster-wide: never install this chart alongside
an unrelated Karpenter controller.

`karpenter.scaleway.st4ck.io_*` are copied from this provider's `config/crd`.
`make crds` synchronizes both sources; repository tests detect provider CRD drift.
