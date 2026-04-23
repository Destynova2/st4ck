# ADR-026 : OpenBao static seal — accepted risk (Gate 1/2)

**Date** : 2026-04-23
**Statut** : Accepte (tracked drift)
**Decideurs** : Equipe plateforme
**Relies a** : ADR-007 (OpenBao secrets manager), ADR-009 (state backend OpenBao), ADR-021 (security hardening)

## Contexte

Le stack `stacks/pki/` deploie OpenBao (Infra + App) en cluster avec un unseal
automatique. Deux strategies sont possibles :

1. **Seal KMS-wrap** : cle de seal chiffree par un KMS externe (Scaleway KMS,
   AWS KMS, GCP KMS). L'operateur delegue la custody de la racine.
2. **Static seal** : cle de 32 octets generee par `random_bytes` Terraform,
   stockee dans un K8s Secret (`secrets/openbao-seal-key`), lue par OpenBao
   au demarrage via `seal "static"` (file-backed mount).

Le code actuel implemente la strategie **2 (static seal)** :

```hcl
# stacks/pki/main.tf
resource "random_bytes" "openbao_seal_key" {
  length = 32
}

resource "kubernetes_secret" "openbao_seal_key" {
  metadata { name = "openbao-seal-key"; namespace = "secrets" }
  data     = { key = random_bytes.openbao_seal_key.hex }
}
```

La cle vit en clair dans l'etat OpenTofu (chiffre par Transit OpenBao une fois
le cluster-0 bootstrap) et dans le K8s Secret (chiffre at-rest par etcd si
Talos EncryptionConfig est active, sinon en clair dans etcd).

## Analyse (revues pass1 + pass2)

- `docs/reviews/2026-04-22-cycle-pass1.md` (#5) : "OpenBao seal key not
  KMS-wrapped". Severite **Med**. Trois options listees : A/KMS-wrap,
  B/SealedSecret, C/documenter la deviation.
- `docs/reviews/2026-04-21-cycle-pass2.md` (#3) : "soit KMS-wrap (Scaleway
  KMS), soit filer un ADR-026 'static seal accepted risk'". Severite **Medium**.

Cette ADR prend le chemin **C + pass2 #3** : accepter le risque, tracer la
derive, lister les conditions de reconsideration.

## Decision

**Static seal accepte** pour Gate 1 (bootstrap mono-cluster) et Gate 2
(multi-tenant dev/staging). La deviation est **tracked drift** : chaque cycle
`cli-cycle` doit la resurfacer tant que le KMS-wrap n'est pas implemente.

### Scope de validite

| Environnement | Static seal ? | Justification |
|---------------|---------------|---------------|
| local (libvirt) | OK | poste de dev, pas de donnees sensibles |
| dev-*           | OK | sandbox, secrets ephemeres, teardown frequent |
| staging-*       | OK (transitoire) | a remplacer par KMS-wrap avant promotion prod |
| prod-*          | **INTERDIT** | KMS-wrap obligatoire (Gate 3 gate) |

## Raisons du report (pourquoi ne pas KMS-wrap maintenant)

1. **Pas de KMS externe provisionne** dans la stack bootstrap. Le cluster-0
   platform pod (podman) ne fait pas tourner un KMS tiers, et Scaleway KMS
   n'est pas encore scope dans les IAM apps (`envs/scaleway/iam/`).
2. **Chicken-and-egg avec OpenBao Transit** : la seul "KMS" disponible
   post-bootstrap est precisement OpenBao lui-meme, qui doit d'abord etre
   unsealed pour servir de wrap.
3. **Cost cap sprint tier3-em-smoke** : l'infra KMS wrap demande un IAM app
   supplementaire + un job de rotation + une procedure DR. Hors-scope.
4. **Air-gapped** : dans certains environnements cibles (VMware airgap), le
   KMS externe n'est pas accessible. Un fallback static seal reste necessaire.

## Risques acceptes

| Risque | Mitigation actuelle | Severite residuelle |
|--------|---------------------|---------------------|
| Fuite du K8s Secret `openbao-seal-key` (RBAC trop large) | `secrets` namespace scope + NetworkPolicy (a rajouter) | Med |
| Fuite via etcd at-rest (sans Talos EncryptionConfig) | Talos EncryptionConfig `aescbc` par defaut | Low |
| Fuite via tfstate en clair (avant cluster-0 Transit) | state initial stocke dans OpenBao KV v2 + Raft at-rest | Low |
| Rotation manuelle couteuse | aucune (rotate = reseed + unwrap de tous les secrets app) | Med |

## Conditions de reconsideration (sortir du tracked drift)

Passer au KMS-wrap (option A pass1 #5) des que **une** des conditions est
remplie :

- Gate 3 : deploiement prod-* vise (cost cap leve)
- Donnees sensibles (PII, secrets client) stockees dans OpenBao app
- Compliance audit externe (ISO 27001, SOC 2, ANSSI) declenche par un client
- Scaleway KMS ajoute aux IAM apps `st4ck-project/` (IAM app `kms-seal`)
- Disponibilite d'un cluster KMS auto-heberge (HashiCorp Vault OSS legal,
  Infisical, KeyCloak KMS plugin)

## Follow-up issue

- **Tracking** : GitHub issue TBD (filed at sprint close of `tier3-em-smoke`).
  Titre : "OpenBao seal: migrate from static to KMS-wrap (ADR-026 resolution)".
  Labels : `security`, `tracked-drift`, `gate-3-blocker`.

## Code pointers

- `stacks/pki/main.tf` (bloc `# ─── OpenBao seal key ───`) — marque par
  un commentaire `# DRIFT: ADR-026`.
- `stacks/pki/values-openbao-infra.yaml` — `seal "static"` block.
- `stacks/pki/values-openbao-app.yaml` — `seal "static"` block.

## Alternatives etudiees et rejetees

- **SealedSecret (Bitnami)** : nouveau controller a deployer, rotation des
  keys non triviale, aggrave la dependance git pour un boot-time secret.
- **sops-nix / sops-operator** : SOPS proscrit par CLAUDE.md ("No SOPS").
- **Vault agent injector** : agit apres unseal, ne resout pas le boot-time.

## References

- ADR-007 : OpenBao comme secrets manager
- ADR-009 : state backend OpenBao
- ADR-021 : security hardening (section "Secrets at rest")
- pass1 #5 : `docs/reviews/2026-04-22-cycle-pass1.md`
- pass2 #3 : `docs/reviews/2026-04-21-cycle-pass2.md`
