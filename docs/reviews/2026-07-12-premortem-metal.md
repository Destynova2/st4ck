# Pré-mortem — stack metal Karpenter (avant merge et engagement serveurs)

> **ERRATUM (2026-07-12, post-publication)** — Le scénario G4/§1.1 (« les deux
> cerveaux ») est **infirmé** par vérification des sources karpenter-core
> v1.14 : `nodeclaimutils.IsManaged` et `nodepoolutils.IsManaged` filtrent
> NodeClaims **et** NodePools par `nodeClassRef.GroupKind()` contre
> `GetSupportedNodeClasses()` — GC, provisioner et watches inclus. Deux cores
> à NodeClass disjointes se partitionnent donc par design ; il n'y a ni
> suppression croisée par ICE ni GC croisé. Les risques réels de cohabitation
> sont ailleurs : (1) **CRDs karpenter.sh partagées** installées par le chart
> karpenter de `stacks/autoscaling` pinné **1.3.3**, alors que le provider EM
> est bâti sur core v1.14 et que les NodePools statiques (`spec.replicas`)
> exigent un schéma CRD récent — prérequis de déploiement : monter le chart ;
> (2) double réaction aux pods Pending si les pools se recouvrent (mitigé par
> le taint metal) ; (3) le finding Codex « NodeClass manquante → ICE » reste
> un vrai bug, mais confiné au domaine EM — ce n'est pas une « arme »
> inter-providers. Le bloquant merge « cohabitation » est requalifié en
> prérequis d'intégration (alignement de versions CRD + vérification e2e).

**Date** : 2026-07-12
**Cibles** : `docs/design/002-karpenter-scaleway-em.md` (LLD-002), ADR-035, ADR-036,
`modules/em-talos-bootstrap/`, worktree `karpenter-provider-scaleway`
(branche `feat/karpenter-provider-scaleway`, HEAD `0c234e4`)
**Mode** : blueprint résilience complet — modes de défaillance, injections de panne,
budget de rupture, runbook
**Méthode** : analyse statique (code + docs). Aucun serveur EM réel n'a été touché ;
tout constat matériel reste une hypothèse à prouver en T2.
**Score résilience** : 17/60 — critique *en l'état* (normal pour un spike M0 ;
la barre 45/60 est la barre de mise en prod, pas celle du merge d'un spike).

---

## 0. Verdict et portes de décision

Deux décisions distinctes, deux portes distinctes :

