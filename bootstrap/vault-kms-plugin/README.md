# vault-kms-plugin — OpenBao Transit KMS for Kubernetes

OCI image that wraps [`bank-vaults/vault-kms-plugin`](https://github.com/bank-vaults/vault-kms-plugin) — a KMS v2 plugin for kube-apiserver backed by OpenBao Transit.

## Role

Injected as a **sidecar** next to every Kamaji-hosted tenant apiserver. The apiserver reads a `EncryptionConfiguration` that points at a UDS socket served by this plugin:

```
apiserver pod
  ├── kube-apiserver container (reads /etc/enc/config.yaml)
  │     └── EncryptionConfiguration { kms: openbao-transit, endpoint: unix:///run/kms/socket }
  └── vault-kms-plugin sidecar (serves /run/kms/socket)
        └── OpenBao Transit (KEK: transit/keys/tenant-<name>)
```

Every Secret write is encrypted with a per-Secret DEK, wrapped by the tenant's KEK in OpenBao. Key rotation is automatic (OpenBao Transit keeps old key versions; the plugin decrypts with the right version on read).

## Build

Build via Makefile target (parallel with vault-backend):

```bash
podman build -t localhost/vault-kms-plugin:<commit> bootstrap/vault-kms-plugin/
```

A pinned commit (not `main`) is used in production — update the `VAULT_KMS_PLUGIN_COMMIT` build-arg as upstream evolves.

## Runtime config

The sidecar reads these env vars:

| Var | Example | Purpose |
|---|---|---|
| `VAULT_ADDR` | `https://openbao-infra.pki.svc:8200` | OpenBao endpoint |
| `VAULT_TRANSIT_KEY` | `tenant-alice` | Per-tenant KEK name |
| `VAULT_TRANSIT_MOUNT` | `transit` | Transit engine mount path |
| `VAULT_AUTH_METHOD` | `approle` | AppRole auth against OpenBao |
| `VAULT_APPROLE_ROLE_ID_FILE` | `/vault/secrets/role-id` | File mount (managed by ESO) |
| `VAULT_APPROLE_SECRET_ID_FILE` | `/vault/secrets/secret-id` | File mount (managed by ESO) |
| `KMS_SOCKET` | `/run/kms/socket` | UDS path exposed to apiserver |

## Permissions (OpenBao policy)

Each tenant gets its own AppRole with a narrow policy:

```hcl
# kamaji-kms-tenant-<name>
path "transit/encrypt/tenant-<name>"  { capabilities = ["update"] }
path "transit/decrypt/tenant-<name>"  { capabilities = ["update"] }
path "transit/rewrap/tenant-<name>"   { capabilities = ["update"] }
```

No `read` on the key metadata, no cross-tenant access, no admin sudo.

## References

- [Kubernetes KMS v2 encryption](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- [bank-vaults/vault-kms-plugin](https://github.com/bank-vaults/vault-kms-plugin)
- [OpenBao Transit engine](https://openbao.org/docs/secrets/transit/)
- ADR-025 §3.3 — Encryption at rest
