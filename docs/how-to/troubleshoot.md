# How to Troubleshoot

## Symptom / Cause / Fix

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pods stuck in `ContainerCreating` | Cilium CNI not ready | `make k8s-cni-apply` must complete first |
| `k8s-pki-apply` fails: file not found | `kms-output/` missing | Run `make bootstrap && make bootstrap-export` (needs podman) |
| `tofu init` fails: connection refused | vault-backend not running | `make bootstrap` or `podman pod start platform` |
| Kyverno webhooks block deletions | Webhooks persist after pods gone | `make k8s-down` handles this (deletes webhooks first) |
| OpenBao returns `sealed` | Standalone mode, not initialized | `make openbao-init` (after k8s-pki-apply) |
| `k8s-storage-init` fails | Garage Helm chart not fetched | Auto-handled: depends on `garage-chart` target |
| Port-forward zombie processes | Previous session not cleaned | `pkill -f 'kubectl port-forward'` (included in k8s-down) |
| Hydra TLS cert not issued | ClusterIssuer not ready | k8s-pki must be applied before k8s-identity |
| Flux not reconciling | GitRepository secret missing | Check `flux-git-credentials` in flux-system namespace |
| ESO ExternalSecret stuck | ClusterSecretStore not ready | Check openbao-infra-token secret in external-secrets namespace |

## How to check stack health

### Local KMS (vault-backend + OpenBao)

```bash
# vault-backend accessible?
curl -s http://localhost:8080/state/k8s-cni | head -c 100

# OpenBao healthy?
curl -s http://localhost:8200/v1/sys/health | jq .
```

### Cilium

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-agent
```

### OpenBao (in-cluster)

```bash
kubectl -n secrets exec openbao-infra-0 -- bao status
kubectl -n secrets exec openbao-app-0 -- bao status
```

### Flux

```bash
kubectl -n flux-system get kustomizations
kubectl -n flux-system get helmreleases -A
```

### ESO (External Secrets)

```bash
kubectl get externalsecrets -A
kubectl get clustersecretstores
```

### Garage S3

```bash
kubectl -n garage exec garage-0 -- /garage status
```

### All stacks (quick check)

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
```

### Backup validation

```bash
make velero-test                # End-to-end backup/restore test
make state-snapshot             # Raft snapshot (DR backup)
```

## How to restart the local KMS

If the platform pod stopped (e.g., after a reboot):

```bash
podman pod start platform
```

If it needs to be recreated:

```bash
make bootstrap
```

## How to force-destroy a stuck deployment

If `make scaleway-down` hangs or fails:

```bash
# Remove webhooks manually
KUBECONFIG=~/.kube/talos-scaleway kubectl delete mutatingwebhookconfiguration -l app.kubernetes.io/instance=kyverno --ignore-not-found
KUBECONFIG=~/.kube/talos-scaleway kubectl delete validatingwebhookconfiguration -l app.kubernetes.io/instance=kyverno --ignore-not-found

# Kill port-forwards
pkill -f 'kubectl port-forward'

# Destroy in reverse order, ignoring errors
make k8s-storage-destroy || true
make k8s-security-destroy || true
make k8s-identity-destroy || true
make k8s-pki-destroy || true
make k8s-monitoring-destroy || true
make k8s-cni-destroy || true
make scaleway-destroy
```
