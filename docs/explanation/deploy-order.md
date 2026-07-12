# Ordre de deploiement : du laptop au baremetal

Ce document repond a la question recurrente « on deploie d'abord des VM,
puis du baremetal ? » en montrant l'ordre complet de mise en route de la
plateforme, du poste operateur jusqu'aux serveurs Elastic Metal.

Sources : `Makefile` (cible `k8s-up`, vagues paralleles depuis le
2026-07-12), ADR-035 (pool Elastic Metal statique), ADR-036 (ou investir
l'effort autoscaling), LLD-002 (`docs/design/002-karpenter-scaleway-em.md`),
ADR-034 (Hauler).

## Vue d'ensemble

```mermaid
flowchart TB
    subgraph P0["0 — Laptop (podman)"]
        BOOT["make bootstrap"]
        POD["Pod plateforme : OpenBao KMS,<br/>vault-backend :8080, Gitea, Woodpecker<br/>+ PKI root CA"]
    end
    subgraph P1["1 — Scaleway one-shot"]
        IAM["make scaleway-iam-apply<br/>projet + 9 apps IAM"]
        IMG["make scaleway-image-apply<br/>image Talos Image Factory → snapshot<br/>(1x par region)"]
    end
    subgraph P2["2 — VM CI (1 par env)"]
        CI["make scaleway-ci-apply<br/>possede le Private Network partage"]
    end
    subgraph P3["3 — Cluster VM de management"]
        UP["make scaleway-up<br/>3 control planes + 3 workers Talos<br/>instances DEV1-M / DEV1-L"]
        CNI["cni — Cilium"]
        PKI["pki — OpenBao + cert-manager<br/>~10 min : chemin critique"]
        subgraph W1["vague 1 (-j2)"]
            MON["monitoring"]
            IDN["identity"]
        end
        subgraph W2["vague 2 (-j2)"]
            SEC["security"]
            STO["storage"]
        end
        FLX["flux-bootstrap"]
        DAY2["Day-2 : Flux reconcilie tout<br/>registre de versions (substituteFrom)"]
        OIDC["make oidc-register"]
    end
    subgraph P4["4 — Option KaaS"]
        KAAS["make kaas-up : capi → kamaji →<br/>autoscaling → gateway-api<br/>puis managed-cluster-apply par tenant"]
    end
    subgraph P5["5 — Elastic Metal : pool de workers (PAS un 2e cluster)"]
        PRE["modules/em-talos-bootstrap<br/>Ubuntu jetable → rescue → wipe →<br/>dd image metal → apply-config + provider-id"]
        POOL["Pool statique eteint<br/>serveurs tagges, PN meme AZ"]
        KARP["karpenter-provider-scaleway (spike M0)<br/>NodePool statique spec.replicas"]
        JOIN["Workers pool metal du cluster VM<br/>taint st4ck.io/pool=metal<br/>Kyverno route les workloads > 1 h"]
    end

    BOOT -->|"cree"| POD
    POD -->|"backend d'etat : prerequis de tout tofu"| IAM
    IAM -->|"credentials image-builder"| IMG
    IAM -->|"app IAM ci"| CI
    IMG -->|"snapshot Talos"| UP
    CI -->|"PN partage — Bug #31 : AVANT le cluster"| UP
    UP -->|"kubeconfig"| CNI
    CNI -->|"CNI pret"| PKI
    PKI -->|"ClusterIssuer + secrets"| W1
    W1 -->|"CRD CNPG poses"| W2
    W2 --> FLX
    FLX -->|"reconciliation GitOps"| DAY2
    DAY2 -->|"Hydra pret (Bug #35)"| OIDC
    DAY2 -.->|"optionnel"| KAAS
    UP -->|"machineconfig worker + endpoint"| PRE
    CI -->|"PN meme AZ"| POOL
    PRE -->|"pre-image Talos"| POOL
    KARP -->|"power-on / power-off"| POOL
    POOL -->|"boot Talos"| JOIN
    JOIN -.->|"rejoignent le cluster VM"| UP
    STO -.->|"artefacts : registre + Hauler"| JOIN

    classDef prep fill:#ECF0F1,stroke:#BDC3C7,color:#2C3E50
    classDef core fill:#4A90D9,stroke:#2C6CB0,color:#fff
    classDef crit fill:#F39C12,stroke:#D68910,color:#fff
    classDef metal fill:#27AE60,stroke:#1E8449,color:#fff
    class BOOT,POD,IAM,IMG,CI,KAAS prep
    class UP,CNI,MON,IDN,SEC,STO,FLX,DAY2,OIDC core
    class PKI crit
    class PRE,POOL,KARP,JOIN metal
```

Lecture des couleurs : gris = preparation one-shot ou optionnelle, bleu =
chemin core du cluster de management, orange = chemin critique (pki,
~10 min incompressibles), vert = pool Elastic Metal.

## Les phases en bref

| Phase | Lieu | Commande | Reference |
|-------|------|----------|-----------|
| 0 | Laptop (podman) | `make bootstrap` | [Bootstrap](bootstrap.md) |
| 1 | Scaleway (1x par org, image 1x par region) | `make scaleway-iam-apply`, `make scaleway-image-apply` | `envs/scaleway/iam`, `envs/scaleway/image` |
| 2 | VM CI (1 par env) | `make scaleway-ci-apply` | Bug #31 (postmortem 2026-04-30) |
| 3 | Cluster VM | `make scaleway-up` (inclut `k8s-up` en vagues), puis `make oidc-register` | `Makefile`, ADR-028 |
| 4 | Cluster VM (option) | `make kaas-up`, puis `make managed-cluster-apply` par tenant | ADR-020, ADR-025 |
| 5 | Elastic Metal | `modules/em-talos-bootstrap`, puis karpenter-provider-scaleway | ADR-035, ADR-036, LLD-002 |

Points d'ordre non negociables :

- La VM CI possede le Private Network partage et DOIT preceder le cluster
  (`make scaleway-ci-apply` avant `make scaleway-up`, Bug #31).
- `oidc-register` s'execute apres la reconciliation Flux : Hydra est
  Flux-owned (ADR-028), son endpoint admin n'existe qu'apres le day-2
  (Bug #35).
- Le registre de versions (`clusters/management/versions-configmap.yaml`)
  est la source unique partagee entre Flux (`postBuild.substituteFrom`),
  les pins OpenTofu et le manifeste Hauler.

## « D'abord des VM, puis du baremetal ? » — trois reponses

1. **Oui, le bootstrap podman vient d'abord.** Le pod plateforme sur le
   laptop (OpenBao KMS + vault-backend) stocke tous les etats OpenTofu et
   genere la PKI root CA : sans lui, aucun `tofu init` ne fonctionne, quel
   que soit le provider.
2. **Oui, le cluster de management tourne sur VM ensuite.** La VM CI (qui
   possede le reseau prive partage) puis le cluster Talos sur instances
   Scaleway (DEV1-M/L) viennent avant tout baremetal. C'est ce cluster VM
   qui heberge Flux, le registre d'artefacts et, en phase 2, le
   karpenter-provider-scaleway qui pilote le metal.
3. **Le baremetal n'est jamais un second cluster.** Les serveurs Elastic
   Metal sont pre-images Talos (`modules/em-talos-bootstrap` : Ubuntu
   jetable → rescue → wipe → dd de l'image metal → `talosctl apply-config`
   avec provider-id), laisses eteints dans un pool statique tagge, puis
   allumes/eteints par karpenter-provider-scaleway. Ils REJOIGNENT le
   cluster VM existant comme workers du pool `metal` (taint
   `st4ck.io/pool=metal`) ; Kyverno y route les workloads soutenus
   (> 1 h). Le baremetal depend donc du cluster VM (il le rejoint) et du
   registre/Hauler pour ses artefacts — jamais l'inverse.
