# ADR-010 : VictoriaMetrics + VictoriaLogs (observabilite consolidee)

**Date** : 2026-03-09
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

L'observabilite etait initialement prevue avec des composants separes :
- Prometheus (metriques)
- Loki (logs)
- Alloy (collecteur unifie)
- Grafana (dashboards)

## Problemes identifies

### Prometheus

- Consommation memoire elevee (TSDB en memoire)
- Compression faible sur disque
- Scaling horizontal complexe (Thanos/Cortex)
- Pas de long-term storage natif
- kube-state-metrics + node-exporter a deployer separement

### Loki + Alloy

1. `loki.source.kubernetes` (API-based) : **aucun log ingere**. Le mode API ne fonctionnait pas dans l'environnement Talos.
2. `loki.source.file` (hostPath) : fonctionnait mais necessite pipeline CRI parsing complexe.
3. Alloy config fragmentee entre metriques et logs (syntaxe River).

## Decision

Remplacer par **2 charts consolides** :

### 1. victoria-metrics-k8s-stack (chart 0.72.4)

Tout-en-un metriques :
- **VMSingle** : stockage metriques, retention 30d, compression ~10x vs Prometheus TSDB
- **VMAgent** : scrape, relabeling `cluster=talos`
- **VMAlert + Alertmanager** : alertes
- **Grafana** : datasources auto, dashboards grafana.com
- **kube-state-metrics + node-exporter** inclus

API 100% compatible Prometheus (PromQL, remote_write, scrape configs). Single binary, pas de cluster Thanos a gerer.

### 2. VictoriaLogs (remplace Loki)

- victoria-logs-single 0.11.28 (stockage logs)
- victoria-logs-collector 0.2.11 (DaemonSet, remplace Alloy pour les logs)

### Collecteur

Decision initiale : Grafana Alloy comme collecteur unifie metriques+logs.
**Amende** : Alloy remplace par VMAgent (metriques, integre au chart) + victoria-logs-collector (logs, DaemonSet dedie). Alloy ajoutait une couche de complexite sans valeur par rapport aux collecteurs natifs.

## Problemes rencontres au deploiement

- Chart v0.72.4 : `grafana.sidecar.dashboards.enabled: true` + `grafana.dashboards` = conflit. Fix: `sidecar.dashboards.enabled: false`.
- `additionalScrapeConfigs` : CRD VMAgent attend un `SecretKeySelector` (objet), pas un array inline. Fix: supprime, remplace par `scrapeInterval: 30s` dans vmagent.spec.
- `remoteWrite` victoria-logs-collector : attend une liste `[{url: ...}]`, pas un objet. Fix: format liste.
- VMSingle PVC Pending (pas de StorageClass avant k8s-storage). Fix: `storage: {}` -> emptyDir.
- **VMAlertmanager label >63 chars** : le nom genere `vmalertmanager-vm-k8s-stack-victoria-metrics-k8s-stack-<hash>` depasse la limite K8s de 63 caracteres pour les labels. A fixer en raccourcissant le nom de la release Helm ou de la CR.

## Consequences

### Positives

- Un seul chart pour toutes les metriques (install ~2 min)
- Compression superieure (~10x), compatible air-gapped (une seule image)
- Dashboards grafana.com compatibles grace au label `cluster=talos`
- VictoriaLogs + collector = solution logs legere sans Loki
- Headlamp (0.40.0) ajoute comme UI K8s complementaire

### Negatives

- Ecosysteme plus petit que Prometheus
- Dependance a un vendor (VictoriaMetrics Inc.)
- Certaines incompatibilites mineures PromQL (edge cases)
