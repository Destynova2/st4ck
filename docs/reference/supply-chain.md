# Audit Supply Chain — Fournisseurs Helm et Images

> Audit realise 2026-03-19. Couvre tous les charts Helm et images container du projet.

## Helm Charts

| Fournisseur | Mainteneur | Licence | Risque | Notes |
|-------------|-----------|---------|--------|-------|
| Cilium + Tetragon | Isovalent / CNCF Graduated | Apache-2.0 | **Faible** | Cisco-backed, releases signees |
| VictoriaMetrics | VictoriaMetrics Inc. | Apache-2.0 | **Faible** | Open-core, releases multiples/mois |
| cert-manager | Venafi / CNCF Graduated | Apache-2.0 | **Faible** | Tres largement adopte, stable |
| Harbor | CNCF Graduated | Apache-2.0 | **Faible** | Programme advisories actif |
| Headlamp | Kubernetes SIGs | Apache-2.0 | **Faible** | Surface d'attaque faible (UI) |
| CloudNativePG | EDB / CNCF Sandbox | Apache-2.0 | **Faible** | Operator PostgreSQL, EDB sponsor |
| Trivy Operator | Aqua Security | Apache-2.0 | **Faible** | Scanner vulnerabilites, cadence active |
| Kratos + Hydra | Ory Corp | Apache-2.0 | **Faible-Moyen** | VC-backed, OpenID Certified (Hydra) |
| Pomerium | Pomerium Inc. | Apache-2.0 | **Faible-Moyen** | VC-backed, herite CVEs Envoy |
| Woodpecker CI | Communaute | Apache-2.0 | **Faible-Moyen** | Fork Drone, communaute active |
| Kyverno | Nirmata / CNCF Incubating | Apache-2.0 | **Moyen** | CVE-2026-22039 (auth bypass cross-namespace) — patchee >= 1.16.3 |
| OpenBao | Linux Foundation / OpenSSF | MPL-2.0 | **Moyen** | 12 CVEs en 2025 dont CVSS 9.1 (RCE). Jeune projet, monitoring requis |
| Flux2 | fluxcd-community | Apache-2.0 | **Moyen** | Chart communautaire best-effort, pas le chart officiel Flux |
| Velero | VMware / Broadcom | Apache-2.0 | **Faible** | Risque relicensing Broadcom (precedent HashiCorp) |
| local-path-provisioner | containeroo | Non liste | **Moyen-Haut** | 7 stars, chart non-officiel. Envisager le chart upstream Rancher |

## Images Container (bootstrap)

| Image | Mainteneur | Licence | Risque | Pin digest |
|-------|-----------|---------|--------|------------|
| ghcr.io/opentofu/opentofu | Linux Foundation | MPL-2.0 | **Faible** | Oui |
| quay.io/openbao/openbao | OpenBao / LF | MPL-2.0 | **Moyen** | Oui |
| docker.io/gitea/gitea | Gitea project | MIT | **Faible** | Oui |
| docker.io/woodpeckerci/woodpecker-* | Communaute WP | Apache-2.0 | **Faible-Moyen** | Oui |
| docker.io/gherynos/vault-backend | **Individu** (gherynos) | Apache-2.0 | **HAUT** | Oui |

## Risques critiques

### 1. vault-backend (gherynos) — HAUT

Mainteneur unique, 5 stars GitHub. Composant en chemin critique : tout le tfstate transite par lui.
Une compromission de l'image = exfiltration de tous les secrets.

**Mitigations actuelles** : image pinnee au digest SHA256.

**Actions recommandees** :
- Builder l'image depuis les sources (go build)
- Ou vendorer le binaire dans le repo
- Ou remplacer par un backend TF natif (S3/GCS)

### 2. local-path-provisioner (containeroo) — MOYEN-HAUT

Chart communautaire non-officiel wrapping le projet Rancher. 7 stars, bus-factor 1.

**Action recommandee** : migrer vers le chart upstream `rancher/local-path-provisioner`.

### 3. OpenBao — MOYEN

12 CVEs en 2025, dont CVE-2025-54997 (RCE, CVSS 9.1) et CVE-2025-64761 (privilege escalation).
Projet sous Linux Foundation mais jeune. Monitoring actif des releases requis.

## Points positifs

- Toutes les images bootstrap pinnees au digest SHA256
- Majorite CNCF Graduated/Incubating ou entreprises etablies
- Aucune licence copyleft ou proprietaire (Apache-2.0, MPL-2.0, MIT)
- Aucun composant AGPL ou BSL
