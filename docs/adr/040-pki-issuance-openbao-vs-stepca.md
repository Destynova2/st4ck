# ADR-040 : Émission de certificats — OpenBao PKI engine, step-ca/cfssl écartés

**Date** : 2026-07-15
**Statut** : Accepté — documente et verrouille un choix déjà implémenté (stacks/pki)
**Décideurs** : Équipe plateforme
**Reliés à** : ADR-007 (OpenBao secrets), ADR-026 (static seal), ADR-032 (root VM → sub-CA cluster), ADR-033 (frontière Tofu/Flux)

## Contexte

Question récurrente : faut-il une CA « opérationnelle » dédiée (step-ca,
cfssl, EJBCA…) ou le moteur PKI d'OpenBao suffit-il ? La réponse engage
l'air-gap, la surface d'attaque et le nombre d'owners.

État réel de la plateforme (déjà en place, ADR-032) :

```
Root CA (OpenBao KMS bootstrap, podman — froid via `make bootstrap-stop`)
    └── pki_int (OpenBao Infra in-cluster, intermediate issuing CA)
            └── cert-manager
                ├── ClusterIssuer internal-ca-bootstrap (kind CA,
                │     pré-OpenBao — casse l'œuf/poule au premier deploy)
                └── ClusterIssuer internal-ca (kind Vault →
                      pki_int/sign/cluster-issuer, auth Kubernetes)
```

C'est déjà le pattern « root froid → intermediate OpenBao → cert-manager »
que recommandent les comparatifs. La question devient : qu'apporteraient
les alternatives EN PLUS de l'existant ?

## Options considérées

### cfssl (Cloudflare) — rejeté
Signeur de CSR bas niveau, sans lifecycle (pas d'ACME, pas de renewal,
révocation CRL basique), maintenance quasi arrêtée. Son seul cas d'usage
(bootstrap ponctuel d'une intermediate) est déjà couvert chez nous par
le provider `tls` de Tofu + l'init PKI du bootstrap. Aucun rôle restant.

### step-ca (Smallstep) — écarté aujourd'hui, option RA notée
CA complète et bien maintenue : ACME natif, renewal agent, certs SSH,
provisioners OIDC, PKCS#11. Mais dans NOTRE stack chaque force tombe :

- **ACME** : inutile in-cluster — le ClusterIssuer Vault signe en direct
  via l'API `sign/`, sans challenge HTTP/DNS. (Si un client externe
  exigeait ACME un jour, le moteur PKI hérité du fork Vault 1.14 le
  fournit côté OpenBao — à valider à l'activation.)
- **Certs SSH** : l'argument-phare perd l'essentiel de sa valeur ici —
  **Talos n'a pas de SSH du tout** (API talosctl mTLS). Le périmètre SSH
  résiduel se réduit à la VM CI et au Gitea du bootstrap : trop mince
  pour justifier une CA de plus.
- **Renewal** : cert-manager renouvelle déjà tous les certs workloads.

step-ca reste l'option documentée si un vrai besoin SSH-certs émerge
(flotte de VMs CI, accès humains audités) : en mode **RA devant OpenBao**
(OpenBao signe, step-ca automatise) — pas en CA autonome, la hiérarchie
resterait à deux niveaux ADR-032.

### EJBCA CE / XiPKI / Dogtag / Boulder — rejetés
- **EJBCA** : le plus complet (RA/VA séparés, workflows d'approbation,
  audit conformité, HSM). Java + lourd opérationnellement ; pertinent
  seulement sous exigence réglementaire formelle (FIPS, CC) — hors
  périmètre actuel. À réévaluer si un client KaaS l'impose.
- **XiPKI** : outsider crédible surtout pour le post-quantique
  (ML-DSA/ML-KEM). Notre horizon PQC n'est pas engagé ; noté en veille.
- **Dogtag** : complexité FreeIPA sans bénéfice ici. **Boulder** :
  ACME-only, pas une CA généraliste.

## Décision

1. **Le moteur PKI d'OpenBao + cert-manager reste l'unique chaîne
   d'émission X.509** de la plateforme. Zéro composant nouveau : la
   hiérarchie ADR-032 est confirmée comme suffisante.
2. **Aucun step-ca/cfssl n'entre dans la stack.** L'option « step-ca en
   RA devant OpenBao pour des certs SSH » est la seule porte de retour,
   déclenchée par un besoin SSH réel et chiffré (elle ne modifierait pas
   la hiérarchie de CAs).
3. **Durcissement prod noté (pas décidé ici)** : root sur HSM via
   OpenBao Managed Keys / PKCS#11 — s'inscrit dans la checklist
   production (ADR-022), sans changer l'architecture logique.

## Conséquences

- Une question d'architecture récurrente obtient une réponse écrite et
  opposable ; les comparatifs externes (cfssl vs step-ca, etc.) pointent
  ici.
- La révocation reste passive (certs courts renouvelés par cert-manager)
  — cohérent avec l'absence de CRL/OCSP exposés ; à réévaluer seulement
  si des consommateurs hors-cluster apparaissent.
- Le jour où KaaS exige des CAs par tenant, la réponse par défaut est
  « un mount pki_int par tenant dans OpenBao », pas une CA tierce.
