# ADR-032 : PKI hierarchy — Root CA on VM, sub-CAs in cluster via Helm Job

**Date** : 2026-04-30
**Statut** : Proposé (source-only, pas encore deployé)
**Décideurs** : Équipe plateforme
**Reliés à** : ADR-007 (OpenBao secrets manager), ADR-026 (static seal accepted risk), ADR-028 (Flux owner-by-default), Phase F-bis-2 v1/v2 (échec, voir roadmap)

## Contexte

### Historique des tentatives

**Phase 1b-1 (initial)** : `terraform_data.bootstrap_openbao_pki` (~180 LOC bash
inline dans `stacks/pki/secrets.tf`) gérait l'intégralité de la PKI in-cluster :

1. Mount `pki/` (10y max-lease) + `pki_int/` (5y max-lease) sur OpenBao Infra
2. Génération d'un root CA **dans le cluster** (`pki/root/generate/internal`,
   EC P-384, 10y) — distinct du root CA déjà présent sur la CI VM
   (`bootstrap/tofu/pki.tf`).
3. Génération d'un intermediate CSR, signature par le root cluster
   (`pki/root/sign-intermediate`), upload du certificat signé.
4. Configuration des issuer URLs (CRL/OCSP).
5. Création des roles `cluster-issuer` (EC strict) et `cilium-hubble`
   (any-key, scoped aux CN Cilium).
6. Enable `auth/kubernetes`, écriture de la policy `cert-manager`, binding
   du SA `cert-manager → cert-manager-policy`.

**Problème observé** :

- **Duplication des roots** : un root sur la VM (ECDSA P-384 self-signed),
  un autre dans le cluster, sans lien de confiance entre les deux. Les
  consommateurs (cert-manager, ESO, Pomerium) reçoivent le bundle
  `infra-ca-chain.pem` (intermediate VM + root VM), mais OpenBao émet
  des leaf certs signés par un intermediate cluster signé par un root
  cluster — chaîne de confiance différente.
- **Fragilité du provisioner** : 180 LOC bash inline dans Tofu, exécuté
  par `local-exec` depuis la machine de l'opérateur, dépend de
  `kubectl exec` vers `openbao-infra-0`. Échoue silencieusement si
  l'admin password change, si `openbao-infra-0` n'est pas le leader,
  ou si une seule des 6 commandes échoue.
- **Re-runs lents** : chaque `tofu apply` re-exécute le provisioner si
  l'admin password a bougé (input hash). Idempotence garantie par
  `bao read` probes mais coûte ~30s de polling par re-run.

**Phase F-bis-2 v1 (Helm-native HA OpenBao, échec)** :
- Tentative de déployer OpenBao directement avec `replicas: 3` +
  `retry_join` + `OrderedReady`.
- Bug OpenBao 2.x #2274 : initialize blocks racent malgré `OrderedReady`,
  split-brain reproductible.
