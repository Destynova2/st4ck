# Audit des versions et de la compatibilité

Date de consultation : **27 septembre 2026, 11:20–11:42 UTC**. Inventaire du code souhaité, pas inventaire d'un cluster en fonctionnement. Aucun appel à une infrastructure Scaleway/Kubernetes, aucun Podman, aucun changement de pin par cet audit, aucun commit. Seul ce rapport est écrit.

## Conclusion

- **Velero : incompatibilité de branches constatée, puis corrigée par main pendant l'audit.** Initialement : chart `11.4.0`, application `1.17.1`, plugin AWS `1.14.0`. Le correctif minimal appliqué conserve le chart et passe le plugin à **`1.13.2`**. Le manifeste Hauler suit désormais cette même source, sans second pin dans `mirror-images.txt`.
- **Talos/Kubernetes/Cilium : ne pas mettre à jour ces trois composants indépendamment.** Talos `1.12` documente Kubernetes `1.35`, mais Cilium `1.17.13` ne garantit par ses tests que Kubernetes `1.29` à `1.32`. Cela établit un écart de matrice, pas une panne démontrée. Les derniers correctifs des branches actuelles ne suffisent pas à prouver la compatibilité de l'ensemble.
- **Dernier chart ne signifie pas application récente.** Pomerium `34.0.1` est encore le dernier chart de son dépôt, avec une application `0.22.0`, contre une application stable `0.33.3`. Même distinction pour le chart VPA `11.1.1`, qui embarque `1.5.0`, alors que VPA upstream publie `1.8.0`.
- **Les digests racontent la version effectivement choisie.** Les deux images Woodpecker sont `3.13.0`, malgré leur tag indicatif `v3`; le sidecar OpenTofu est `1.9.4`, pas la version CI `1.12.5`. Les sept digests bootstrap inspectés sont des index multiarchitecture incluant Linux amd64 et arm64.
- **Pas de pin futur/non publié confirmé parmi les pins vérifiés.** Plusieurs réponses web étaient moins récentes que les métadonnées officielles directes. Les trous de consultation sont explicités ci-dessous, et ne constituent pas des preuves de fraîcheur.

## Méthode et périmètre

Les dernières versions ont été lues dans les index Helm des éditeurs, les API de releases des dépôts officiels, les sources exactes des tags, Go et les registres OCI des images. Les versions `rc`, `beta` et `edge` ne sont pas promues au rang de stable parce qu'une API les marque `prerelease: false`. La colonne « date » correspond à `published_at` pour les releases, à `created` pour les index Helm, ou à une observation explicitement indiquée. Un `created` d'index régénéré n'est pas nécessairement la date de première publication.

Une « dernière de branche » est un candidat de moindre ampleur, **pas une certification de compatibilité**. `appVersion` est la valeur déclarée par le chart, pas la preuve de toutes ses images, dépendances et hooks. Les overrides locaux restent prioritaires. Aucune vulnérabilité ni garantie de support n'est déduite de la seule ancienneté.

Le parcours standard est celui de `Makefile:k8s-up` et de `clusters/management/kustomization.yaml`. CNI, PKI, ESO et Flux sont amorcés par OpenTofu; les services de plateforme sont ensuite réconciliés par Flux. CAPI, Kamaji, Gateway API et l'ancien provider Karpenter CAPI ne figurent pas dans ce parcours. Le provider Scaleway natif reste opt-in. Leur présence dans un registre ou un manifeste de staging ne prouve pas leur déploiement.

| Source locale réellement lue | Rôle / limite |
|---|---|
| [versions-configmap.yaml](/Users/ludwig/workspace/st4ck/clusters/management/versions-configmap.yaml), [racine Flux](/Users/ludwig/workspace/st4ck/clusters/management/kustomization.yaml) | Registre des charts et providers CAPI; ne remplace pas les locks des providers Terraform. |
| [contexts/_defaults.yaml](/Users/ludwig/workspace/st4ck/contexts/_defaults.yaml), contextes maintenus, [vars.mk](/Users/ludwig/workspace/st4ck/vars.mk) | Talos `v1.12.9`, Kubernetes `1.35.6`; pas de nouveau registre à créer dans `vars.mk`, qui ne contient déjà plus de pins. |
| [Makefile](/Users/ludwig/workspace/st4ck/Makefile), `stacks/*/main.tf`, HelmRelease et valeurs des stacks atteignables | Départage version de chart, application, override et composant optionnel. |
| [bootstrap/platform-pod.yaml](/Users/ludwig/workspace/st4ck/bootstrap/platform-pod.yaml), [bootstrap/main.tf](/Users/ludwig/workspace/st4ck/bootstrap/main.tf), [CI Scaleway](/Users/ludwig/workspace/st4ck/envs/scaleway/ci/main.tf) | Images bootstrap; défaut `vault_backend_image` dupliqué entre bootstrap et CI distante. |
| Locks HCL de `bootstrap`, `bootstrap/tofu`, `envs/scaleway/*`, `envs/local`, `modules/em-talos-bootstrap`, `stacks/cni`, `stacks/pki`, `stacks/flux-bootstrap` | Sélections enregistrées, pas preuve des plugins effectivement installés dans un volume ou sur une machine distante. |
| [.woodpecker.yml](/Users/ludwig/workspace/st4ck/.woodpecker.yml), [Dockerfile](/Users/ludwig/workspace/st4ck/karpenter-provider-scaleway/Dockerfile), [go.mod](/Users/ludwig/workspace/st4ck/karpenter-provider-scaleway/go.mod) | Outillage CI, compilation et dépendances directes du provider natif. Les dépendances Go indirectes ne font pas l'objet d'un audit exhaustif de fraîcheur. |
| [verify-gitops.py](/Users/ludwig/workspace/st4ck/scripts/verify-gitops.py), [hauler-manifest-gen.py](/Users/ludwig/workspace/st4ck/scripts/hauler-manifest-gen.py), [hauler-manifest.yaml](/Users/ludwig/workspace/st4ck/hauler-manifest.yaml), [test_hauler_images.py](/Users/ludwig/workspace/st4ck/scripts/tests/test_hauler_images.py) | Relecture des corrections de main; cet audit ne les réimplémente pas. |

