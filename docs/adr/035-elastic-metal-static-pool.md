# ADR-035 : Elastic Metal — pool statique en attendant le support CAPI (révision ADR-024)

**Date** : 2026-07-11
**Statut** : Proposé (amende ADR-024)
**Décideurs** : Équipe plateforme
**Reliés à** : ADR-019 (Matchbox bare metal on-prem), ADR-024 (autoscaling hybride cloud/bare metal), ADR-025 (Kamaji/NodePools)

## Contexte

L'ADR-024 propose un modèle inversé : cloud VM en première intention, bare
metal activé par consolidation Karpenter quand un workload est soutenu
(> 1-2 h), via la chaîne Karpenter → provider CAPI → infrastructure provider
Scaleway. L'investigation du 2026-07-11 a vérifié chaque maillon de cette
chaîne contre l'état réel de l'upstream.

## Constats vérifiés (2026-07-11)

| Maillon | État | Verdict |
|---|---|---|
| cluster-api-provider-scaleway (CAPS) | v0.2.2 (2026-07-07), API v1alpha2. `ScalewayMachine` ne provisionne que des **Instances** (`commercialType`) — **aucun champ Elastic Metal**, aucune issue/roadmap EM | **Bloquant** : Karpenter→CAPI ne peut pas créer d'EM |
| karpenter-provider-cluster-api | v0.2.0, « experimental proof of concept » auto-déclaré. Scale des MachineDeployments labellisés ; scale-from-zero via annotations de capacité manuelles ; pas de modèle de coût CAPI | Immature, mais agnostique — fonctionnerait si CAPS exposait l'EM |
| Talos sur Elastic Metal | Pas de guide officiel (le guide Scaleway ne couvre que les Instances, plateforme `scaleway` = metadata Instances). Chemin éprouvé : **rescue mode + `dd`** de l'image Image Factory `metal-amd64.raw.xz` (plateforme `metal`), réseau fourni par machineconfig | Faisable, scriptable, mais manuel — on possède l'intégration |
| Caractéristiques opérationnelles EM | Livraison < 2 min mais **install OS jusqu'à ~1 h** ; facturation **horaire ou mensuelle** (pas de per-second, conversion monthly→hourly = réinstall) ; **aucune API de warm pool/réservation** ; PN privés supportés (8/serveur, IPAM) mais **par AZ** | Incompatible avec un scale-up réactif |

Conclusion : **l'autoscaling Elastic Metal réactif est infaisable aujourd'hui**,
doublement — le provider CAPI ne sait pas le piloter, et même s'il le savait,
~1 h de provisioning + facturation horaire sans warm pool défont l'économie
d'un scale-up à la demande.

## Décision

1. **Geler le volet Elastic Metal autoscalé de l'ADR-024** (qui reste la
   cible long terme). Les NodePools Karpenter existants (burst/general/
   compute/memory/gpu) continuent de ne piloter que des Instances.
