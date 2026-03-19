# ADR-021 : Durcissement securite — consolidation des audits

**Date** : 2026-03-19
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

Trois audits securite independants ont ete realises sur la plateforme st4ck (Talos Linux + OpenBao + Cilium + Flux). Les constats ont ete consolides et priorises ci-dessous. La plateforme fonctionne en mode POC/dev ; ce document definit les changements concrets necessaires avant tout deploiement en environnement de production ou pre-production.

### Synthese des constats

| # | Severite | Constat | Fichier(s) |
|---|----------|---------|------------|
| 1 | CRITIQUE | Security groups ouverts 0.0.0.0/0 — etcd (2379), kubelet (10250), Cilium exposes sur internet | `envs/scaleway/main.tf:108-169` |
| 2 | CRITIQUE | emptyDir pour OpenBao Raft — perte totale du state KMS au restart podman | `bootstrap/platform-pod.yaml:326-327` |
| 3 | CRITIQUE | Cles CA + tokens ecrits en 0644 — `local_file` au lieu de `local_sensitive_file` | `bootstrap/tofu/vault.tf`, `bootstrap/tofu/pki.tf` |
| 4 | CRITIQUE | Secrets dans ConfigMap (pas Secret) — credentials Scaleway en clair | `bootstrap/main.tf:106-133`, `envs/scaleway/ci/setup.sh.tpl:13-32` |
| 5 | HAUT | `admin_password = "localpass123"` sans validation de complexite | `bootstrap/main.tf:60` |
| 6 | HAUT | TLS desactive sur OpenBao in-cluster (listener tcp tls_disable = true) | `stacks/pki/values-openbao-infra.yaml:14`, `stacks/pki/values-openbao-app.yaml` |
| 7 | HAUT | Hydra + Kratos en mode dev avec SQLite memory (perte au restart) | `stacks/identity/values-hydra.yaml:6-9`, `stacks/identity/values-kratos.yaml:5-8` |
| 8 | HAUT | Gitea registration ouverte + Woodpecker OPEN=true | `bootstrap/platform-pod.yaml:225` |
| 9 | HAUT | Token vault-backend expire apres 32j sans renouvellement automatique | `bootstrap/tofu/vault.tf:27-31` |
| 10 | HAUT | Git push avec credentials dans l'URL | `bootstrap/tofu/gitea.tf:82` |
| 11 | HAUT | VM CI ouverte sur internet sans restriction IP | `envs/scaleway/ci/main.tf:27-59` |
| 12 | MOYEN | Kyverno failurePolicy: Ignore | `stacks/security/values-kyverno.yaml:17` |
| 13 | MOYEN | Cosign en mode Audit uniquement | `stacks/security/verify-images.yaml:14` |
| 14 | MOYEN | Flux known_hosts = placeholder | `stacks/flux-bootstrap/main.tf:64` |
| 15 | MOYEN | Superuser policy path "*" sans audit logging | `stacks/pki/values-openbao-infra.yaml:97-101` |
| 16 | MOYEN | Pomerium vers Hydra en HTTP (pas HTTPS) | `stacks/identity/values-pomerium.yaml:7` |
| 17 | MOYEN | Garage provisioners non re-executables | `stacks/storage/` |

---

## Decisions

### P0 — Critiques (avant tout deploiement non-local)

#### 1. Restreindre les security groups Scaleway aux CIDRs du VPC

**Probleme** : Les regles inbound n'ont pas de champ `ip_range`, donc etcd (2379), kubelet (10250), Cilium health/VXLAN (4240/8472) et Hubble (4244) sont ouverts a 0.0.0.0/0.

**Changement** (`envs/scaleway/main.tf`) :

```hcl
# Separer en deux security groups :
# 1. sg-public : seuls les ports API publics (6443, 50000) restent ouverts
# 2. sg-internal : tous les ports cluster restreints au CIDR du private network

resource "scaleway_instance_security_group" "public" {
  name                    = "${var.cluster_name}-sg-public"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  # Talos API — restreindre a l'IP de management si possible
  inbound_rule {
    action   = "accept"
    port     = 50000
    protocol = "TCP"
    ip_range = var.management_cidr  # nouvelle variable
  }

  # Kubernetes API (via LB, pas directement)
  inbound_rule {
    action   = "accept"
    port     = 6443
    protocol = "TCP"
  }
}

resource "scaleway_instance_security_group" "internal" {
  name                    = "${var.cluster_name}-sg-internal"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  # etcd, kubelet, Cilium, Hubble — VPC uniquement
  dynamic "inbound_rule" {
    for_each = [2379, 2380, 10250, 4240, 4244]
    content {
      action   = "accept"
      port     = inbound_rule.value
      protocol = "TCP"
      ip_range = scaleway_vpc_private_network.talos.ipv4_subnet[0].subnet
    }
  }

  inbound_rule {
    action   = "accept"
    port     = 8472
    protocol = "UDP"
    ip_range = scaleway_vpc_private_network.talos.ipv4_subnet[0].subnet
  }
}
```

