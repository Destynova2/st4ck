#!/usr/bin/env bash
# Validate Velero backup/restore on a live cluster.
# Usage: KUBECONFIG=~/.kube/talos-scaleway ./scripts/velero-test.sh
set -euo pipefail

NS="velero-test"
TS=$(date +%s)
BACKUP_NAME="test-backup-${TS}"
RESTORE_NAME="test-restore-${TS}"

echo "=== Velero Backup/Restore Test ==="

# ─── 1. Create test namespace with sample resources ───────────────────
echo "1. Creating test namespace and resources..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap test-data -n "$NS" \
  --from-literal=key1=value1 --from-literal=key2=value2 \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create deployment nginx-test -n "$NS" \
  --image=nginx:alpine --replicas=1 \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl wait --for=condition=available deployment/nginx-test -n "$NS" --timeout=120s
echo "   Resources created."

# ─── 2. Create Velero backup ─────────────────────────────────────────
echo "2. Creating Velero backup '${BACKUP_NAME}'..."
cat <<YAML | kubectl apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: storage
spec:
  includedNamespaces:
    - ${NS}
  storageLocation: default
  ttl: 1h0m0s
YAML

echo "   Waiting for backup to complete..."
for i in $(seq 1 60); do
  PHASE=$(kubectl get backup "$BACKUP_NAME" -n storage -o jsonpath='{.status.phase}' 2>/dev/null || echo "New")
  case "$PHASE" in
    Completed) break ;;
    Failed|PartiallyFailed)
      echo "ERROR: Backup failed (phase: $PHASE)"
      kubectl describe backup "$BACKUP_NAME" -n storage
      exit 1 ;;
  esac
  printf "   attempt %d/60 (phase: %s)...\r" "$i" "$PHASE"
  sleep 3
done
echo ""

if [ "$PHASE" != "Completed" ]; then
  echo "ERROR: Backup timed out (phase: $PHASE)"
  exit 1
fi
echo "   Backup completed."

# ─── 3. Delete the test namespace ────────────────────────────────────
echo "3. Deleting test namespace..."
kubectl delete namespace "$NS" --wait=true --timeout=120s
echo "   Namespace deleted."

# ─── 4. Restore from backup ─────────────────────────────────────────
echo "4. Restoring from backup '${BACKUP_NAME}'..."
cat <<YAML | kubectl apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${RESTORE_NAME}
  namespace: storage
spec:
  backupName: ${BACKUP_NAME}
  includedNamespaces:
    - ${NS}
YAML

echo "   Waiting for restore to complete..."
for i in $(seq 1 60); do
  PHASE=$(kubectl get restore "$RESTORE_NAME" -n storage -o jsonpath='{.status.phase}' 2>/dev/null || echo "New")
  case "$PHASE" in
    Completed) break ;;
    Failed|PartiallyFailed)
      echo "ERROR: Restore failed (phase: $PHASE)"
      kubectl describe restore "$RESTORE_NAME" -n storage
      exit 1 ;;
  esac
  printf "   attempt %d/60 (phase: %s)...\r" "$i" "$PHASE"
  sleep 3
done
echo ""

if [ "$PHASE" != "Completed" ]; then
  echo "ERROR: Restore timed out (phase: $PHASE)"
  exit 1
fi
echo "   Restore completed."

# ─── 5. Verify restored resources ───────────────────────────────────
echo "5. Verifying restored resources..."
VALUE=$(kubectl get configmap test-data -n "$NS" -o jsonpath='{.data.key1}')
if [ "$VALUE" != "value1" ]; then
  echo "ERROR: ConfigMap data mismatch: expected 'value1', got '$VALUE'"
  exit 1
fi
kubectl get deployment nginx-test -n "$NS" > /dev/null
echo "   ConfigMap data OK, Deployment restored."

# ─── 6. Cleanup ─────────────────────────────────────────────────────
echo "6. Cleaning up..."
kubectl delete namespace "$NS" --wait=false 2>/dev/null || true
kubectl delete backup "$BACKUP_NAME" -n storage 2>/dev/null || true
kubectl delete restore "$RESTORE_NAME" -n storage 2>/dev/null || true

echo ""
echo "=== Velero Backup/Restore Test PASSED ==="