- Revert : commit `78a301f` ("revert: Phase F-bis-2 Helm-native HA —
  split-brain malgré OrderedReady").

**Phase F-bis-2 v2 (operator OpenBao, abandonné)** :
- Évalué : bao-operator (community) — projet jeune, peu de contributeurs,
  pas de support officiel HashiCorp/OpenBao.
- Risque jugé excessif pour un environnement déjà fragile.
- Pas de POC engagé.

### Insight 2026-04-30 (idée user)

> "Pourquoi ne pas garder le root sur la VM (déjà présent), et bootstrap
> les sub-CAs dans le cluster via un Helm Job au lieu d'un terraform_data ?
> Ça enlève la duplication et le pattern devient K8s-natif."

C'est cette décomposition que codifie ADR-032.

## Décision

### Architecture cible (Phase F-bis-2 v3)

```
┌─────────────────────────────────────────────────────────────────┐
│  CI VM (platform-bao podman pod)                                 │
│    ├── Root CA (EXISTANT : bootstrap/tofu/pki.tf)                │
│    │   └── tls_self_signed_cert.root_ca, ECDSA P-384, 10y       │
│    │   └── lifecycle.ignore_changes = all                        │
│    ├── Intermediate Infra CA                                     │
│    │   └── tls_locally_signed_cert.infra_ca, ECDSA P-384, 5y    │
│    │   └── signé par root_ca, exporté vers kms-output/          │
│    ├── Intermediate App CA (idem, séparé)                        │
│    └── Distribution :                                            │
│        ├── kms-output/root-ca.pem      → K8s Secret pki-root-ca │
│        ├── kms-output/infra-ca-*.pem   → K8s Secret pki-infra-ca│
│        └── kms-output/app-ca-*.pem     → K8s Secret pki-app-ca  │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼ (distribués comme K8s Secrets, ns: secrets)
┌─────────────────────────────────────────────────────────────────┐
│  Cluster (Helm post-install Job — pas de terraform_data)        │
│    ├── Job: bootstrap-openbao-pki                                │
│    │   ├── Hook: post-install,post-upgrade (weight: 10)         │
│    │   ├── Delete-policy: before-hook-creation,hook-succeeded   │
│    │   ├── ServiceAccount + Role + RoleBinding (RBAC scoped)    │
│    │   └── Container :                                           │
│    │       ├── Wait OpenBao Infra API ready (300s budget)       │
│    │       ├── Login admin (read openbao-admin-password)        │
│    │       ├── Mount pki_int/ (5y max-lease) — PAS pki/         │
│    │       ├── Configure issuer URLs                             │
│    │       ├── Create role cluster-issuer (EC strict)           │
│    │       ├── Create role cilium-hubble (any-key, scoped)      │
│    │       ├── Enable auth/kubernetes (idempotent)              │
│    │       ├── Write policy cert-manager                         │
│    │       └── Bind SA cert-manager → policy                     │
│    │                                                             │
│    └── Note : intermediate CA loading sur pki_int/config/ca     │
│        DEFERRED to follow-up (Job RBAC pas étendu volontairement)│
└─────────────────────────────────────────────────────────────────┘
```

### Changements techniques

| Aspect | Avant | Après |
|--------|-------|-------|
| Root CA location | VM + cluster (duplication) | VM uniquement |
| Bootstrap mechanism | terraform_data inline ~180 LOC | Helm Job + RBAC ~280 LOC |
| Trigger | `tofu apply` depuis opérateur | Helm hook post-install/upgrade |
| Idempotence | bao probes guard | bao probes guard (identique) |
| Failure visibility | Tofu output (parfois opaque) | `kubectl logs job/bootstrap-openbao-pki` |
| Re-run cost | ~30s polling à chaque apply | 0 si Helm release inchangée |
| RBAC scope | Tofu admin (kubeconfig full) | SA scoped : 2 secrets read + exec sur openbao-infra-0 |
| Pattern alignment | Tofu-as-K8s-controller | K8s-native (Job + Helm) |

### Ce que la migration NE change pas

- **Roles + policies** : `cluster-issuer` (EC strict, max_ttl 35040h) et
  `cilium-hubble` (any-key, allowed_domains scoped) restent identiques.
- **cert-manager auth** : binding SA `cert-manager → cert-manager` policy
  reste identique, K8s host reste `https://kubernetes.default.svc:443`.
- **ClusterIssuer YAML** : `internal-ca` (Vault kind) et `cilium-issuer`
  inchangés — ils pointent vers le même `pki_int/sign/...` path.
- **Static seal** : ADR-026 reste valide, openbao-seal-key reste un K8s
  Secret généré par `random_bytes` Tofu.

### Migration step-by-step

1. **Source-only commit** (cette ADR + Helm Job + secrets.tf no-op shim).
   PAS de `tofu apply`, PAS de redéploiement. Agent #10 est en cours de
   rebuild — on respecte sa territoriality sur main.tf.
2. **Validation post-demo** (2026-05-01+) :
   - `tofu apply stacks/pki` → pour observer que le Helm Job se déclenche
     bien après `helm install`.
   - `kubectl logs -n secrets job/bootstrap-openbao-pki` → vérifier
     idempotence sur re-apply.
3. **Intermediate CA loading** (follow-up) :
   - Soit étendre le Job RBAC pour lire `pki-infra-ca` (intermediate
     keypair), invoquer `pki_int/config/ca pem_bundle=@<bundle>`.
   - Soit one-shot manuel depuis l'opérateur après bootstrap.
   - Décision déferrée : on veut d'abord voir le Job tourner sans cette
     étape pour vérifier que le reste (roles, auth) est suffisant pour
     les paths `internal-ca-bootstrap` (CA-secret kind, Phase 0).
4. **Définitive removal** du shim no-op (Phase F-bis-2 v4) :
   - Remplacer `depends_on = [terraform_data.bootstrap_openbao_pki]` par
     un `kubernetes_job` data source ou `time_sleep` dans `main.tf`.
   - Supprimer le bloc `terraform_data.bootstrap_openbao_pki` entier.
   - `tofu state rm` sur chaque cluster existant.

## Conséquences

### Positives

- **-180 LOC bash dans Tofu** (provisioner inline supprimé). +280 LOC YAML
  Helm Job (mais Job est un artefact K8s standard, lisible/auditable).
- **Pattern K8s-natif** : Helm hook + Job + RBAC scoped, plus aucune
  dépendance à `local-exec` ou à la machine de l'opérateur.
- **Pas de duplication root CA** : la chaîne de confiance est cohérente
  end-to-end (VM root → VM intermediate → cluster pki_int signé par
  VM intermediate, cf follow-up).
- **Failure visibility améliorée** : `kubectl logs` au lieu de Tofu output
  parfois tronqué.
- **RBAC scoped** : le Job lit 2 secrets (admin password + root CA cert)
  + peut `exec` uniquement sur `openbao-infra-0`. Tofu auparavant avait
  full kubeconfig.
- **Idempotence Helm-native** : si la Helm release n'a pas changé, le Job
  ne re-tourne pas. Si elle change (upgrade), le Job re-tourne avec les
  bao probes pour skip si déjà configuré.

### Négatives

- **Le shim no-op `terraform_data.bootstrap_openbao_pki` reste pendant
  la transition** (Phase F-bis-2 v3). Bruit visuel dans `tofu plan`,
  mais pas d'impact runtime.
- **Intermediate CA loading toujours en suspens** (cf follow-up Étape 3).
  Les roles + auth sont créés, mais `pki_int/cert/ca` reste vide tant que
  personne ne fait `pki_int/config/ca`. Conséquence : `cluster-issuer`
  role peut être appelé mais retournera "no CA available" jusqu'à
  intermediate loading.
- **Job vs terraform_data — séquencement Tofu** : la migration définitive
  (v4) doit gérer le fait que Tofu ne sait pas attendre un Helm Job.
  Soit `kubernetes_job` data source (avec wait_for_completion), soit
  `time_sleep`, soit accepter que cluster-issuer Vault ClusterIssuer
  apply en parallèle et que cert-manager retry en boucle pendant 1-2min.
- **Helm Job re-run sur upgrade** : si on change `values-openbao-infra.yaml`
  pour faire un upgrade Helm, le Job re-tourne. Idempotent mais consomme
  ~30s à chaque upgrade. Acceptable.

### Risques

- **Cluster fresh bootstrap** : si pour une raison quelconque le Helm Job
  échoue (network blip, OpenBao not ready après 300s), cert-manager se
  retrouve sans backend Vault et bloque tous les Certificate CRs. La
  recovery : `kubectl delete job/bootstrap-openbao-pki && helm upgrade`
  re-fire le hook.
- **Migration v3 → v4 sur cluster existant** : nécessite un `tofu state
  rm` sur chaque cluster pour évacuer le shim. À documenter dans le
  runbook de migration.
- **VM intermediate keypair en cluster** : pour faire le `pki_int/config/ca`,
  il faut que le keypair VM-signed soit accessible depuis OpenBao. Il
  l'est déjà (kubernetes_secret.pki_infra_ca, secrets ns), mais étendre
  le Job RBAC pour lire ce secret signifie que la clé privée transite
  par le pod Job. Acceptable (même surface que `cert_manager_ca` Secret
  dans cert-manager ns), à documenter explicitement.

## Alternatives considérées

### A — Status quo (terraform_data inline)

- Pour : aucun changement, marche déjà.
- Contre : duplication root CA, 180 LOC bash fragile, dépendance à
  l'opérateur. Tracked drift.

### B — Operator OpenBao (Phase F-bis-2 v2)

- Pour : K8s-native, pattern operator-first.
- Contre : bao-operator community jeune, pas de support OpenBao officiel,
  risque d'abandon du projet upstream.
- Décision : abandonné Phase F-bis-2 v2.

### C — Helm-native HA (Phase F-bis-2 v1)

- Pour : déploiement direct `replicas: 3` + `retry_join`, pas de scale
  orchestré.
- Contre : bug OpenBao 2.x #2274 reproductible, split-brain malgré
  `OrderedReady`.
- Décision : revert (commit `78a301f`).

### D — vault-secrets-operator (HashiCorp)

- Pour : opérateur officiel HashiCorp.
- Contre : Vault uniquement (pas OpenBao). Pas une option pour st4ck
  (ADR-007).

### E — Helm Job (cette ADR)

- Pour : K8s-native, pattern standard, RBAC scoped, pas de duplication.
- Contre : nécessite une migration en deux phases (v3 shim → v4 removal).
- Décision : retenu.

## Status flag

- 2026-04-30 : ADR créée (Phase F-bis-2 v3, source-only).
- TBD : déploiement post-demo + validation Job.
- TBD : Phase F-bis-2 v4 (removal définitif du shim).
