# Harnais kwok e2e — cycle NodeClaim complet sans matériel

Niveau 5 du plan `docs/how-to/test-local.md` : **karpenter-core v1.14 +
notre CloudProvider + FakeBackend** contre un cluster
[kwok](https://kwok.sigs.k8s.io/) (nœuds simulés — l'outil de test de
karpenter lui-même). Dernière marche logicielle avant de louer le premier
serveur Elastic Metal.

## Ce que le harnais prouve

Le cycle complet du LLD-002 §5, bout en bout, contre un vrai apiserver :

```
replicas 0→1 ──▶ static provisioning ──▶ Create() ──▶ StartServer (fake: stopped→ready)
                                            │
   node simulator (= kubelet Talos) ────────┘
   crée le Node kwok avec spec.providerID = scaleway-em://<zone>/<id>
   (octets identiques, taint karpenter.sh/unregistered)
                                            │
        Registered ──▶ Initialized (conditions NodeClaim, matching C3)
                                            │
replicas 1→0 ──▶ static deprovisioning ──▶ drain ──▶ Delete()
                 ──▶ StopServer (fake: ready→stopped) ──▶ NodeClaim finalisé
```

Assertions du script : providerID byte-identique Node↔NodeClaim,
transitions de puissance du FakeBackend (endpoint debug `/servers`),
conditions `Registered`/`Initialized`, finalisation complète (NodeClaim et
Node supprimés, serveur fake `stopped`).

Ce que le harnais ne prouve PAS (hardware-only, runbook M0-REPORT §3) :
denylist kubelet Talos pour `provider-id`, latence POST p95, certs après
arrêt long.

## Prérequis

```bash
brew install kwok        # fournit kwok + kwokctl (testé v0.8.0)
brew install kubectl go  # si absents
podman machine start     # ou docker — runtime des composants kwokctl
```

## Lancer

```bash
make e2e-kwok            # depuis karpenter-provider-scaleway/
# ou
hack/kwok-e2e/run.sh
```

Variables : `KEEP=1` (garde cluster + contrôleur pour inspection),
`KWOK_RUNTIME=podman|docker|binary`, `TIMEOUT=<s>` (défaut 120).
Artefacts (logs contrôleur, YAML de preuve, snapshots `/servers`) dans
`hack/kwok-e2e/.artifacts/`.

## Composants

| Fichier | Rôle |
|---|---|
| `controller/main.go` | Wiring de prod (cmd/controller) mais FakeBackend seedé (3 serveurs `stopped`, offre EM-A116X-SSD) + **node simulator** (joue le kubelet : crée le Node kwok au providerID exact) + endpoint debug `GET /servers` |
| `manifests/` | `ScalewayEMNodeClass` + NodePool statique `replicas: 0` |
| `run.sh` | Orchestration : cluster kwokctl → CRDs (depuis le cache du module karpenter pinné, zéro dérive) → contrôleur → cycle 0→1→0 avec assertions |

Détails de wiring notables :

- `FEATURE_GATES=StaticCapacity=true` — `NodePool.spec.replicas` est un
  champ **alpha** du core v1.14 (prérequis de déploiement documenté au
  README du module).
- `DISABLE_LEADER_ELECTION=true`, ports metrics/health déplacés
  (8087/8088 — 8080 est pris par vault-backend sur les postes du projet).
- Le node simulator pose le taint `karpenter.sh/unregistered:NoExecute`
  comme le ferait `registerWithTaints` sur le machineconfig réel — sans
  lui, core v1.14 refuse l'enregistrement.
- Les CRDs karpenter viennent de `go list -m -f '{{.Dir}}' sigs.k8s.io/karpenter`
  → toujours celles du tag pinné dans go.mod.
