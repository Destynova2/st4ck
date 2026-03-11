# ADR-012 : Garage post-deploy via K8s Job au lieu de local-exec

**Date** : 2026-03-11
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

Apres le deploy Helm de Garage, un setup post-deploy est necessaire :
1. Configurer le layout du cluster (assigner les noeuds)
2. Creer les buckets (velero-backups, harbor-registry)
3. Creer les API keys et les secrets K8s correspondants

Initialement, cela etait fait via un script `scripts/garage-setup.sh` execute par `terraform_data` + `local-exec provisioner`.

## Problemes

1. **Capture stdout** : `kubectl run --rm -i` melange stdout/stderr, le message "pod deleted" pollue le JSON de reponse des API calls.
2. **Garage v2.2+ redacte les secrets** : la CLI ne retourne plus les secret keys, il faut passer par l'admin API HTTP.
3. **Port-forward implicite** : le script tourne en local et doit acceder a l'API admin Garage dans le cluster.
4. **Non-idempotent** : `local-exec` re-execute a chaque apply si le trigger change.
5. **Lent** : spawn d'un pod curl temporaire pour chaque appel API.

## Decision

Remplacer par un **`kubernetes_job_v1`** Terraform qui tourne directement dans le cluster :

```hcl
resource "kubernetes_job_v1" "garage_setup" {
  spec {
    template {
      spec {
        service_account_name = "garage-setup"
        container {
          image   = "alpine:3.21"
          command = ["/bin/sh", "-c"]
          args    = [<<-SCRIPT
            apk add --no-cache curl jq
            # ... appels directs a l'API admin Garage
          SCRIPT]
        }
      }
    }
  }
}
```

Avec RBAC dedie :
- `ServiceAccount` garage-setup (namespace garage)
- `Role` + `RoleBinding` dans namespace storage (pour creer les secrets)

## Consequences

### Positives

- **In-cluster** : pas de port-forward, appels API directs (DNS cluster)
- **Idempotent** : verifie l'existence avant de creer (buckets, keys, secrets)
- **Rapide** : un seul pod, pas de spawn intermediaire
- **RBAC least-privilege** : le Job ne peut creer des secrets que dans le namespace storage
- **wait_for_completion** : Terraform attend la fin du Job avant de deployer Velero/Harbor

### Negatives

- Script shell embarque dans le HCL (moins lisible)
- Le Job reste dans l'historique K8s (cleanup manuel ou TTL)
