# ADR-022 : Checklist de mise en production

**Date** : 2026-03-19
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

Ce document consolide toutes les actions necessaires avant un deploiement en production de la plateforme st4ck. Il decoule de l'ADR-021 (durcissement securite) et des invariants d'architecture documentes dans CLAUDE.md.

## Checklist

### Reseau et acces (ADR-021 #1, #11)

- [ ] **Security groups Scaleway** : separer sg-public (6443, 50000) et sg-internal (etcd, kubelet, Cilium restreints au CIDR VPC)
- [ ] **Variable `management_cidr`** : definir les CIDRs autorises pour Talos API (50000) et SSH CI (22)
- [ ] **VM CI** : supprimer les regles inbound 3000/8000 du security group public, acces via tunnel SSH
- [ ] **Load Balancer** : verifier que seul le port 6443 est expose publiquement
- [ ] **NetworkPolicy Cilium** : deployer des policies L3/L4 par namespace (deny-all par defaut, allow explicite)

### Secrets et credentials (ADR-021 #3, #4, #5, #10)

- [ ] **local_file -> local_sensitive_file** : migrer tous les fichiers contenant des cles privees ou tokens (`vault.tf`, `pki.tf`)
- [ ] **ConfigMap -> Secret** : separer `platform-config` en ConfigMap (non-sensible) + Secret (mots de passe, cles API)
- [ ] **setup.sh.tpl** : appliquer la meme separation ConfigMap/Secret pour le deploiement CI distant
- [ ] **admin_password** : supprimer le default `localpass123`, ajouter validation `length >= 16`
- [ ] **Git push** : supprimer les credentials de l'URL, utiliser git credential helper ou token API
- [ ] **Verifier `.gitignore`** : confirmer que `kms-output/`, `*.tfstate`, `*.tfvars` sont ignores
- [ ] **Rotation des secrets** : documenter la procedure de rotation pour chaque secret genere par `random_id`

### Stockage et persistance (ADR-021 #2, #7)

- [ ] **OpenBao KMS (podman)** : remplacer `emptyDir` par un PVC pour `/bao/data`
- [ ] **Backup Raft** : mettre en place un cron `make state-snapshot` (quotidien minimum)
- [ ] **Hydra** : migrer de `dsn: "memory"` vers PostgreSQL, `dev: false`
- [ ] **Kratos** : migrer de `dsn: "memory"` vers PostgreSQL, `development: false`
- [ ] **PostgreSQL identity** : deployer un operateur (CloudNativePG ou Bitnami chart) avec backup WAL

### TLS et PKI (ADR-021 #6, #16)

- [ ] **OpenBao in-cluster** : activer TLS sur le listener TCP (`tls_disable = false`), certificat signe par `ClusterIssuer "internal-ca"`
- [ ] **Pomerium -> Hydra** : passer de HTTP a HTTPS (`providerUrl: https://hydra-public.identity.svc:4444/`)
- [ ] **CA trust** : injecter la CA interne dans les trust stores de tous les composants qui communiquent en TLS intra-cluster
- [ ] **Certificats** : verifier les durees de validite (Root CA 10 ans, Sub-CA 5 ans, workloads via cert-manager auto-renew)

### Authentification et autorisation (ADR-021 #8, #9, #15)

- [ ] **Gitea** : `DISABLE_REGISTRATION=true` apres creation de l'admin
- [ ] **Woodpecker** : `OPEN=false`
- [ ] **Token vault-backend** : migrer vers AppRole (renouvellement automatique) ou mettre en place un cron de renewal
- [ ] **Superuser policy** : activer l'audit log OpenBao (`sys/audit/file`), integrer dans VictoriaLogs
- [ ] **RBAC Kubernetes** : verifier qu'aucun `ClusterRoleBinding` superflu n'existe (pas de `cluster-admin` pour les workloads)

### Politique de securite runtime (ADR-021 #12, #13)

- [ ] **Kyverno** : valider toutes les policies en mode Audit pendant 2 semaines, puis passer `failurePolicy: Fail`
- [ ] **Cosign** : signer toutes les images de la CI avec Cosign, configurer la cle publique, passer `validationFailureAction: Enforce`
- [ ] **Tetragon** : deployer les TracingPolicy de base (ADR-018) — detection d'acces fichiers sensibles, connexions suspectes
- [ ] **Pod Security Standards** : activer le mode `restricted` sur les namespaces applicatifs

### Flux et GitOps (ADR-021 #14)

- [ ] **known_hosts** : remplacer le placeholder par la cle SSH reelle de Gitea (`ssh-keyscan`)
- [ ] **Git SSH** : verifier que le `Secret flux-git-credentials` contient une cle SSH valide signee par la CA OpenBao
- [ ] **Reconciliation** : verifier que `kubectl get kustomizations -n flux-system` montre tous les stacks en `Ready`
- [ ] **Drift detection** : activer les alertes Flux (`Alert` + `Provider`) vers le monitoring

### Observabilite

- [ ] **VictoriaMetrics** : confirmer la retention configuree (defaut 1 mois minimum en production)
- [ ] **VictoriaLogs** : integrer les logs OpenBao audit, Tetragon, Cilium flow logs
- [ ] **Alerting** : configurer les regles d'alerte critiques (node down, pod crash loop, certificat expirant, OpenBao sealed)
- [ ] **Headlamp** : restreindre l'acces via Pomerium (pas d'acces anonyme)

### Stockage et sauvegarde

- [ ] **Velero** : configurer un schedule de backup quotidien vers Garage S3
- [ ] **Garage** : verifier la replication (minimum 3 copies), tester la restauration
- [ ] **Harbor** : activer le garbage collection, configurer les quotas de stockage
- [ ] **etcd** : verifier les snapshots automatiques Talos (`machine.etcd.snapshotSchedule`)

### Reseau avance

- [ ] **Cilium mTLS** : activer le chiffrement transparent inter-workloads
- [ ] **Hubble** : deployer Hubble UI avec acces restreint (via Pomerium)
- [ ] **DNS** : configurer un enregistrement DNS pour l'API Kubernetes (pas d'acces par IP)

### Documentation et procedures

- [ ] **Runbook** : documenter les procedures de restauration (Raft snapshot, Velero, etcd)
- [ ] **Rotation PKI** : documenter la procedure de rotation Root CA et Sub-CA
- [ ] **Break-glass** : documenter l'acces admin d'urgence (userpass OpenBao)
- [ ] **Incident response** : definir le processus d'alerte et d'escalade

### Tests pre-production

- [ ] **Chaos test** : redemarrer chaque composant individuellement et verifier la reprise
- [ ] **Failover etcd** : simuler la perte d'un control plane et verifier le quorum
- [ ] **Restore test** : restaurer un backup Velero et un snapshot Raft sur un cluster vierge
- [ ] **Penetration test** : scanner les ports exposes depuis l'exterieur (nmap, trivy image scan)
- [ ] **Load test** : valider les `resources.requests` et `limits` sous charge

## Consequences

### Positives

- Visibilite complete sur le travail restant avant production
- Chaque item est tracable vers un ADR ou un invariant d'architecture
- La checklist sert de gate de validation formelle

### Negatives

- Volume de travail significatif (~30h technique + tests + documentation)
- Certains items sont interdependants (TLS avant Pomerium HTTPS, PostgreSQL avant desactivation dev mode)
- La checklist devra etre maintenue a jour a chaque evolution de la plateforme