L'audit et la configuration Renovate appartiennent au chantier A. Aucune deuxième automatisation de versions n'est proposée ici. Les corrections des schémas appartiennent à main; leurs résultats rapportés ne sont pas présentés comme une exécution de cet audit.

## Socle et compatibilité

| Composant | Présent | Dernière stable / branche actuelle | Date et source primaire | Preuve résiduelle |
|---|---|---|---|---|
| Talos | `v1.12.9` | `v1.14.1`; branche 1.12 : `v1.12.12` | [1.14.1, 15/09/2026](https://github.com/siderolabs/talos/releases/tag/v1.14.1); [1.12.12, 04/09/2026](https://github.com/siderolabs/talos/releases/tag/v1.12.12) | Rebuild/import d'image, upgrade de nœuds et retour arrière à tester. Un correctif disponible ne prouve pas le maintien du support communautaire. |
| Kubernetes | `1.35.6` | `v1.37.1`; branche 1.35 : `v1.35.9` | [1.37.1, 23/09/2026](https://github.com/kubernetes/kubernetes/releases/tag/v1.37.1); [1.35.9, 23/09/2026](https://github.com/kubernetes/kubernetes/releases/tag/v1.35.9) | Vérifier le triplet Talos/CNI/Kubernetes, les API et le chemin d'upgrade, pas seulement les manifests rendus. |
| Cilium | chart/app `1.17.13` | `1.20.2`; branche 1.17 : `1.17.18` | [Index éditeur](https://helm.cilium.io/index.yaml), 16/09/2026 et 16/07/2026 | `1.35.6` est hors de la matrice testée publiée pour le tag 1.17.13. |

La [matrice Talos 1.12](https://docs.siderolabs.com/talos/v1.12/getting-started/support-matrix) inclut Kubernetes 1.30 à 1.35, pas 1.37. Sa fenêtre de support communautaire se termine à la sortie de 1.13; un contrat de support éventuel n'a pas été vérifié. La [matrice du tag exact Cilium 1.17.13](https://raw.githubusercontent.com/cilium/cilium/v1.17.13/Documentation/network/kubernetes/compatibility.rst) liste 1.29 à 1.32 et distingue compatibilité ascendante attendue et tests garantis. La [documentation stable Cilium consultée](https://docs.cilium.io/en/stable/network/kubernetes/compatibility/) liste 1.33 à 1.36; la documentation `latest` de développement ne doit pas servir à certifier 1.37.

## Charts du parcours maintenu

Dans les cellules `chart → app`, les deux nombres appartiennent à des espaces de versions différents. « Même branche » désigne ici le même couple majeur/mineur du chart. Les dates sont celles de l'entrée de la dernière version dans l'index consulté, sauf mention contraire.

| Clé du registre | Présent : chart → app | Dernier chart stable → app | Date / source officielle du chart | Branche / preuve résiduelle |
|---|---|---|---|---|
| `cert_manager_version` | `1.21.0 → 1.21.0` | `1.21.2 → 1.21.2` | 11/09/2026, [Jetstack](https://charts.jetstack.io/index.yaml) | Correctif de branche; CRD, webhook et renouvellement à éprouver. |
| `openbao_version` | `0.28.4 → 2.5.5` | `0.29.6 → 2.6.3` | 23/09/2026, [OpenBao Helm](https://openbao.github.io/openbao-helm/index.yaml) | Même branche chart : `0.28.6 → 2.6.1`, donc même un patch chart change la mineure applicative. App upstream `2.7.0` ne signifie pas chart `0.29.6 → 2.7.0`. |
| `external_secrets_version` | `0.20.4 → 0.20.4` | `2.11.0 → 2.11.0` | 21/09/2026, [ESO](https://charts.external-secrets.io/index.yaml) | Dernier 0.20 : 0.20.4. Passage majeur à instruire; CRD et stores à tester. |
| `flux_version` | `2.18.4 → 2.8.8` | `2.19.1 → 2.9.5` | 19/09/2026, [fluxcd-community](https://fluxcd-community.github.io/helm-charts/index.yaml) | Chart communautaire `flux2`, pas version de Flux. [App Flux 2.9.5](https://github.com/fluxcd/flux2/releases/tag/v2.9.5), 31/08/2026. |
| `local_path_provisioner_version` | `0.0.37 → 0.0.36` | `0.0.38 → 0.0.37` | 05/08/2026, [Containeroo](https://charts.containeroo.ch/index.yaml) | Provisionnement/reprise des volumes à tester. |
| `cnpg_version` | `0.29.0 → 1.30.0` | `0.29.1 → 1.30.1` | 23/09/2026, [CloudNativePG](https://cloudnative-pg.github.io/charts/index.yaml) | Le Cluster local ne fixe pas `imageName` PostgreSQL : la version de l'opérateur ne suffit pas à inventorier la base. |
| `headlamp_version` | `0.43.0 → 0.43.0` | `0.45.0 → 0.45.0` | 20/08/2026, [Headlamp](https://kubernetes-sigs.github.io/headlamp/index.yaml) | Dernier 0.43 : 0.43.0. RBAC/plugins à vérifier. |
| `kratos_version` | `0.62.1 → 26.2.0` | `0.64.0 → 26.2.0` | Index régénéré 03/09/2026, [Ory](https://k8s.ory.com/helm/charts/index.yaml) | L'application ne change pas selon l'index; [app 26.2.0](https://github.com/ory/kratos/releases/tag/v26.2.0), publiée 20/03/2026. Valeurs et migrations restent à contrôler. |
| `hydra_version` | `0.62.1 → 26.2.0` | `0.64.0 → 26.2.0` | Index régénéré 03/09/2026, [Ory](https://k8s.ory.com/helm/charts/index.yaml) | [App 26.2.0](https://github.com/ory/hydra/releases/tag/v26.2.0), publiée 20/03/2026. Ne pas appeler 0.64 une version de Hydra. |
| `pomerium_version` | `34.0.1 → 0.22.0` | **`34.0.1 → 0.22.0`** | 30/05/2023, [Pomerium Helm](https://helm.pomerium.io/index.yaml) | Chart à jour dans ce dépôt, application ancienne : [0.33.3](https://github.com/pomerium/pomerium/releases/tag/v0.33.3), 09/09/2026. Choix de voie de déploiement/migration à instruire, pas simple bump de chart. |
| `kyverno_version` | `3.8.2 → 1.18.2` | `3.9.1 → 1.19.1` | 10/09/2026, [Kyverno](https://kyverno.github.io/kyverno/index.yaml) | Dernier 3.8 : 3.8.2. Policies, exceptions et webhooks à tester. |
| `tetragon_version` | `1.7.0 → 1.7.0` | `1.7.1 → 1.7.1` | 25/08/2026, [Cilium/Tetragon](https://helm.cilium.io/index.yaml) | Validation eBPF/Talos requise; schéma valide ne prouve pas chargement noyau. |
| `trivy_operator_version` | `0.34.0 → 0.32.0` | `0.36.0 → 0.34.0` | 24/08/2026, [Aqua](https://aquasecurity.github.io/helm-charts/index.yaml) | Deux numérotations différentes; vérifier aussi les images de scan et bases en air-gap. |
| `kubescape_version` | `1.40.2 → 1.40.2` | `1.40.4 → 1.40.4` | 04/09/2026, [Kubescape](https://kubescape.github.io/helm-charts/index.yaml) | Les sous-composants du chart ont leurs propres images. |
| `garage_chart_version` | ref Git `v2.3.0`; chart vendored `0.9.3 → 2.3.0` | ref `v2.4.1`; chart `0.10.2 → 2.4.1` | 08/09/2026, [release Garage](https://git.deuxfleurs.fr/Deuxfleurs/garage/releases/tag/v2.4.1), [Chart.yaml du tag](https://git.deuxfleurs.fr/Deuxfleurs/garage/raw/tag/v2.4.1/script/helm/garage/Chart.yaml) | Cette clé est une ref d'archive, pas une version Helm. L'override actif est `dxflrs/garage:v2.3.0`, pas l'ancien défaut arch-spécifique du chart. Sauvegarde, données et S3 à tester. |
| `zot_version` | `0.1.122 → 2.1.18` | `0.1.125 → 2.1.21` | 19/09/2026, [zot](https://zotregistry.dev/helm-charts/index.yaml) | Registry, auth, signatures et contenu à vérifier. |
| `velero_version` | `11.4.0 → 1.17.1` | `12.2.0 → 1.18.2` | 16/09/2026, [Velero Helm](https://vmware-tanzu.github.io/helm-charts/index.yaml) | Conserver 11.4.0 + plugin 1.13.2 est le correctif minimal retenu; voir section dédiée. |
| `victoria_logs_version` | `0.13.8 → 1.51.0` | `0.13.9 → 1.52.0` | 16/07/2026, [VictoriaMetrics](https://victoriametrics.github.io/helm-charts/index.yaml) | Chart `victoria-logs-single`; vérifier stockage et requêtes. |
| `victoria_logs_collector_version` | `0.3.6 → 1.51.0` | `0.3.7 → 1.52.0` | 16/07/2026, [VictoriaMetrics](https://victoriametrics.github.io/helm-charts/index.yaml) | Coordonner avec le serveur, ne pas confondre collector et stack métriques. |
| `vm_k8s_stack_version` | `0.86.0 → 1.147.0` | `0.93.0 → 1.152.0` | 20/09/2026, [VictoriaMetrics](https://victoriametrics.github.io/helm-charts/index.yaml) | Même branche : `0.86.2 → 1.147.0`. `appVersion` ne décrit pas toutes les dépendances du stack. |
| `keda_version` | `2.20.1 → 2.20.1` | `2.21.0 → 2.21.0` | 23/09/2026, [KEDA](https://kedacore.github.io/charts/index.yaml) | Branche 2.20 : 2.20.2. ScaledObjects et métriques à tester. |
| `prometheus_adapter_version` | `4.11.0 → 0.12.0` | `5.3.0 → 0.12.0` | 19/02/2026, [Prometheus community](https://prometheus-community.github.io/helm-charts/index.yaml) | Branche 4.11 : 4.11.1. Major chart sans changement d'app; tester APIService et disponibilité des métriques. |
| `vpa_version` | `11.1.1 → 1.5.0` | **`11.1.1 → 1.5.0`** | 06/10/2025, [Cowboysysop](https://cowboysysop.github.io/charts/index.yaml) | [App upstream 1.8.0](https://github.com/kubernetes/autoscaler/releases/tag/vertical-pod-autoscaler-1.8.0), 23/09/2026; chart upstream distinct `0.13.0`. Migration de distribution à évaluer; aucune preuve fonctionnelle VPA. |

### Velero : constat puis correction

| État / option | Chart | Application | Plugin AWS | Statut |
|---|---|---|---|---|
| Constat initial, avant correction de main | 11.4.0 | 1.17.1 | 1.14.0 | Hors matrice upstream. |
| **Correctif minimal appliqué par main** | **11.4.0** | **1.17.1** | **1.13.2** | Aligné sur la matrice 1.13.x / 1.17.x; values et staging Hauler relus après correction. |
| Alternative d'upgrade, non appliquée | 12.2.0 | 1.18.2 | 1.14.3 | Alignée sur la matrice 1.14.x / 1.18.x; changement de major chart et de mineure applicative. |

`v1.13.2` est la dernière release stable de la branche 1.13 trouvée dans les releases officielles, publiée le **16/01/2026**. Sa [matrice de compatibilité au tag exact](https://raw.githubusercontent.com/velero-io/velero-plugin-for-aws/v1.13.2/README.md) désigne Velero 1.17.x. La [release 1.13.2](https://github.com/velero-io/velero-plugin-for-aws/releases/tag/v1.13.2) n'est ni draft ni prerelease. La dernière stable 1.14 est [1.14.3, 21/09/2026](https://github.com/velero-io/velero-plugin-for-aws/releases/tag/v1.14.3); `1.14.4-rc.1` du 24/09 est exclue. La [matrice de la branche courante](https://raw.githubusercontent.com/velero-io/velero-plugin-for-aws/main/README.md) associe 1.14.x à Velero 1.18.x.

Relecture locale après intervention de main : `stacks/storage/flux/values-velero.yaml` et `hauler-manifest.yaml` sélectionnent `v1.13.2`; `scripts/mirror-images.txt` ne porte plus le pin concurrent. `collect_images()` lit les valeurs Velero, et `test_hauler_images.py` vérifie unicité et égalité entre configuration et artefact air-gap. Le garde de `verify-gitops.py` porte sur les images réellement rendues.

Résultats **rapportés par main**, non réexécutés ici : 18 charts, 446 objets valides, 0 skipped; 15 tests de schémas PASS; manifeste du plugin 1.13.2 vérifié multiarch Linux amd64/arm64/armv7. Les 52 skips initiaux ont été attribués à 50 CRD non disponibles dans le catalogue standalone et 2 APIService v1beta1 rendus sans capacité Kubernetes adaptée. Cette correction de validation ne constitue pas un backup/restore réussi. Le README du plugin signale des particularités S3 compatibles liées à aws-sdk-go-v2 : **restauration réelle contre Garage et cohérence applicative restent à prouver**.

## Bootstrap, digests et outils

Inspection OCI limitée aux manifestes et configs, sans téléchargement de couches ni exécution. Les hashes complets restent dans les fichiers source. Le rapprochement tag/digest est daté; le digest est l'identité qui prime sur le texte du tag.

| Image / outil présent | Dernière stable observée | Date / source | Preuve et limite |
|---|---|---|---|
| OpenBao KMS `2.5.1@87d715…` | `2.7.0` | 23/09/2026, [release](https://github.com/openbao/openbao/releases/tag/v2.7.0) | Config OCI : 2.5.1, construite 23/02/2026. Tag 2.5.1 et digest identiques à la consultation; index Linux amd64/arm64. KMS distinct des OpenBao Helm infra/app. |
| Gitea `1.22-rootless@4216d6…` | `1.27.3` | 29/08/2026, [release](https://github.com/go-gitea/gitea/releases/tag/v1.27.3) | Digest exactement égal au tag éditeur `1.22.6-rootless`; build 13/12/2024. Le label `1-rootless` seul ne suffisait pas. Index Linux amd64/arm64; migrations DB/stockage à instruire. |
| Woodpecker server `v3@428eb0…` | `3.18.1` | 08/09/2026, [release](https://github.com/woodpecker-ci/woodpecker/releases/tag/v3.18.1) | Label du digest : **3.13.0**, build 14/01/2026; index multiarch. Tag v3 courant = `58dafbe5…`, différent. |
| Woodpecker agent `v3@a983b1…` | `3.18.1` | 08/09/2026, [release](https://github.com/woodpecker-ci/woodpecker/releases/tag/v3.18.1) | Label du digest : **3.13.0**, même révision que server; index multiarch. Tag v3 courant = `73ee7cc6…`, différent. Maintenir le couple server/agent. |
| Matchbox `v0.10.0@e14cc4…` | `v0.11.0` | 24/03/2024, [release](https://github.com/poseidon/matchbox/releases/tag/v0.11.0) | Tag v0.10.0 = digest pin; index amd64/arm64. Présence bootstrap, usage PXE dépendant du contexte. |
| OpenTofu setup `1.9@2fc03a…` | `1.12.6` | 19/08/2026, [release](https://github.com/opentofu/opentofu/releases/tag/v1.12.6) | Label du digest : **1.9.4**, build 03/09/2025; tag 1.9 = digest pin, index multiarch. Version du moteur distincte de celle des providers. |
| vault-backend `@fb654a…` | `v1.0.5` | 12/01/2026, [release](https://github.com/gherynos/vault-backend/releases/tag/v1.0.5) | Digest identique au tag éditeur v1.0.5; config construite 12/01/2026, sans label de version. Index amd64/arm64/armv7. Correspondance au dernier tag vérifiée; pas audit fonctionnel du backend. |
| CI OpenTofu `1.12.5` | `1.12.6` | 19/08/2026, [release](https://github.com/opentofu/opentofu/releases/tag/v1.12.6) | Tag sans digest. Le sidecar bootstrap n'est pas mis à jour en changeant seulement cette ancre CI. |
| CI/Dockerfile/Go module `1.26.5` | `1.27.1`; branche 1.26 : **1.26.8** | 01/09/2026, [historique Go](https://go.dev/doc/devel/release), [versions téléchargeables](https://go.dev/dl/?mode=json) | Pin 1.26.5 publié le 07/07/2026, pas futur. Candidat conservateur : patch 1.26; coordonner CI, image de compilation et contrainte du module. |
| kubeconform `v0.8.0` | `v0.8.0` | 04/06/2026, [release](https://github.com/yannh/kubeconform/releases/tag/v0.8.0) | À jour selon les releases consultées. Le binaire à jour ne dispense pas de catalogues exacts ni de schémas CRD. |
| CI et job de bootstrap stockage `alpine/k8s:1.35.4` | Tag `1.37.1`; branche 1.35 : `1.35.9` | 27/09/2026, [registre de l'éditeur](https://hub.docker.com/v2/repositories/alpine/k8s/tags?page_size=25&ordering=last_updated) | Date de mise à jour du tag, pas release Kubernetes. Image composite : son tag ne pinne pas séparément Helm, kubectl ni les paquets installés ensuite par apk. |
| Hook VPA `registry.k8s.io/kubectl:v1.35.6` | Kubernetes `1.37.1`; branche 1.35 : `1.35.9` | 23/09/2026, [Kubernetes](https://github.com/kubernetes/kubernetes/releases/tag/v1.35.9) | Alignement actuel sur la version cible; pas de preuve OCI distincte de ces tags dans cet audit. |
| Runtime natif `gcr.io/distroless/static-debian12:nonroot` | Non déterminé | [Source Distroless](https://github.com/GoogleContainerTools/distroless) | Tag mobile sans digest; pas d'ordre SemVer équivalent à une release Go. Image réellement construite non inventoriée. |
| Hauler et Cosign locaux | Non déterminé | [Releases Hauler](https://github.com/hauler-dev/hauler/releases), [releases Cosign](https://github.com/sigstore/cosign/releases), consultations API : HTTP 403 quota | Outils appelés depuis Make/scripts, sans pin établi ici. Aucun verdict « à jour ». Ne pas les confondre avec une image CI pinée. |

Sources des inspections d'images : registres des éditeurs `quay.io/openbao/openbao`, `docker.io/gitea/gitea`, `docker.io/woodpeckerci/woodpecker-{server,agent}`, `quay.io/poseidon/matchbox`, `ghcr.io/opentofu/opentofu`, `docker.io/gherynos/vault-backend`. Tous les sept pins répondent et pointent vers un manifest list/index incluant Linux amd64/arm64. Les entrées OCI `unknown/unknown` sont conservées dans l'observation, pas interprétées comme plateformes exécutables. Aucune vérification de signature, SBOM ou contenu binaire n'a été faite.

## Providers OpenTofu

Les contraintes HCL ne sont pas les versions sélectionnées. Les nombres « présents » ci-dessous sont ceux des locks lus. `~> 2.0` exclut 3.x; `~> 0.6` autorise les mineures suivantes avant 1.0. Ne pas supprimer les locks pour obtenir mécaniquement les dernières versions.

| Provider | Présent dans les locks concernés | Dernière stable / branche | Date / source primaire | Preuve résiduelle |
|---|---|---|---|---|
| Scaleway | 2.74.0, EM module 2.78.0 | 2.83.1 | 16/09/2026, [release](https://github.com/scaleway/terraform-provider-scaleway/releases/tag/v2.83.1) | Notes de migration, plans et tests mock; aucune nécessité de bump pour le correctif image établi sur 2.74.0. |
| Talos | 0.11.0 | 0.12.0 | 21/09/2026, [release](https://github.com/siderolabs/terraform-provider-talos/releases/tag/v0.12.0) | Provider et OS Talos ont des numérotations distinctes. Tester configs et machine secrets. |
| libvirt | 0.8.3 | 0.9.9 | 30/08/2026, [release](https://github.com/dmacvicar/terraform-provider-libvirt/releases/tag/v0.9.9) | Traiter comme migration de provider, pas patch inoffensif; aucun hyperviseur interrogé. |
| local | 2.8.0, 2.9.0, 2.9.1 | 2.9.1 | 10/09/2026, [release](https://github.com/hashicorp/terraform-provider-local/releases/tag/v2.9.1) | Certaines racines déjà à jour; autres volontairement verrouillées. |
| random | 3.8.1, 3.9.0 | 3.9.1 | 11/09/2026, [release](https://github.com/hashicorp/terraform-provider-random/releases/tag/v3.9.1) | Ne pas régénérer des secrets en confondant upgrade du plugin et remplacement des ressources. |
| tls | 4.2.1 | 4.4.1 | 10/09/2026, [release](https://github.com/hashicorp/terraform-provider-tls/releases/tag/v4.4.1) | Préserver PKI et state; contrôler absence de remplacement inattendu. |
| null | 3.3.0 | 3.3.2 | 10/09/2026, [release](https://github.com/hashicorp/terraform-provider-null/releases/tag/v3.3.2) | EM optionnel; ne pas rejouer l'imaging pour tester une mise à jour. |
| helm | 2.17.0 | 3.3.0; dernier 2.x : **2.17.0** | 02/09/2026, [3.3.0](https://github.com/hashicorp/terraform-provider-helm/releases/tag/v3.3.0); [2.17.0](https://github.com/hashicorp/terraform-provider-helm/releases/tag/v2.17.0) | À jour dans la majeure autorisée, pas globalement; migration de schéma 3.x à étudier séparément. |
| kubernetes | 2.38.0 | 3.2.1; dernier 2.x : **2.38.0** | 01/07/2026, [3.2.1](https://github.com/hashicorp/terraform-provider-kubernetes/releases/tag/v3.2.1); [2.38.0](https://github.com/hashicorp/terraform-provider-kubernetes/releases/tag/v2.38.0) | Même distinction contrainte/dernière globale. |
| vault | 4.8.0 | 5.12.0; dernier 4.x : **4.8.0** | 17/09/2026, [5.12.0](https://github.com/hashicorp/terraform-provider-vault/releases/tag/v5.12.0); [4.8.0](https://github.com/hashicorp/terraform-provider-vault/releases/tag/v4.8.0) | Compatibilité OpenBao et bootstrap AppRole à vérifier avant changement de majeure. |
| alekc/kubectl | 2.2.0 | 2.4.1 | 01/06/2026, [release](https://github.com/alekc/terraform-provider-kubectl/releases/tag/v2.4.1) | Tester manifests/CRD et state, pas seulement syntaxe HCL. |
| go-gitea/gitea | 0.7.0 | 0.8.1 | Observé 27/09/2026, [registre OpenTofu](https://registry.opentofu.org/v1/providers/go-gitea/gitea/versions) | Date de publication non obtenue; vérifier contre Gitea réellement retenu et son API. |

Cas important : le setup bootstrap copie seulement `/source/bootstrap/tofu/*.tf` vers `/var/lib/tofu`, conserve les locks persistants et exécute `tofu init`. Le lock Git de `bootstrap/tofu` **n'est pas copié** par ce chemin. Sur un volume vierge, le choix peut donc différer du lock Git; sur un volume existant, il dépend du lock conservé. Aucune version effective de ce volume n'est revendiquée ici. Les providers optionnels hors de ces racines, notamment `hashicorp/http` de Gateway API, ne sont pas certifiés à jour par cette table.

## Provider natif : Go, core et SDK

| Dépendance | Présent | Dernière observée / branche | Date / source primaire | Compatibilité / preuve résiduelle |
|---|---|---|---|---|
| Karpenter core | 1.14.0 | 1.14.1 | 21/08/2026, [release](https://github.com/kubernetes-sigs/karpenter/releases/tag/v1.14.1) | Le [go.mod 1.14.1](https://raw.githubusercontent.com/kubernetes-sigs/karpenter/v1.14.1/go.mod) exige Go 1.26.6, contre 1.26.5 au [tag 1.14.0](https://raw.githubusercontent.com/kubernetes-sigs/karpenter/v1.14.0/go.mod). Ne pas proposer le patch core seul. |
| Scaleway SDK | 1.0.0-beta.36 | **1.0.0-beta.37**, pas une GA | 31/07/2026, [release](https://github.com/scaleway/scaleway-sdk-go/releases/tag/v1.0.0-beta.37) | Le pin beta.36 existe, publié 18/12/2025. API et conversions VM/EM à tester; aucun appel cloud effectué. |
| controller-runtime | 0.23.1 | 0.25.1; branche 0.23 : 0.23.3 | [0.25.1, 14/09/2026](https://github.com/kubernetes-sigs/controller-runtime/releases/tag/v0.25.1); [0.23.3, 05/03/2026](https://github.com/kubernetes-sigs/controller-runtime/releases/tag/v0.23.3) | Core 1.14.0 et 1.14.1 utilisent encore 0.23.1. La dernière globale n'est pas une cible automatique. |
| k8s.io/api, apimachinery, client-go | 0.35.1 | Branche 0.35 : 0.35.9 | Observé 27/09/2026, [versions du module api](https://proxy.golang.org/k8s.io/api/@v/list) | Core amont fixe aussi 0.35.1; mélange 0.35.0 indirect/0.35.1 direct déjà présent dans son go.mod. Ne pas « nettoyer » isolément toutes les versions Kubernetes. Latest hors branche et équivalence de chaque module non certifiés ici. |
| awslabs/operatorpkg | `v0.0.0-20260708223819-4da4c353c5fa` | Pas de stable déterminée | [go.mod du core 1.14.0](https://raw.githubusercontent.com/kubernetes-sigs/karpenter/v1.14.0/go.mod) | Pseudo-version identique au core 1.14.0 et 1.14.1, datée avant l'audit. Ce n'est pas une nouvelle abstraction locale à supprimer parce que son nom contient AWS. |
| google/uuid | 1.6.0 | 1.6.0 | 23/01/2024, [release](https://github.com/google/uuid/releases/tag/v1.6.0) | À jour parmi les releases officielles consultées. |
| go.yaml.in/yaml/v3 | 3.0.4 | Non déterminé | [Source du mainteneur](https://github.com/yaml/go-yaml); API releases : HTTP 403 quota | Échec explicite, pas verdict « à jour ». |

La concordance des dépendances du core est une preuve de cohérence de départ, pas une preuve e2e. Un changement core/SDK demanderait tests Go, race et contrats locaux, puis validation opérationnelle autorisée séparément. Le contrôleur étant opt-in, ces pins ne doivent pas être décrits comme des pods forcément présents sur le cluster management.

## Composants optionnels ou historiques

Ils sont inventoriés pour éviter les angles morts, **sans les réactiver ni les intégrer à une vague d'upgrade standard**.

| Clé / composant | Présent | Dernière observée | Date / source primaire | Limite |
|---|---|---|---|---|
| `capi_core_version` | v1.10.10 | v1.14.2 | 08/09/2026, [Cluster API](https://github.com/kubernetes-sigs/cluster-api/releases/tag/v1.14.2) | Pin publié 08/01/2026. Matrice croisée des providers à reconstruire avant réactivation. |
| `capi_bootstrap_talos_version` | v0.6.12 | v0.6.13 | 18/09/2026, [CABPT](https://github.com/siderolabs/cluster-api-bootstrap-provider-talos/releases/tag/v0.6.13) | Pin publié 27/04/2026; pas preuve de compatibilité avec CAPI 1.14. |
| `capi_controlplane_kamaji_version` | v0.14.2 | v0.21.0 | 16/09/2026, [provider Kamaji](https://github.com/clastix/cluster-api-control-plane-provider-kamaji/releases/tag/v0.21.0) | Pin publié 20/03/2025. Ne pas confondre provider et opérateur Kamaji. |
| `capi_infrastructure_scaleway_version` | v0.2.2 | v0.2.3 | 17/09/2026, [CAPS](https://github.com/scaleway/cluster-api-provider-scaleway/releases/tag/v0.2.3) | Pin publié 07/07/2026. Aucun scénario CAPI cloud validé. |
| `capi_operator_version` | chart 0.27.0 | chart/app 0.29.0 | 26/08/2026, [index officiel](https://kubernetes-sigs.github.io/cluster-api-operator/index.yaml) | Mettre à jour l'opérateur ne met pas magiquement tous les providers à niveau. |
| `etcd_operator_version` | chart 0.4.5, source OCI aenix-io | app v0.5.6 | 23/09/2026, [release cozystack](https://github.com/cozystack/etcd-operator/releases/tag/v0.5.6) | Redirection du dépôt aenix vers cozystack constatée. Dernière version du chart OCI/appVersion exact du pin non vérifiés : ne pas assimiler automatiquement chart 0.5.6 et app 0.5.6. |
| `gateway_api_version` | v1.2.0 | v1.6.2 | 03/09/2026, [Gateway API](https://github.com/kubernetes-sigs/gateway-api/releases/tag/v1.6.2) | CRD, canal standard/expérimental et implémentation Cilium à aligner. |
| `kamaji_git_ref` | `3e5439488b678e8827c6bcc4733f2017ed2d59fc` | Pas de notion « dernier SHA stable » | [Commit amont](https://github.com/clastix/kamaji/commit/3e5439488b678e8827c6bcc4733f2017ed2d59fc), 11/07/2026 | Commit existe. Chart vendored `0.0.0+latest`; dépendance chart `>=0.15.0` et `helm dependency update` rendent la ref seule insuffisante pour une résolution reproductible. |
| `kamaji_image_tag` | 26.7.2-edge | endpoint latest : **26.9.4-edge**; release sans suffixe edge trouvée : v1.0.0 | [edge, 21/09/2026](https://github.com/clastix/kamaji/releases/tag/26.9.4-edge); [v1.0.0, 28/06/2024](https://github.com/clastix/kamaji/releases/tag/v1.0.0) | Pin edge publié 06/07/2026. `prerelease:false` ne transforme pas une distribution edge en stable; ne pas recommander un retour aveugle à l'ancienne 1.0.0. |
| `karpenter_capi_provider_version` | 0.2.0 | v0.2.0 | 28/10/2025, [provider CAPI](https://github.com/kubernetes-sigs/karpenter-provider-cluster-api/releases/tag/v0.2.0) | Pas de nouveauté dans les releases observées; ancien chemin expérimental retiré du déploiement standard. |
| `karpenter_version` | 1.14.0 | v1.14.1 | 21/08/2026, [core](https://github.com/kubernetes-sigs/karpenter/releases/tag/v1.14.1) | Registre hérité distinct du go.mod réellement compilé; voir section Go. Ne prouve pas l'exécution d'un chart Karpenter AWS. |

## Conflits et consultations incomplètes

1. **Kubernetes : réponses de fraîcheur différente.** Les pages officielles [releases](https://kubernetes.io/releases/) et [patch releases](https://kubernetes.io/releases/patch-releases/) consultées via le moteur web montraient encore 1.37.0 / 1.35.8, alors que l'API du dépôt officiel exposait des releases 1.37.1 / 1.35.9 publiées le 23/09/2026. Les dates calendaires de release peuvent aussi différer de `published_at`. Les tables retiennent les artefacts/release metadata directement consultés, pas une conclusion de « version future » à partir d'un extrait en retard.
2. **Ory : consultation initialement en échec, finalement résolue.** L'ancien hôte `k8s.ory.sh` renvoie HTTP 308 vers `k8s.ory.com`; les essais de chemins GitHub de secours renvoyaient 404. Le nouvel index officiel répond 200 et a été analysé. Les dates `created` de plusieurs anciennes versions y sont identiques : elles ne permettent pas de dater leur première publication.
3. **OCI : distinction du poste d'audit et de la plateforme cible.** Une première lecture de config sans override OS cherchait Darwin, et les références combinant tag+digest étaient refusées par l'outil. Relecture réussie avec dépôt@digest et sélection Linux/amd64; inventaire des plateformes fait séparément sur l'index brut. Ces erreurs initiales ne sont pas des défauts des images.
4. **Limite d'API atteinte.** Les derniers appels GitHub pour YAML Go, Cosign et Hauler ont renvoyé HTTP 403 quota. Leur dernière stable n'est pas certifiée. Le chart OCI etcd, les sous-images transitives de tous les charts, les providers des chemins optionnels et les dépendances Go indirectes restent hors preuve exhaustive.
5. **Pins récents contrôlés.** Talos 1.12.9, Kubernetes 1.35.6, Go 1.26.5, les pins CAPI cités et les entrées Helm consultées existent avec des dates non futures relativement au 27/09/2026. Aucun pin non publié confirmé dans cet ensemble; ce constat borné ne couvre pas les consultations incomplètes, une signature d'artefact, ni la correspondance du code avec une installation réelle.

## Cinq simplifications concrètes

| Proposition | Emplacement / duplication réelle | État et limite |
|---|---|---|
| **Une seule source pour le plugin Velero déployé et embarqué** | `stacks/storage/flux/values-velero.yaml`, `scripts/mirror-images.txt`, `scripts/hauler-manifest-gen.py`, `hauler-manifest.yaml` | **Réalisée par main et relue** : suppression du pin dupliqué, lecture des valeurs dans le collecteur, test d'égalité/unicité. Conserver le garde de compatibilité sur les images rendues. |
| **Clarifier la nature des clés existantes, sans nouveau registre** | `versions-configmap.yaml` : `garage_chart_version` est une ref Git; `flux_version`, `cnpg_version` et `pomerium_version` sont des versions de charts; providers TF dans leurs locks | Ajouter des commentaires de type/source et des tests ciblés aux lecteurs existants. Ne pas réintroduire les pins morts dans `vars.mk`, ni recopier chaque appVersion en dur dans une nouvelle source concurrente. |
| **Séparer le staging standard du catalogue optionnel** | Le générateur Hauler parcourt `stacks/*/main.tf` et `stacks/*/flux*`, plus largement que la racine Flux; CAPI/Kamaji et anciens providers sont hors parcours standard | Réutiliser le parcours atteignable déjà vérifié par le contrôle GitOps, avec inclusion optionnelle explicite, plutôt qu'un deuxième moteur d'inventaire. Préserver l'export air-gap volontaire des options. |
| **Rendre explicite le lock effectif du setup et le défaut d'image backend partagé** | `bootstrap/platform-pod.yaml` ne copie que les `.tf`; `bootstrap/tofu/.terraform.lock.hcl` n'est donc pas la preuve du lock persistant. `vault_backend_image` est dupliqué dans bootstrap et CI Scaleway | Définir une politique initialisation/upgrade du lock persistant, sans l'écraser aveuglément; mutualiser le défaut d'image dans la configuration déjà utilisée ou tester son égalité. Ne pas fusionner les frontières KMS, Infra et App OpenBao. |
| **Traiter les mises à jour par ensembles compatibles dans les mécanismes existants** | Talos/Kubernetes/Cilium; chart/app/plugin Velero; core Karpenter/Go/controller-runtime/SDK; server/agent Woodpecker | Transmettre ces ensembles au chantier Renovate A et aux tests actuels, sans deuxième bot ni abstraction générale. Exemple concret : core 1.14.1 demande Go >=1.26.6, tandis que chart Velero 12.2.0 appelle plugin 1.14.x. |

## Suite recommandée, sans upgrade automatique

Conserver le correctif minimal Velero et ses gardes. Instruire ensuite la matrice Talos/Kubernetes/Cilium et la voie de maintenance Pomerium/VPA. Les correctifs des branches actuelles sont des candidats à valider, pas une consigne de déploiement global. Pour chaque changement retenu : comparer valeurs et schémas, relire le plan OpenTofu et les remplacements, vérifier les images réellement rendues et leur disponibilité multiarch/air-gap, puis mener les tests fonctionnels autorisés séparément. Aucun résultat de schéma, mock provider ou métadonnée publique ne remplace une preuve de restauration, de renouvellement PKI, d'autoscaling ou de transition de nœuds.