| Décision | Verdict | Conditions |
|---|---|---|
| **Merge du spike** | **Conditionnel** | Lever les 3 bloquants code/architecture (§12 Tier 3 : cohabitation karpenter-core, garde d'appartenance au pool dans `Delete()`, CI minimale). Le squelette + 26 tests unitaires sont sains et mergeables ensuite. |
| **Achat / engagement serveurs** | **Non — pas encore** | Exécuter d'abord les critères matériels M0 n°1 et n°2 (denylist `provider-id` Talos, latence power-on→Ready p95 < 12 min ×5) **sur un EM loué à l'heure** (~1-2 € au cap du harnais P15). Un engagement mensuel avant ces mesures parie l'architecture entière sur une constante non configurable de 15 min. |

Rappel économique (ADR-035) : un EM arrêté reste facturé. « Acheter » = s'engager
sur une capacité facturée 24/7, éteinte ou allumée ; la conversion
horaire→mensuel est sans retour (l'inverse = réinstallation).

---

## 1. Scénarios pré-mortem — nous sommes le 12 janvier 2027, la stack est morte

Cinq récits, classés par plausibilité × dégâts. Chacun renvoie aux modes de
défaillance du §4 et aux garde-fous du §12.

### 1.1 Les deux cerveaux (G4 — le plus probable, dès le premier déploiement)

Le provider EM a été déployé sur le cluster de management, à côté de la stack
`autoscaling/` existante — qui installe déjà **karpenter-core** (chart
`oci://public.ecr.aws/karpenter`) **et** `karpenter-provider-cluster-api`,
chacun embarquant sa propre boucle core. karpenter-core ne connaît aucun
concept de partition : chaque instance réconcilie **tous** les
NodePools/NodeClaims `karpenter.sh/v1` du cluster. Résultat observé :
le core EM tente `Create()` sur un NodeClaim à NodeClass CAPI, ne trouve pas
la `ScalewayEMNodeClass` et répond `InsufficientCapacityError`
(`cloudprovider.go:72-74`) — ce qui **supprime le NodeClaim** de l'autre
provider. Symétriquement, le GC du core CAPI ne voit jamais les serveurs EM
dans son `List()` et efface les NodeClaims metal. Les deux cerveaux se
garbage-collectent mutuellement ; les nœuds churnent en continu ; personne ne
comprend car chaque contrôleur, pris isolément, « fonctionne ».

### 1.2 La boucle de la mort à 15 minutes (B1/G1)

Le POST de la gamme achetée prend 13 à 17 minutes selon l'humeur du firmware —
jamais mesuré avant l'achat. Séquence : `Create()` → power-on → le nœud rate
la fenêtre `registrationTimeout = 15 min` (constante non configurable,
`liveness.go`) → NodeClaim supprimé → `Delete()` → power-off → le NodePool
statique recrée un NodeClaim → power-on du même serveur. **Cycle thermique
d'un serveur bare metal toutes les ~18 minutes, tout un week-end.** Variante
logicielle : un octet de différence entre le `provider-id` du machineconfig
pré-imagé et `pool.FormatProviderID()` produit exactement la même boucle —
et le nœud non matché a rejoint le cluster **sans le taint du NodePool**
(les taints du template sont posés via le NodeClaim) : des pods ordinaires
s'y schedulent, puis meurent au power-off suivant.

### 1.3 L'érosion silencieuse (P1/O6)

Mars 2027 : une maintenance Scaleway laisse 2 serveurs sur 3 en statut
`error`. `PoweredOn()` les classe éteints ; ils sortent de `List()`, le GC
nettoie ; `available` compte uniquement les `stopped`, `PoolReady` reste
`True` tant qu'il existe ≥ 1 serveur taggé. Aucune métrique, aucune alerte
(M1). Trois mois plus tard, jour de pic : replicas 0→3, un seul serveur
monte. Les pods metal restent Pending — et comme le scale des replicas est
**manuel** en M0, personne ne sait s'il faut blâmer l'opérateur, le pool ou
Kyverno. La capacité payée depuis six mois était morte depuis mars.

### 1.4 Le serveur fantôme (S1)

Le projet Scaleway `st4ck` est unique pour dev/staging/prod, et l'IAM du
contrôleur est `ElasticMetalFullAccess`. `Delete()` parse le providerID du
NodeClaim et appelle `StopServer` **sans jamais vérifier que le serveur porte
le tag du pool** (`cloudprovider.go:104-130`). Un NodeClaim corrompu, forgé,
ou un copier-coller malheureux d'UUID suffit : le provider dev éteint
proprement un EM de prod du même projet. L'API a fait exactement ce qu'on lui
a demandé ; les logs du provider affichent un `Delete` nominal.

### 1.5 Le pool momifié (O2/O5/G2)

Les serveurs ont été pré-imagés avec le défaut du module : Talos **v1.10.4**
(`modules/em-talos-bootstrap/variables.tf:37`) alors que la plateforme est en
**v1.12.4** (`contexts/_defaults.yaml:14`). Le pool dort éteint ; le cluster,
lui, vit : deux upgrades Kubernetes plus une reconstruction DR (nouveau CA,
nouveau endpoint) plus tard, plus aucun membre du pool ne peut joindre —
kubelet hors fenêtre de skew, machineconfig pointant un cluster mort, certs
kubelet périmés. Remise en service = re-imaging complet (rescue + dd) de
chaque serveur, un dimanche, sous pression.

---

## 2. Carte des surfaces de défaillance

| Surface | Source de vérité | Première sonde discriminante | Rayon d'impact |
|---|---|---|---|
| Imaging EM (rescue + dd) | `modules/em-talos-bootstrap/main.tf` | `nc -zw5 <ip> 50000` après reboot normal | 1 serveur (réinstall ~1 h) |
| Contrat providerID | `pkg/pool/providerid.go` **et** machineconfig pré-imagé (dupliqué) | `kubectl get node <n> -o jsonpath='{.spec.providerID}'` vs ID API | boucle churn + nœud non taint |
| Inventaire pool (tag) | tags serveurs Scaleway (`poolTag`) | `scw baremetal server list zone=<z> tags.0=<tag>` | tout le pool |
| Boucles karpenter-core | déploiements en NS `autoscaling` + provider EM | `kubectl get deploy -A \| grep -i karpenter` (compter les cores) | tous les NodeClaims du cluster |
| API Scaleway baremetal | SDK v1.0.0-beta.36, pas de rate limit publié | logs provider : erreurs 429/5xx | scale up/down gelé |
| CRD `ScalewayEMNodeClass` | types Go + YAML maintenus à la main | diff controller-gen vs `config/crd/` | champs silencieusement ignorés |
| Identité / IAM | app IAM `ElasticMetalFullAccess`, projet unique | audit IAM Scaleway | tous les EM du projet, tous envs |
| Réseau (PN par-AZ, IP flexible) | IPAM + PN partagé env | ping PN + SANs cert talosctl après power cycle | join kubelet, endpoints talosctl |
| Économie | facturation EM (éteint = facturé) | facture Scaleway mensuelle | budget |
| Observabilité | rien en M0 (conditions + events seulement) | `kubectl get scwemnc -o yaml` | détection tardive de tout le reste |

---

## 3. Génome — faits opérationnels dupliqués (dérive détectée)

| Invariant | Source de vérité | Autres occurrences | Dérive constatée / risque | Vérification |
|---|---|---|---|---|
| Version + schematic Talos | `contexts/_defaults.yaml` (`v1.12.4`) + `envs/scaleway/image/variables.tf` | défaut `talos_image_url` du module (**v1.10.4**, schematic vanilla) ; harnais smoke | **Dérive réelle aujourd'hui** — deux mineures d'écart | grep croisé en T0 ; harvest depuis contexts (déjà proposé par ADR-035) |
| Format providerID `scaleway-em://<zone>/<id>` | `pkg/pool/providerid.go` | machineconfig pré-imagé (kubelet extraArgs), écrit par un autre outil | mismatch d'un octet = boucle 1.2 | test T0 de rendu croisé + assertion E2E T2 |
| Tag pool `st4ck.io/karpenter-pool=…` | spec CRD `poolTag` | tags posés par le module TF / à la main | serveur détaggé = invisible ; taggé à tort = pilotable | T3 : mutation tag |
| Offre `EM-A116X-SSD` | spec CRD `offerName` | `OfferName` des serveurs, catalogue Scaleway (EOL possible) | offre renommée/EOL → `OfferNotFound` → pool Ready=False au restart | T4 : mutation offre |
| Nombre de karpenter-core | *aucune source ne le fixe* | `stacks/autoscaling` (core + CAPI provider) + futur provider EM | **invariant absent des docs** — cf. 1.1 | à écrire dans l'ADR avant merge |
| Taint `st4ck.io/pool=metal` | template NodePool (LLD §7) | absent du machineconfig pré-imagé | nœud non matché rejoint **sans** taint | ajouter aux `registerWithTaints` du machineconfig |

---

## 4. Catalogue des modes de défaillance

Probabilité : H/M/B. Impact : H/M/B.

### 4.1 Génome / architecture (G)

| ID | Mode | Cause | P | I | Signal précoce | Garde-fou |
|---|---|---|---|---|---|---|
| G1 | Boucle churn providerID | mismatch octet machineconfig ↔ provider | M | H | NodeClaims dont l'âge ne dépasse jamais ~15 min | test rendu croisé T0 + E2E T2 |
| G2 | Pool imagé en Talos v1.10.4 | défaut du module ≠ contexts | H | M | grep versions | harvest contexts (Tier 2) |
| G3 | Champ CRD silencieusement ignoré | deepcopy/CRD à la main | M | M | diff controller-gen | regen en CI (T0) |
| G4 | Double/triple karpenter-core | stack autoscaling déjà propriétaire du core | **H** | **H** | churn NodeClaims croisé dès le déploiement | invariant « 1 core/cluster » + décision de cohabitation (Tier 3) |

### 4.2 Boot / imaging (B)

| ID | Mode | Cause | P | I | Signal précoce | Garde-fou |
|---|---|---|---|---|---|---|
| B1 | POST > 15 min → boucle de la mort | constante `registrationTimeout` | M | H | mesure p95 M0 jamais faite | **gate d'achat** : mesure ×5 sur EM horaire ; repli pool tiède |
| B2 | Boot sur le 2e disque (GRUB/RAID résiduel) | wipe du 1er disque seulement (`main.tf:129-148`) ; l'Ubuntu jetable installe potentiellement un RAID md sur 2 disques | M | M | serveur `ready` mais port 50000 muet, console KVM sur grub | wiper **tous** les disques en step 2 ; valider sur l'offre réelle en smoke |
| B3 | Image Talos corrompue au dd | `curl \| xz -d \| dd` sans checksum (`main.tf:186`) | B | M | boot en panique, port 50000 muet | vérifier le SHA512 Factory avant dd |
| B4 | Rescue SSH indisponible | clé IAM ≠ clé locale ; incident rescue Scaleway | M | B | timeout step 1 (10 min) | pré-check clé ; réessai documenté |
| B5 | IP flexible / booking IPAM perdus après arrêt long | hypothèse « persiste aux power cycles » jamais testée en durée | M | H | SANs cert invalides, join qui boucle | test T3 arrêt long ; sonde IP à chaque power-on |
| B6 | factory.talos.dev indisponible au ré-imaging | dépendance externe non miroir | B | M | échec step 3 en pleine DR | miroir de l'image dans arbor/Garage |

### 4.3 Runtime provider (P)

| ID | Mode | Cause | P | I | Signal précoce | Garde-fou |
|---|---|---|---|---|---|---|
| P1 | Érosion silencieuse (serveurs `error`) | `error` = « éteint », aucun compteur exposé | H | H | `available` < poolSize − allumés | métrique + alerte + condition dédiée (Tier 2) |
| P2 | Offre EOL/renommée | cache offre « forever » masque jusqu'au restart, puis `Ready=False`, `GetInstanceTypes` en erreur | B | H | changelog Scaleway | runbook + test mutation offre ; ne jamais dériver en suppression de type (règle LLD §3) |
| P3 | 429 / panne API Scaleway | pas de backoff M0 ; `List()` du GC **non caché** (`cloudprovider.go:169`) contrairement à `GetInstanceTypes` | M | M | erreurs SDK en rafale dans les logs | plateau : nœuds vivants intacts ; backoff M1 ; cacher List() |
| P4 | Double power-on (claim) | `claimTTL = 2 min` < latence de propagation `stopped→starting`, ou restart contrôleur (map en mémoire) | B | B | erreur API « cannot start » | test T3 restart contrôleur ; TTL ≥ propagation mesurée |
| P5 | Power-off hors bande = perte sèche des pods | GC ~2 min **sans drain** (sémantique assumée LLD §3) | M | M | NodeClaim disparu sans événement de drain | procédure maintenance §9.5 ; à assumer par écrit dans le runbook |
| P6 | replicas > taille du pool | ICE en boucle douce sur le dernier claim | M | B | events ICE répétés | `Available=false` couvre le gros ; documenter la limite |
| P7 | NodePool statique inopérant | `spec.replicas` (design static-capacity) absent/derrière feature gate sur le core v1.14 déployé | M | H | replicas ignorés au premier T2 | vérification explicite au T2 (feature gate) |

### 4.4 Day-2 / opérations (O)

| ID | Mode | Cause | P | I | Signal précoce | Garde-fou |
|---|---|---|---|---|---|---|
| O1 | La plateforme rallume ce que l'opérateur éteint | replicas statiques : GC → nouveau NodeClaim → re-claim du serveur `stopped` | H | M | serveur qui « refuse » de rester éteint | procédure : détagger avant maintenance (§9.5) |
| O2 | Kubelet hors skew après upgrades cluster | pool éteint jamais upgradé (aucun process défini) | H | H | version kubelet vs API server | cadence « allumer-upgrader-éteindre » à chaque upgrade cluster (Tier 2) |
| O3 | Certs kubelet périmés après arrêt > ~30 j | rotation cert client ; « Talos re-bootstrappe au boot » = hypothèse LLD §10 à prouver | M | H | join refusé, CSR en attente | test T4 horloge avancée (déjà prévu M0-REPORT §3.2.4) |
| O4 | Horloge fausse au boot après arrêt long | RTC dérivé + NTP injoignable | B | M | erreurs TLS x509 « not yet valid » | sonde NTP au boot ; test T4 |
| O5 | DR : cluster reconstruit, pool orphelin | machineconfig pré-imagé fige CA/endpoint/token | M | H | join impossible après DR | chemin « ré-imaging pool » dans docs DR (Tier 2) |
| O6 | Pods metal Pending pour toujours | scale replicas **manuel** en M0, non outillé, non alerté | H | M | pods Pending avec toleration metal > 15 min | alerte Pending + runbook §9.3 ; KEDA en M1 |
| O7 | Policy Kyverno absente/cassée | routage metal = mutation d'annotation (ADR-035 §3) | M | M | workloads longs sur VMs | test policy dans la stack security |

### 4.5 Sécurité (S)

| ID | Mode | Cause | P | I | Signal précoce | Garde-fou |
|---|---|---|---|---|---|---|
| S1 | Power-off d'un EM hors pool | `Delete()` sans vérification du tag pool ; projet unique multi-env ; `ElasticMetalFullAccess` | B | **H** | aucun (le Delete est « nominal » dans les logs) | **garde tag avant StopServer** (Tier 3, ~5 lignes + test) |
| S2 | Secrets machineconfig exposés à l'apply | `talosctl apply-config --insecure` sur IP publique (`main.tf:235`) | B | M | — | appliquer via PN / CI VM (Tier 2) |
| S3 | Credentials SCW volés dans le cluster | `SCW_*` en env du pod, portée projet entier | B | H | audit IAM | app IAM dédiée au pool, scope minimal possible |

### 4.6 Économie (E)

| ID | Mode | Cause | P | I | Signal précoce | Garde-fou |
|---|---|---|---|---|---|---|
| E1 | « Éteint = gratuit » supposé par un futur mainteneur | intuition cloud ≠ facturation EM | H | M | facture | déjà martelé partout ; garder le caveat dans le README du chart M1 |
| E2 | Conversion mensuelle prématurée | irréversible sans réinstall | M | M | taux d'occupation | règle : convertir après ≥ 1 mois d'occupation mesurée |
| E3 | Zone unique fr-par-2 | contrainte PN-par-AZ | B | H | incident zone | assumé (ADR-035) ; drill papier §8 |

---

## 5. Budget de rupture

Les budgets quantifiés dont l'épuisement change qualitativement le comportement
(transition de phase). Toute PR touchant l'un d'eux doit citer ce tableau.

| Budget | Valeur | Source | Rupture si dépassé | Preuve exigée |
|---|---|---|---|---|
| Fenêtre d'enregistrement | **15 min, constante non configurable** | karpenter-core `liveness.go` (LLD C1) | boucle de la mort 1.2 | p95(power-on→Node Ready) < **12 min** ×5 runs (marge 3 min) — **gate d'achat** |
| Post-enregistrement | ∞ (aucun timeout) | LLD C1 | pas de rupture, mais zombie `Initialized=False` possible | sonde runbook §9.2 |
| `claimTTL` | 2 min | `cloudprovider.go:41` | double power-on si propagation API > 2 min | mesurer la latence `StartServer→status starting` en T2 |
| Fenêtre GC hors bande | ~2 min | LLD §3 | perte de pods **sans drain** (P5) | assumé par écrit + procédure §9.5 |
| Polling API | ≤ 1 req/10 s/serveur ; inventaire TTL 10 s ; nodeclass 1/min ; **List() GC non caché** | LLD §8, `main.go:21`, `controller.go:27` | 429 en rafale (P3) | télémétrie M1 ; cacher List() |
| Session console KVM | ~48 h | ADR-035 | perte du seul accès de debug bas niveau en incident long | noter l'heure d'ouverture dans le journal d'incident |
| Coût pool | ~0,077 €/h/serveur (EM-A116X-SSD), **éteint ou allumé** ≈ 55 €/mois/serveur | commentaires module | ~166 €/mois pour 3 serveurs idle | revue coût mensuelle ; conversion mensuelle = one-way (E2) |
| Skew kubelet | n−3 mineures vs API server | politique K8s | pool momifié 1.5 | cadence upgrade pool ≥ 1 allumage par upgrade cluster |
| Certs kubelet | rotation ~≤ 30 j (à confirmer) | risque LLD §10 | join refusé après arrêt long | test horloge (T4) |
| Timeouts imaging | rescue 10 min ; Talos 5 min (défauts module) | `variables.tf:66-77` | échec bootstrap (faux négatif si POST lent) | recaler après mesure réelle |
| Ré-imaging complet | ~1 h/serveur (install catalogue) + dd | ADR-035 | durée de la fenêtre DR (O5) | drill DR chronométré |
| `expireAfter` | **Never** obligatoire (défaut 720 h) | LLD §5 | remplacement forcé de nœuds metal à 30 j | assertion T0 sur le manifest NodePool |

---

## 6. Matrice de parité prod (membrane)

Ce que l'environnement de validation actuel (fake in-memory + docs) prouve,
contre ce que la prod métal exigera.

| Axe | Observé aujourd'hui | Attendu en prod | Écart | Risque |
|---|---|---|---|---|
| Matériel | `FakeBackend` : transitions instantanées, POST inexistant | POST 5-20 min, firmware capricieux, disques multiples | **Total** | B1, B2 |
| Cycle de puissance | transitions contrôlées par le test | latences API réelles, états `error` spontanés | Total | P1, P4 |
| Réseau | aucun (tests sans réseau, voulu) | PN par-AZ, IP flexible, IPAM booking, NTP | Total | B5, O4 |
| Identité | env vars locales | IAM app dans le cluster, projet unique multi-env | Élevé | S1, S3 |
| Denylist kubelet Talos | non testée | décide Option A vs B (formats providerID différents) | **Bloquant M0** | G1 |
| Données | aucune (provider stateless — bon point) | idem | Nul | — |
| Dépendances externes | aucune | API baremetal (beta SDK), factory.talos.dev, catalogue offres | Total | P2, P3, B6 |
| Horloge | horloge du test | RTC après semaines d'arrêt | Total | O3, O4 |
| Observabilité | events + conditions | métriques, alertes, dashboards (M1) | Élevé | P1, O6 |
| Orchestrateur | core v1.14.0 en unit test | core v1.14.0 déployé **à côté d'autres cores** | **Élevé** | G4, P7 |

Déviations acceptées explicitement : zone unique (E3, ADR-035), pas de drain
sur power-off hors bande (P5, LLD §3), Allocatable optimiste sans overhead
(M0-REPORT écart 3 — à recaler avec la mesure matérielle).

---

## 7. Échelle de tests — T0 → T4 + M0

Rappel des trois preuves à retenir : **Contrat → Matériel → Vie commune.**
(T0-T1 prouvent le contrat, T2 prouve le matériel, T3-T4 prouvent la vie
commune avec le reste de la plateforme.)

### T0 — Génome (gate de merge, CI)
- `make build && make test && make lint` (existe, **non câblé en CI** — Tier 3).
- Test de rendu croisé providerID : le générateur de machineconfig et
  `pool.FormatProviderID()` produisent la même chaîne pour un même serveur.
- Diff controller-gen vs `config/crd/` committé (G3).
- Grep « une seule source de version Talos » : le module ne doit plus porter
  de défaut d'URL image en dur (G2).
- Assertion sur les manifests : `expireAfter: Never`, taint metal présent,
  nodeClassRef groupe/kind corrects.

### T1 — Organelle
- Build de l'image OCI du contrôleur (n'existe pas encore) + smoke `--help`.
- Les 26 tests unitaires existants (point fort réel : négatifs, course,
  injection d'erreurs, GC hors bande).

### T2 — Tissu (gate d'achat — sur EM **loué à l'heure**, cap ~2 €)
1. Smoke P15 (`examples/smoke/`) : imaging complet rescue→dd→apply-config.
2. **Critère M0 n°1** : denylist `provider-id` Talos v1.12 (décide Option A/B).
3. **Critère M0 n°2** : latence power-on→Ready ×5, p95 < 12 min.
4. **Critère M0 n°4** : E2E replicas 0→1→0 sur cluster dev — vérifie au
   passage P7 (le support `spec.replicas`/feature gate du core déployé).
5. Vérifier B2 sur l'offre réelle : nombre de disques, résidus RAID après wipe.

### T3 — Organisme
- Rerun `tofu apply` sur serveur déjà bootstrappé → no-op (le guard Talos du
  step 2 existe : le prouver).
- Power-off console pendant charge → GC ~2 min → replicas statiques
  rallument : observer le « combat » O1 et valider la procédure detag §9.5.
- Restart du contrôleur pendant un `starting` (perte de la map `claimed`).
- Credentials SCW invalides → `Ready=False`, `Create` refusé proprement,
  nœuds vivants intacts.
- Arrêt long simulé (horloge avancée > 30 j) → re-join (O3).

### T4 — Immunitaire (batterie §8)

### M0 — Mémoire
- Promouvoir le runbook §9 en `docs/runbooks/metal-pool-runbook.md` au merge.
- Entrées blackbox pré-semées §10.
- Chaque incident réel du pool alimente une injection T4 nouvelle.

---

## 8. Batterie d'injections de panne

Règle du silence : une mutation qui devrait casser et passe sans bruit = Tier 3.

| # | Mutation | Signal attendu | Passage silencieux = | Niveau |
|---|---|---|---|---|
| 1 | Muter un octet du `provider-id` dans le machineconfig d'un serveur de test | NodeClaim jamais `Registered`, suppression bruyante à 15 min, événement explicite | nœud non taint qui prend des pods (G1 + risque taint) | T2 |
| 2 | Retirer le tag pool d'un serveur **allumé** | disparition de List() → GC ~2 min, NodeClaim supprimé | serveur zombie facturé, ni piloté ni visible | T3 |
| 3 | Power-off console d'un nœud chargé | GC + rallumage par replicas statiques (O1) documenté | pods perdus sans trace ni procédure | T3 |
| 4 | Forger un NodeClaim avec le providerID d'un EM **hors pool** | `Delete()` refuse (garde tag) | **extinction d'un serveur arbitraire du projet (S1) — aujourd'hui le code passe silencieusement** | T1 (unit) puis T3 |
| 5 | Spoofer `OfferNotFound` (offre renommée) | `Ready=False` lisible ; les nœuds vivants gardent leur type (règle LLD §3) | churn de remplacement des nœuds metal (P2) | T4 |
| 6 | Credentials SCW révoqués à chaud | `Ready=False` reason APIError ; plateau sûr | crash-loop du contrôleur ou churn | T3 |
| 7 | replicas = poolSize + 2 | ICE propre, `Available=false`, pas de boucle chaude | spam Create/Delete → 429 (P6/P3) | T3 |
| 8 | Image Factory tronquée servie au dd | échec bruyant du step 3 (checksum) | panique au boot des semaines plus tard (B3) | T2 |
| 9 | Horloge du serveur avancée de 45 j avant power-on | join OK (re-bootstrap kubelet) ou échec x509 **documenté** | bug temporel invisible jusqu'au premier arrêt long réel (O3/O4) | T4 |
| 10 | Couper l'API Scaleway (DNS blackhole) 30 min | scale gelé, nœuds vivants intacts, reprise propre | GC intempestif ou crash (P3) | T4 |
| 11 | Déployer le provider EM avec la stack autoscaling active (état actuel !) | gate d'install qui refuse, ou décision de cohabitation documentée | destruction croisée des NodeClaims (G4) | T2 |
| 12 | Casser une commande du runbook §9 (chemin, flag) | relecture exécutable du runbook en revue trimestrielle | opérateur suivant des instructions mortes | M0 |

Constat immédiat : la mutation n°4 **passe silencieusement dans le code
actuel** (aucune vérification de tag dans `Delete()`/`Get()`), et la n°11
décrit l'état du repo au moment du merge. Deux Tier 3 confirmés sans toucher
un serveur.

---

## 9. Runbook — pool Elastic Metal Karpenter

Réflexes d'incident : **Capturer → Statut → Matching.**
(1) Capturer l'état avant toute correction. (2) Statut réel côté Scaleway.
(3) Matching providerID octet pour octet. Le budget 15 min explique le reste.

### 9.1 Capture avant correction

```bash
TS=$(date +%Y%m%dT%H%M%S); mkdir -p /tmp/metal-$TS && cd /tmp/metal-$TS
kubectl get nodeclaims -o yaml            > nodeclaims.yaml
kubectl get nodepools -o yaml             > nodepools.yaml
kubectl get scalewayemnodeclasses -o yaml > emnc.yaml
kubectl get nodes -l st4ck.io/pool=metal -o yaml > nodes.yaml
kubectl get events -A --sort-by=.lastTimestamp | grep -i -E 'nodeclaim|karpenter' > events.txt
kubectl -n autoscaling logs deploy/<provider-em> --since=2h > provider.log
scw baremetal server list zone=fr-par-2 -o json > servers.json
```
Refaire **la même capture** après correction ; le diff est la preuve.
Ne jamais supprimer un NodeClaim à la main avant capture (finalizers = la
suppression déclenche un power-off).

### 9.2 Triage rapide

| # | Commande | OK | KO |
|---|---|---|---|
| 1 | `kubectl get scwemnc <n> -o jsonpath='{.status}'` | `Ready=True`, `poolSize`=N, `available`≥0 cohérents | `APIError` (auth/API), `PoolEmpty` (tags), `OfferNotFound` (P2) |
| 2 | `scw baremetal server list zone=<z> -o json \| jq '[.[] \| {name, status}]'` | statuts ∈ {ready, stopped} et comptes = attendu | serveurs `error` (P1) ou comptes ≠ status CRD |
| 3 | `kubectl get nodeclaims` | âges variés, `READY True` | **aucun âge > 15 min** = boucle de la mort (§9.4-A) |
| 4 | `kubectl get node <n> -o jsonpath='{.spec.providerID}'` vs `scaleway-em://<zone>/<server-id>` (ID depuis servers.json) | égalité **octet pour octet** | tout écart = G1 |
| 5 | `kubectl get pods -A --field-selector status.phase=Pending \| grep -c .` puis inspecter les tolerations metal | 0, ou Pending < âge du dernier scale | Pending anciens + replicas non scalés (O6) |
| 6 | `kubectl get deploy -A \| grep -i karpenter` | **un seul** karpenter-core actif | plusieurs cores (G4) — geler, cf. §9.5 |

### 9.3 Arbre de décision

- **A. NodeClaim jamais `Registered` (supprimé vers 15 min)** →
  - serveur pas `ready` à t+12 min (`scw baremetal server get <id>`) :
    POST lent (B1) ou `error` → console KVM ; si récurrent : repli pool tiède
    (serveurs `ready` + cordon, décision LLD §9).
  - serveur `ready`, aucun Node : join Talos KO → `talosctl -n <ip> dmesg`
    (certs O3, horloge O4, PN/IP B5, machineconfig obsolète O5).
  - Node présent mais NodeClaim supprimé quand même : providerID ≠ (G1) —
    triage n°4 est la preuve.
- **B. Pods metal Pending, aucun NodeClaim créé** → replicas non scalés (O6) ;
  sinon `available=0` (pool érodé P1, triage n°2) ; sinon policy Kyverno (O7 :
  `kubectl get clusterpolicy` côté stack security).
- **C. `available=0` alors que des serveurs `stopped` existent** → tags (mutation 2)
  ou zone de la CRD ≠ zone des serveurs.
- **D. Node `NotReady` après power-on réussi** → CNI/kubelet classique, puis
  horloge et certs (O3/O4).
- **E. Un serveur se rallume « tout seul » après extinction console** →
  comportement nominal des replicas statiques (O1) → procédure §9.5.
- **F. Erreurs API en rafale (429/5xx)** → plateau : ne rien redémarrer en
  boucle ; les nœuds vivants ne dépendent pas de l'API. Attendre/backoff.
- **G. Après DR (cluster reconstruit)** → le pool entier est orphelin (O5) :
  ré-imaging par `modules/em-talos-bootstrap` serveur par serveur (~1 h/u),
  après mise à jour du machineconfig (nouveau CA/endpoint).

### 9.4 Confinement

- Geler le pilotage sans perdre l'état : `kubectl -n autoscaling scale deploy/<provider-em> --replicas=0`
  (les serveurs restent dans leur état de puissance courant).
- Ne pas éteindre un serveur par la console pour « aider » : cela déclenche
  GC + rallumage (O1) et détruit les preuves.
- En cas de suspicion G4 (plusieurs cores) : geler **les deux** contrôleurs
  avant analyse, sinon chacun « répare » ce que l'autre observe.

### 9.5 Maintenance matérielle d'un membre du pool (procédure nominale)

1. Retirer le tag pool du serveur (`scw baremetal server update <id> tags=…`)
   → il sort de l'inventaire ; le GC supprimera son NodeClaim (~2 min) **sans
   drain** : d'abord `kubectl drain <node>` si des pods tournent.
2. Baisser `spec.replicas` d'autant si la capacité doit refléter la maintenance.
3. Maintenance (console KVM ≤ 48 h/session).
4. Re-tagger, re-monter replicas.

### 9.6 Anti-régression après correctif

Minimum : `make test` + le test T0 de rendu providerID + redéploiement T2 sur
dev + la mutation §8 correspondant au mode de défaillance corrigé.
Rayon large (toucher au contrat CloudProvider, au machineconfig ou au module
TF) : rejouer T2 complet (smoke P15 + E2E 0→1→0).

### 9.7 Critères de clôture

- symptôme et premier signal utile capturés (§9.1 avant/après) ;
- cause racine localisée sur une surface du §2 ;
- source de vérité corrigée (pas le symptôme) ;
- garde-fou durable ajouté (test, gate, entrée runbook/blackbox) ;
- niveaux d'échelle concernés rejoués ;
- entrée blackbox écrite (§10).

---

## 10. Mémoire / blackbox — entrées à pré-semer

| Incident anticipé ou constat | Garde-fou manquant | Test à ajouter | Delta runbook |
|---|---|---|---|
| G4 cohabitation karpenter-core (constat, repo actuel) | invariant écrit nulle part | injection §8-11 | §9.2-6, §9.4 |
| S1 StopServer hors pool (constat, code actuel) | garde tag | mutation §8-4 en unit test | — |
| Boucle de la mort (anticipé) | mesure p95 jamais faite | T2 critère 2 | §9.3-A |
| Érosion silencieuse (anticipé) | zéro métrique | alerte `available`/`error` | §9.2-1/2 |
| Pool momifié post-DR (anticipé) | chemin DR absent des docs DR | drill G §9.3 | docs/how-to/disaster-recovery.md |

Postmortems existants à relier : `docs/reviews/2026-04-25-mgmt-deploy-postmortem.md`
(leçon « ordre de déploiement »), `2026-04-26-bao-seal-key-postmortem.md`
(leçon « hypothèse de persistance non testée » — même famille que B5/O3).

---

## 11. Scores — 15 dimensions

| # | Dimension | Score /4 | Preuve | Manque |
|---|---|---|---|---|
| D1 | Génome des contrats | 1 | formats centralisés dans `pkg/pool` | providerID dupliqué sans test croisé ; Talos v1.10.4 vs v1.12.4 |
| D2 | Parité de frontière | 1 | contraintes C1-C3 explicites, écarts assumés dans M0-REPORT | zéro validation matérielle |
| D3 | Reproductibilité build | 2 | go.mod pinné, build propre | pas d'image OCI, pas de CI |
| D4 | Déploiement frais | 0 | — | jamais déployé (critère 4 non exécuté) |
| D5 | Rerun / hystérésis | 2 | guard wipe Talos, Delete idempotent, claim TTL — testés | provisioners TF fragiles par nature ; restart contrôleur non testé |
| D6 | Homéostasie | 1 | conditions Ready + events | aucune métrique ; érosion invisible |
| D7 | Fidélité des chemins réseau | 1 | chemins nommés dans le LLD | persistance PN/IP non prouvée ; apply-config via IP publique |
| D8 | Secrets / identité / rôles | 1 | auth standard `scw.WithEnv` | FullAccess projet multi-env ; pas de garde tag |
| D9 | Données / récupération | 1 | provider stateless (bon choix) | chemin DR du pool non écrit |
| D10 | Observabilité / premier signal | 1 | events core | premier signal documenté seulement par ce rapport |
| D11 | Opérabilité | 1 | README, M0-REPORT §3 | runbook inexistant avant ce rapport |
| D12 | Tests immunitaires | 3 | 26 tests : négatifs, course, injections, GC | mutation offre/tag absentes |
| D13 | Chaos / mode dégradé | 0 | — | rien sur matériel réel |
| D14 | Convergence gates CI | 0 | Makefile seul | **aucune CI : le vert est déclaratif** |
| D15 | Mémoire / runbook / blackbox | 2 | M0-REPORT liste ses 9 écarts ; culture reviews | pas encore transformé en garde-fous |

**Total : 17/60.** Lecture honnête : c'est le score attendu d'un spike M0 de
qualité (D5/D12/D15 au-dessus du lot). Le danger n'est pas le score, c'est de
merger puis d'acheter **comme si** le score était 45.

---

## 12. Plan d'action priorisé

### Tier 3 — bloquants (avant merge, sauf mention)

| # | Constat | Surface | Pourquoi en prod | Correctif minimal | Rejeu minimal |
|---|---|---|---|---|---|
| 1 | Deux/trois karpenter-core dans le même cluster (stack `autoscaling` : core + CAPI provider ; le provider EM en ajoute un) | orchestrateur | destruction croisée des NodeClaims dès le jour 1 (§1.1) | décision écrite (ADR ou § LLD) : remplacer / décommissionner / cluster dédié ; au minimum un pré-check d'install qui échoue si un autre core est présent | injection §8-11 en T2 |
| 2 | `Delete()`/`Get()` sans vérification d'appartenance au pool avant `StopServer` | sécurité | extinction d'un EM arbitraire du projet unique multi-env (§1.4) | vérifier `poolTag ∈ server.Tags` avant tout StopServer ; sinon erreur explicite | mutation §8-4 en test unitaire |
| 3 | Aucune CI sur le repo provider | release gate | « tests verts » invérifiables ; régression silencieuse au premier bump core | workflow build+test+vet en gate de merge | pipeline vert sur la PR |
| 4 | **(gate d'achat)** Critères M0 n°1-2 non exécutés | matériel | l'architecture parie 15 min non configurables sur un POST jamais mesuré (§1.2) | louer 1 EM à l'heure, dérouler T2 (§7) avant tout engagement mensuel | rapport de mesure ×5 annexé à la décision d'achat |

### Tier 2 — majeurs (avant mise en service du pool)

5. Test de rendu croisé providerID + taint metal dans les
   `registerWithTaints` du machineconfig pré-imagé (un nœud non matché ne
   doit jamais accepter de pods ordinaires).
6. Harvest version/schematic Talos depuis `contexts/_defaults.yaml` — corrige
   la dérive v1.10.4/v1.12.4 (déjà proposé par ADR-035, non fait).
7. Wipe de **tous** les disques au step 2 + checksum SHA512 avant dd (B2, B3).
8. Métriques pool (`available`, `error_count`, âge des NodeClaims) + alerte
   VictoriaMetrics « érosion » et « Pending metal > 15 min » (P1, O6).
9. Procédures écrites : maintenance detag (§9.5), cadence upgrade du pool
   éteint (O2), chemin DR ré-imaging dans `docs/how-to/disaster-recovery.md` (O5).
10. `apply-config` via PN/CI VM plutôt que l'IP publique (S2) ; IAM app
    dédiée au pool (S3).
11. Vérifier en T2 le support réel de `spec.replicas`/feature gate statique
    sur le core déployé (P7) et la persistance PN/IP/booking sur arrêt long (B5).

### Tier 1 — mineurs

12. Cacher `List()` (même TTL que l'inventaire) et backoff 429 (M1 prévu).
13. `NodeClass` introuvable dans `Create()` : erreur de config explicite
    plutôt qu'`InsufficientCapacityError` (diagnostic trompeur).
14. Module path Go réel, regénération controller-gen outillée, miroir de
    l'image Factory dans arbor/Garage (B6).

---

## 13. Renvois

- Revue formelle de la MR au moment du merge : `/cli-audit-review` (le présent
  rapport couvre la résilience, pas la conformité MR).
- Si la décision G4 débouche sur un remaniement de la stack `autoscaling` :
  `/cli-forge-infra` pour l'arbre de dépendances de remplacement
  CAPI-provider → provider natif (chemin ADR-036 B « Phase Instances »).

---

*Rapport généré dans le cadre du pré-mortem demandé avant merge de
`feat/karpenter-provider-scaleway` et engagement de serveurs Elastic Metal.
Aucune sortie de commande n'a été fabriquée : toutes les commandes du runbook
sont à valider lors du premier déploiement T2 (§8-12).*
