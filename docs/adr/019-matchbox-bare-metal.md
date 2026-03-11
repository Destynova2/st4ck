# ADR-019 : Matchbox pour le provisioning bare metal / VM degradees

**Date** : 2026-03-11
**Statut** : Planifie (Gate 1.7+ / VMware air-gap)
**Decideurs** : Equipe plateforme

## Contexte

Le provisioning Talos en environnement air-gapped (VMware, bare metal) repose actuellement sur des scripts shell qui generent des OVA avec image cache embarque et des configs YAML par noeud avec IPs statiques. Cette approche ne scale pas au-dela de quelques noeuds.

## Probleme

- **Scripts manuels** : `gen-configs.sh` genere un fichier YAML par noeud (IPs codees en dur)
- **Pas de PXE/iPXE** : chaque noeud necessite un deploy OVA manuel via vSphere
- **Pas de discovery** : les noeuds ne s'enregistrent pas automatiquement
- **VM degradees** : certains environnements n'ont pas d'API vSphere (Morpheus, portails limites)

## Decision

**Matchbox** (CoreOS/Poseidon) comme serveur de provisioning bare metal et VM :

### Qu'est-ce que Matchbox

- Serveur HTTP/gRPC qui sert des profils iPXE, Ignition et cloud-init
- Matching basé sur les attributs machine (MAC, UUID, labels)
- Supporte Talos nativement (profils `talos-install`)
- Leger (~10 MB, Go, single binary)

### Architecture cible

```
DHCP (existant) → iPXE → Matchbox → Profil Talos
                                       ├── kernel + initrd (Talos)
                                       ├── machine config (par groupe/noeud)
                                       └── image cache (air-gap)
```

### Integration

- **Matchbox sur la VM CI** : meme VM que Gitea + Woodpecker (Podman Quadlet)
- **DHCP relay** : pointe `next-server` vers Matchbox pour iPXE
- **Groupes** : `controlplane` (3 noeuds) et `worker` (N noeuds), matching par MAC
- **Profiles Talos** : machine config template avec variables (IP, hostname, role)

## Avantages par rapport a l'approche actuelle

| Critere | Scripts actuels | Matchbox |
|---|---|---|
| Ajout d'un noeud | Modifier vars.env + regenerer | Ajouter MAC dans le groupe |
| PXE boot | Non (OVA manuel) | Oui (iPXE natif) |
| Discovery | Non | Oui (MAC matching) |
| Air-gap | OVA + image cache | Kernel/initrd + image cache servis par Matchbox |
| Scale | ~10 noeuds max | Centaines de noeuds |

## Consequences

### Positives

- Provisioning zero-touch (PXE boot → Talos installe → rejoint le cluster)
- Scale au-dela de 10 noeuds sans effort
- Compatible bare metal, VM degradees, et environnements sans API vSphere
- Matchbox est leger et s'integre dans le pod CI existant

### Negatives

- Necessite un DHCP relay configure (reseau)
- Matchbox est un composant supplementaire a operer
- iPXE peut ne pas etre disponible sur certains firmwares (UEFI secure boot)

## Pre-requis

1. DHCP avec option `next-server` configurable
2. Reseau L2 entre Matchbox et les noeuds cibles (ou DHCP relay)
3. Images Talos kernel + initrd disponibles localement (air-gap)

## Reconsiderer si

- L'API vSphere devient disponible (CAPV + Terraform suffisent)
- Moins de 10 noeuds (les scripts actuels suffisent)
