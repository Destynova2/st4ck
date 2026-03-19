# Security Model

This document explains the security architecture, threat assumptions, and policy enforcement of the Talos platform.

## Threat Model Assumptions

The platform is designed for **sovereign environments** with strong security requirements. The threat model assumes:

1. **Untrusted network**: All inter-node communication may be intercepted. Mitigated by Cilium mTLS and eBPF network policies.
2. **Compromised container images**: Any pulled image may contain vulnerabilities. Mitigated by Trivy scanning, Cosign signature verification, and Harbor as a controlled registry.
3. **Lateral movement after pod compromise**: An attacker who gains code execution in a pod should not be able to escalate. Mitigated by Kyverno admission policies, Tetragon runtime enforcement, and Cilium L7 network policies.
4. **Air-gap integrity**: In air-gapped deployments, all images must be verified before transfer. Harbor mirror + Trivy scan + Cosign verification chain handles this.
5. **Secrets leakage**: No secret should exist in Git, on disk in plaintext, or in environment variables at rest. Mitigated by `random_id` generation + encrypted Terraform state via OpenBao Transit.

## Immutable OS (Talos Linux)

Talos Linux provides the first layer of defense:

- **No SSH**: There is no SSH daemon. Node access is via `talosctl` only.
- **No shell**: There is no shell (`/bin/sh`, `/bin/bash`). Processes cannot spawn arbitrary commands.
- **No systemd**: System services are managed by machined, not systemd.
- **Read-only root filesystem**: The root filesystem is immutable. Only `/var` and `/etc` are writable, and only by the Talos API.
- **Minimal attack surface**: No package manager, no user accounts, no cron.

This is why Trivy's node-collector is disabled (ADR-011) -- there is nothing to scan on the host.

## PKI Trust Chain

```
Root CA (EC P-256, 10 years, offline in kms-output/)
  |
  +-- Intermediate CA (signed by Root, injected into cluster)
       |
       +-- cert-manager ClusterIssuer "internal-ca"
            |
            +-- Hydra TLS certificate
            +-- Internal service certificates
```

- The Root CA private key exists only in `kms-output/` (local, gitignored). It never enters the cluster.
- The Intermediate CA is injected via Terraform `kubernetes_secret` into the `secrets` namespace.
- cert-manager issues leaf certificates automatically via the `internal-ca` ClusterIssuer.
- Certificate rotation is handled by cert-manager (default: 90-day leaf certs).

## Secrets Management

### Generation

All secrets are auto-generated at deploy time:

- `random_id.*.hex` (64 chars): tokens, passwords, RPC secrets
- `random_id.*.b64_std` (base64, 32 bytes): Pomerium shared/cookie secrets (strict 32 bytes required)
- No manual `secret.tfvars` for application secrets

### Storage

```
OpenTofu random_id -> Terraform state -> vault-backend -> OpenBao KV v2
                                                           (Transit encryption: aes256-gcm96)
                                                           (Raft at-rest encryption)
```

Secrets are never written to disk in plaintext. They exist only in:
1. Encrypted Terraform state (in OpenBao KV v2)
2. Kubernetes Secrets (after injection via `templatefile()` -> Helm values)

### Day-2 (ESO)

After initial deployment, External Secrets Operator can sync from in-cluster OpenBao:

```
OpenBao KV v2 -> ESO ClusterSecretStore -> ExternalSecret -> K8s Secret
```

## Network Security (Cilium)

Cilium provides multi-layer network security:

| Layer | Feature | Configuration |
|-------|---------|---------------|
| L3/L4 | Network Policies | CiliumNetworkPolicy CRDs |
| L7 | HTTP/gRPC-aware policies | Protocol parsing in eBPF |
| Encryption | mTLS between pods | Transparent, no sidecars |
| DNS | DNS-aware policies | Block/allow by FQDN |
| Observability | Hubble flow logs | All traffic logged |

`kubeProxyReplacement: true` means kube-proxy is completely replaced by Cilium's eBPF datapath, removing iptables from the networking stack.

## Admission Policies (Kyverno)

Kyverno enforces policies at admission time:

| Policy | Type | Mode | Description |
|--------|------|------|-------------|
| Cosign verifyImages | ClusterPolicy | Audit | Verify image signatures (ready for Enforce) |
| Pod Security Standards | ClusterPolicy | Baseline/Restricted | Prevent privileged pods, host networking |

`failurePolicy: Ignore` is set to prevent Kyverno webhook failures from blocking the entire cluster. This is intentional: in a bootstrap scenario, Kyverno must not block its own deployment.

**Important**: Kyverno webhooks persist after pod deletion. The `k8s-down` target deletes webhooks first to prevent them from blocking resource cleanup.

## Runtime Security (Tetragon)

Tetragon provides eBPF-based runtime security:

- **Process monitoring**: Tracks all process executions in pods
- **Network monitoring**: Tracks all network connections
- **File monitoring**: Tracks filesystem access patterns
- **Enforcement**: Can kill processes or block syscalls in real-time

Talos-specific: Tetragon requires `extraHostPathMounts` for `/sys/kernel/tracing` (tracefs) because Talos mounts it at a non-standard location (ADR-018).

## Image Security (Trivy + Cosign + Harbor)

The image security chain:

```
Build image -> Push to Harbor -> Trivy scans automatically -> Sign with Cosign
                                                                    |
Pull from Harbor -> Kyverno verifyImages (Cosign signature check) -> Allow/Deny
```

- **Trivy Operator** runs in standalone mode. Node-collector is disabled (Talos is already hardened).
- **Cosign** signature verification via Kyverno ClusterPolicy (currently in audit mode).
- **Harbor** acts as the single registry, with S3 backend on Garage.

## OpenBao (In-Cluster)

Two separate OpenBao instances run in the cluster:

| Instance | Namespace | Purpose |
|----------|-----------|---------|
| openbao-infra | secrets | PKI intermediate CA, Transit engine, SSH CA, infrastructure secrets |
| openbao-app | secrets | Application secrets (Gate 2+) |

Both use **standalone mode with static seal** (self-init). The seal key is stored as a Kubernetes secret, auto-generated during bootstrap.

Engines on openbao-infra:
- `transit/`: Encrypts Terraform state (aes256-gcm96 key "state-encryption")
- `ssh-client-signer/`: SSH CA for certificate signing (Flux, operators)
- Kubernetes auth: pods authenticate via ServiceAccount

## OIDC Integration

```
User -> Pomerium (zero-trust proxy) -> Hydra (OIDC provider) -> Kratos (identity)
                                            |
                                    K8s apiServer (OIDC auth)
```

- Hydra issues OIDC tokens
- K8s apiServer is patched (via `talosctl`) to accept Hydra as an OIDC provider
- Pomerium acts as a reverse proxy, enforcing authentication before forwarding to services

## Relevant ADRs

| ADR | Decision |
|-----|----------|
| [ADR-001](../adr/001-cilium-cni.md) | Cilium over Flannel (eBPF, L7 policies, mTLS) |
| [ADR-007](../adr/007-openbao-secrets-manager.md) | OpenBao over Vault BSL (Apache 2.0) |
| [ADR-008](../adr/008-random-id-secrets.md) | Auto-generated secrets via random_id |
| [ADR-009](../adr/009-state-backend-openbao.md) | HTTP state backend via OpenBao KV v2 |
| [ADR-011](../adr/011-trivy-node-collector-disabled.md) | Trivy node-collector disabled for Talos |
| [ADR-018](../adr/018-tetragon-over-falco.md) | Tetragon over Falco (eBPF, Cilium alignment) |