**Effort** : 2h | **Priorite** : P0

---

#### 2. Remplacer emptyDir par un PVC pour OpenBao Raft

**Probleme** : `bao-data` utilise `emptyDir: {}`. Si le pod podman redemarre, toutes les cles de chiffrement, tokens et states Terraform sont perdus definitivement.

**Changement** (`bootstrap/platform-pod.yaml`) :

```yaml
# Remplacer :
#   - name: bao-data
#     emptyDir: {}
# Par :
  - name: bao-data
    persistentVolumeClaim:
      claimName: platform-bao-data
```

Ajouter le PVC dans `bootstrap/main.tf` (meme pattern que `platform-gitea-data`).

**Effort** : 30min | **Priorite** : P0

---

#### 3. Migrer local_file vers local_sensitive_file pour les secrets

**Probleme** : `local_file` ecrit en 0644 et affiche le contenu dans les logs Terraform. Les cles CA privees, tokens AppRole, et tokens vault-backend sont concernes.

**Changement** (`bootstrap/tofu/vault.tf`) :

```hcl
# Remplacer CHAQUE local_file contenant un secret par :
resource "local_sensitive_file" "approle_role_id" {
  content         = data.vault_approle_auth_backend_role_id.vault_backend.role_id
  filename        = "${var.output_dir}/approle-role-id.txt"
  file_permission = "0600"
}

resource "local_sensitive_file" "approle_secret_id" {
  content         = vault_approle_auth_backend_role_secret_id.vault_backend.secret_id
  filename        = "${var.output_dir}/approle-secret-id.txt"
  file_permission = "0600"
}

resource "local_sensitive_file" "vault_backend_token" {
  content         = vault_token.vault_backend.client_token
  filename        = "${var.output_dir}/vault-backend-token.txt"
  file_permission = "0600"
}

resource "local_sensitive_file" "transit_token" {
  content         = vault_token.autounseal.client_token
  filename        = "${var.output_dir}/transit-token.txt"
  file_permission = "0600"
}
```

**Changement** (`bootstrap/tofu/pki.tf`) — meme migration pour :
- `local_file.infra_ca_key` (cle privee CA infra)
- `local_file.app_ca_key` (cle privee CA app)

Les certificats publics (root-ca.pem, infra-ca.pem, chains) peuvent rester en `local_file`.

**Effort** : 1h | **Priorite** : P0

---

#### 4. Migrer les secrets du ConfigMap vers un Secret Kubernetes

**Probleme** : `CI_PASSWORD`, `CI_AGENT_SECRET`, `CI_SCW_IMAGE_SECRET_KEY`, `CI_SCW_CLUSTER_SECRET_KEY` sont dans un ConfigMap en clair. Les ConfigMaps ne sont pas chiffres au repos et sont visibles par tout utilisateur ayant `get configmaps`.

**Changement** (`bootstrap/main.tf`) — separer en deux objets :

```hcl
locals {
  # ConfigMap : donnees non-sensibles uniquement
  configmap_yaml = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: platform-config
    data:
      CI_GITEA_URL: "${var.gitea_url}"
      CI_OAUTH_URL: "${var.oauth_url}"
      CI_DOMAIN: "${var.domain}"
      CI_WP_HOST: "${var.wp_host}"
      CI_ADMIN: "${var.admin_user}"
      CI_GIT_REPO_URL: "${var.git_repo_url}"
      CI_SCW_PROJECT_ID: "${var.scw_project_id}"
  YAML

  # Secret : donnees sensibles
  secret_yaml = <<-YAML
    apiVersion: v1
    kind: Secret
    metadata:
      name: platform-secrets
    type: Opaque
    stringData:
      CI_PASSWORD: "${var.admin_password}"
      CI_AGENT_SECRET: "${random_password.agent_secret.result}"
      CI_SCW_IMAGE_ACCESS_KEY: "${var.scw_image_access_key}"
      CI_SCW_IMAGE_SECRET_KEY: "${var.scw_image_secret_key}"
      CI_SCW_CLUSTER_ACCESS_KEY: "${var.scw_cluster_access_key}"
      CI_SCW_CLUSTER_SECRET_KEY: "${var.scw_cluster_secret_key}"
  YAML
}
```

Adapter `platform-pod.yaml` : remplacer `configMapKeyRef` par `secretKeyRef` pour les champs sensibles.