2. **Court terme : pool statique EM pré-provisionné.**
   - Implémentation : **`modules/em-talos-bootstrap`** (« Option A »,
     déjà commité avec harnais smoke P15 sur EM-A116X-SSD fr-par-2).
     Le provider Scaleway refuse `install = null` sur
     `scaleway_baremetal_server`, donc le module installe un Ubuntu
     jetable (serveur sous state TF), puis : reboot rescue → wipe guardé
     (refuse d'écraser un disque déjà flashé Talos) → `curl | xz -d | dd`
     de l'image Factory → reboot disque → attente port 50000 →
     `talosctl apply-config --insecure` (worker, plateforme `metal`).
     C'est le handoff Talos normal — le même point où CAPT échoue en le
     traitant comme une erreur (issue
     tinkerbell/cluster-api-provider-tinkerbell#467).
   - Rattachement au **PN partagé de l'env, dans la même AZ** (contrainte
     PN-par-AZ vérifiée avant commande du serveur).
   - Nœuds labellisés `st4ck.io/pool=metal` + taint dédié.
   - Améliorations candidates issues de l'investigation 2026-07-11 :
     remplacer le `curl | xz | dd` du step 3 par l'action Tinkerbell
     standalone **image2disk** (`quay.io/tinkerbell/actions/image2disk`,
     env `IMG_URL`/`DEST_DISK`/`COMPRESSED` — dd durci : retry à backoff,
     progression, multi-format xz/zstd) ; et harvester la version Talos +
     schematic depuis `contexts/_defaults.yaml` /
     `envs/scaleway/image/variables.tf` au lieu de les passer en dur.
3. **Le déclencheur « > 1 h » devient une décision de scheduling, pas de
   provisioning** : les workloads longs s'annoncent par annotation, une
   policy Kyverno (stack security) mute affinity/toleration vers le pool
   metal. Pas de migration réactive de pods en cours d'exécution
   (eviction = redémarrage ; inacceptable par défaut, surtout sur PVC
   local-path node-local).
4. **Dimensionnement du pool** : N serveurs allumés facturés à l'heure
   (warm pool assumé) ; bascule en mensuel si la charge est soutenue —
   la conversion horaire→mensuel est sans interruption, l'inverse non.
5. **Tinkerbell : le stack est écarté, ses primitives d'imaging sont
   reprises.** Vérifié (v0.23.0, monorepo consolidé) :
   - **Smee** (DHCP/PXE) exige le contrôle de la chaîne de boot — Scaleway
     la possède. **Rufio** (virtual media) exige un BMC Redfish/IPMI
     pilotable — l'« accès distant » EM est un KVM-over-IP à sessions
     limitées (~48 h), pas un Redfish scriptable (contrairement aux
     Dedibox). Deux blocages durs.
   - **CAPT** hérite du besoin PXE, n'a aucun modèle d'adoption de machine
     déjà provisionnée, et ne supporte pas Talos (issue #467 ouverte sans
     résolution).
   - En revanche les **actions Tinkerbell sont des images OCI autonomes**
     (env vars, aucun Tink server requis) : `image2disk` est retenue comme
     primitive d'imaging dans le rescue mode (séquence ci-dessus). Le
     pattern « agent dans un OS déjà booté qui exécute des actions
     conteneurisées » est exactement ce que le rescue Scaleway permet.
   - En colo/on-prem (où l'on possède DHCP/PXE), l'ADR-019 (Matchbox) reste
     le chemin retenu ; Tinkerbell complet n'y serait réévalué que pour un
     parc hétérogène avec BMC.
6. **Action upstream** : ouvrir une issue sur scaleway/cluster-api-provider-scaleway
   pour jauger l'intention d'un support Elastic Metal.

## Critères de réouverture du volet autoscalé

Réévaluer (et réactiver l'ADR-024 tel quel) quand **les deux** conditions
sont réunies :

1. CAPS expose l'Elastic Metal dans `ScalewayMachine`/`ScalewayMachineTemplate` ;
2. karpenter-provider-cluster-api sort du statut proof-of-concept (release
   stable, scale-from-zero sans annotations manuelles).

Le warm pool restera nécessaire même alors, tant que l'install EM se compte
en dizaines de minutes.

## Conséquences

- Le pattern « workload long → metal » est livrable maintenant, avec des
  briques déjà en place (Kyverno, PN partagé, Image Factory, taints/pools
  ADR-025) et un périmètre de code réduit : un script d'install + une policy
  Kyverno + un template de labels.
- Coût assumé : capacité idle facturée à l'heure — à dimensionner petit
  (1-2 serveurs) et à convertir en mensuel dès que l'occupation le justifie
  (break-even ~2-4 cœurs dès la première heure, cf. roadmap Phase G).
- La dette est explicitement upstream, traçable via l'issue CAPS, au lieu
  d'être une intégration maison fragile (pilotage EM hors CAPI) qu'il
  faudrait jeter le jour où CAPS rattrape.