Appliquer la meme separation dans `envs/scaleway/ci/setup.sh.tpl`.

**Effort** : 2h | **Priorite** : P0

---

### P1 — Hauts (avant pre-production)

#### 5. Valider la complexite du mot de passe admin

**Changement** (`bootstrap/main.tf`) :

```hcl
variable "admin_password" {
  description = "Admin password for Gitea and Woodpecker"
  type        = string
  sensitive   = true
  # Supprimer le default "localpass123"

  validation {
    condition     = length(var.admin_password) >= 16
    error_message = "admin_password doit contenir au moins 16 caracteres."
  }
}
```

Fournir le mot de passe via `TF_VAR_admin_password` ou un fichier `.auto.tfvars` ignore par git.

**Effort** : 30min | **Priorite** : P1

---

#### 6. Activer TLS sur OpenBao in-cluster

**Changement** (`stacks/pki/values-openbao-infra.yaml`, `values-openbao-app.yaml`) :

```hcl
listener "tcp" {
  tls_disable     = false
  address         = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_cert_file   = "/openbao/tls/tls.crt"
  tls_key_file    = "/openbao/tls/tls.key"
}
```

Utiliser un `Certificate` cert-manager signe par le `ClusterIssuer "internal-ca"`, monte via `extraVolumes` dans le chart Helm.

**Effort** : 3h | **Priorite** : P1

---

#### 7. Remplacer SQLite memory par PostgreSQL pour Hydra et Kratos

**Changement** :

- Deployer un PostgreSQL (via chart Bitnami ou CloudNativePG) dans le namespace `identity`
- `values-hydra.yaml` : `dsn: "postgres://..."` au lieu de `"memory"`, `dev: false`
- `values-kratos.yaml` : `dsn: "postgres://..."` au lieu de `"memory"`, `development: false`
- Generer les credentials PostgreSQL via `random_password` dans `stacks/identity/main.tf`

**Effort** : 4h | **Priorite** : P1

---

#### 8. Desactiver l'inscription ouverte Gitea et Woodpecker

**Changement** (`bootstrap/platform-pod.yaml`) :

```yaml
# Gitea : ajouter
- name: GITEA__service__DISABLE_REGISTRATION
  value: "true"

# Woodpecker : changer
- name: WOODPECKER_OPEN
  value: "false"
```

L'admin est deja cree par le provisioner Terraform (`gitea.tf`). L'inscription publique n'est plus necessaire apres le bootstrap.

Note : `DISABLE_REGISTRATION` doit etre mis apres le premier `tofu apply` (qui cree l'admin). Ajouter un second `terraform_data` provisioner qui ferme l'inscription via l'API Gitea apres creation de l'admin.

**Effort** : 1h | **Priorite** : P1

---

#### 9. Renouvellement automatique du token vault-backend

**Probleme** : `period = "768h"` (32 jours). Si le bootstrap n'est pas relance, le token expire et toutes les operations `tofu` echouent.

**Changement** — deux options :

**Option A** (recommandee) : Passer a l'authentification AppRole dans vault-backend au lieu d'un token statique. Les role_id/secret_id sont deja generes (`vault.tf`). vault-backend supporte l'auth AppRole nativement.

**Option B** : Ajouter un cron systemd/podman qui renouvelle le token :
```bash
curl -s -X POST -H "X-Vault-Token: $(cat /kms-output/vault-backend-token.txt)" \
  http://127.0.0.1:8200/v1/auth/token/renew-self
```

**Effort** : 2h (option A) / 1h (option B) | **Priorite** : P1

---

#### 10. Supprimer les credentials de l'URL git push

**Probleme** : `git remote add gitea "http://${var.ci_admin}:${var.ci_password}@..."` expose le mot de passe dans les logs git, l'historique shell, et `/proc`.

**Changement** (`bootstrap/tofu/gitea.tf`) :

```bash
# Utiliser git credential helper au lieu de l'URL
git -c credential.helper='!f() { echo "username=${var.ci_admin}"; echo "password=${var.ci_password}"; }; f' \
  push gitea main --force
```

Ou mieux : generer un token API Gitea avec le provisioner et utiliser `Authorization: token <TOKEN>` via `http.extraHeader`.

**Effort** : 1h | **Priorite** : P1

---

#### 11. Restreindre la VM CI aux IPs de management

**Changement** (`envs/scaleway/ci/main.tf`) :

```hcl
variable "management_cidrs" {
  description = "CIDRs autorises a acceder a la VM CI"
  type        = list(string)
}

resource "scaleway_instance_security_group" "ci" {
  # ...
  dynamic "inbound_rule" {
    for_each = var.management_cidrs
    content {
      action   = "accept"
      port     = 22
      protocol = "TCP"
      ip_range = inbound_rule.value
    }
  }

  # Gitea/WP : accessible uniquement depuis le cluster
  # Supprimer les regles 3000, 8000 du SG public
  # Utiliser un tunnel SSH ou wireguard pour l'acces admin
}
```

**Effort** : 1h | **Priorite** : P1

---

### P2 — Moyens (amelioration continue)

#### 12. Kyverno failurePolicy: Fail

**Changement** (`stacks/security/values-kyverno.yaml`) :

```yaml
admissionController:
  failurePolicy: Fail
```

Prerequis : valider que toutes les policies Kyverno existantes sont stables et ne bloquent pas les workloads legitimes. Tester en mode `Audit` pendant 2 semaines avant de passer en `Fail`.

**Effort** : 2h (tests inclus) | **Priorite** : P2

---

#### 13. Cosign : passer de Audit a Enforce

**Changement** (`stacks/security/verify-images.yaml`, `stacks/security/flux/cosign-policy.yaml`) :

```yaml
validationFailureAction: Enforce
```

Prerequis : signer toutes les images avec Cosign via le pipeline Woodpecker, configurer la cle publique dans la ClusterPolicy.

**Effort** : 4h (pipeline signing + tests) | **Priorite** : P2

---

#### 14. Flux known_hosts : cle reelle

**Changement** (`stacks/flux-bootstrap/main.tf`) :

Remplacer le placeholder par la recuperation dynamique de la cle SSH Gitea :

```hcl
variable "gitea_known_hosts" {
  description = "SSH known_hosts for Gitea (ssh-keyscan output)"
  type        = string
  # Plus de valeur par defaut placeholder
}
```

Generer automatiquement via un `terraform_data` provisioner :
```bash
ssh-keyscan -p 2222 -t ed25519 ${gitea_host} 2>/dev/null
```

**Effort** : 1h | **Priorite** : P2

---

#### 15. Audit logging sur la policy superuser

**Changement** (`stacks/pki/values-openbao-infra.yaml`) — activer l'audit log OpenBao :

```hcl
initialize "audit" {
  request "enable-file-audit" {
    operation = "update"
    path      = "sys/audit/file"
    data = {
      type = "file"
      options = {
        file_path = "/openbao/audit/audit.log"
      }
    }
  }
}
```

Monter un volume pour `/openbao/audit/` et integrer les logs dans VictoriaLogs.

**Effort** : 2h | **Priorite** : P2

---

#### 16. Pomerium vers Hydra en HTTPS

**Changement** (`stacks/identity/values-pomerium.yaml`) :

```yaml
authenticate:
  idp:
    providerUrl: https://hydra-public.identity.svc:4444/
```

Prerequis : le constat #6 (TLS OpenBao) et un `Certificate` cert-manager pour Hydra doivent etre deployes. La CA interne doit etre injectee dans le trust store Pomerium.

**Effort** : 1h (apres #6) | **Priorite** : P2

---

#### 17. Garage provisioners idempotents

**Probleme** : les provisioners `local-exec` pour Garage (creation de buckets, tokens) echouent si relances.

**Changement** : utiliser des scripts idempotents avec verification d'existence :

```bash
# Avant creation
garage bucket list | grep -q "^$BUCKET_NAME$" || garage bucket create "$BUCKET_NAME"
```

Ou migrer vers un provider Terraform Garage si disponible.

**Effort** : 2h | **Priorite** : P2

---

## Resume des efforts

| Priorite | Nombre | Effort total estime |
|----------|--------|---------------------|
| P0 (critique) | 4 constats | ~5h30 |
| P1 (haut) | 7 constats | ~12h30 |
| P2 (moyen) | 6 constats | ~12h |
| **Total** | **17 constats** | **~30h** |

## Consequences

### Positives

- Surface d'attaque reduite significativement (ports cluster non exposes sur internet)
- Secrets proteges au repos et en transit (Secret K8s, local_sensitive_file, TLS)
- Pas de credentials par defaut ni de credentials dans les URLs
- Pipeline de durcissement progressif (P0 -> P1 -> P2) compatible avec les sprints
- Chaque changement est retrocompatible — pas de rupture d'architecture

### Negatives

- Complexite accrue du bootstrap (Secret K8s separe du ConfigMap, PVC supplementaire)
- PostgreSQL pour Hydra/Kratos ajoute un composant a operer
- Le passage Kyverno `Fail` + Cosign `Enforce` peut bloquer des deployments en cas de regression
- TLS intra-cluster ajoute une charge de gestion de certificats (mais cert-manager la simplifie)
- Certains changements P1 (token renewal, AppRole) necessitent un re-bootstrap
