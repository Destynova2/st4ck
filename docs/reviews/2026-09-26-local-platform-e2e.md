# Recette locale de la plateforme, 26 septembre 2026

> Ce compte rendu conserve le verdict du premier banc. L'investigation
> Kubescape et la reconstruction sur une nouvelle VM sont décrites dans
> [la recette suivante](2026-09-26-kubescape-clean-bootstrap.md).

## Périmètre

Branche de travail : `docs/openbao-eso-flux-ownership`, modifications non commitées.
Copie isolée de ces modifications dans un dépôt Gitea jetable, sans publication
sur GitHub et sans utilisation des credentials Scaleway réels.

- VM Lima dédiée `st4ck-e2e-hvyapz` : 8 CPU, 28 Gio, disque de 120 Gio.
- Podman rootful distinct du moteur des autres projets ; aucune connexion par défaut modifiée.
- Talos en conteneurs : 1 control plane, 3 workers, Talos et CLI 1.12.9, Kubernetes 1.35.6.
- CNI, local-path, PKI, ESO et Flux installés par les stacks Tofu du dépôt.
- Les autres services sont installés par le graphe Flux réel, depuis Gitea en SSH.
- États et certificats propres au banc. Backend local pour les stacks ; backend HTTP/AppRole testé séparément.

Artefacts privés et journaux : `/private/tmp/st4ck-platform-e2e.HVYAPZ`.
Le répertoire contient aussi les secrets jetables : ne pas le publier ni le commiter.
L'orchestrateur temporaire `control.py` n'est pas un nouveau parcours officiellement maintenu.
L'ancien `make e2e-local` n'a pas été utilisé : noms fixes, contextes globaux,
suppression d'états et vérifications insuffisamment strictes restent à reprendre.

## Verdict

**Recette partielle, pas de feu vert global : 17 HelmReleases Ready sur 18.**
Kubescape reste en échec et bloque la santé de la Kustomization racine.
La révision testée dans Gitea est `1c5a73e6acce6baa968c3f316ac35158ca3515e6` ;
ce n'est pas un commit publié dans le dépôt de travail.

Le vérificateur attend 56 objets issus du graphe réel. Sans exemption, il
échoue sur trois assertions : Kubescape non prêt, racine non prête et révision
non confirmée comme appliquée par la racine. Avec l'exemption explicite
`security/kubescape`, il rapporte zéro autre échec et deux objets exemptés
(la release et sa Kustomization propriétaire). Cette seconde passe vérifie
toujours la révision tentée par la racine ; elle ne remplace pas le verdict strict.

La dernière passe statique termine à **99 contrôles réussis, zéro échec**,
dont 53 tests Python, les tests Go avec détection de courses et les plans Tofu
simulés. Les journaux de clôture sont `verify-local-closure.log`,
`platform-final-strict.log`, `platform-final-qualified.log` et
`platform-final-inventory.json` dans le répertoire privé du banc.

## Vérifications réalisées

| Contrôle | Résultat et limite |
|---|---|
| API Kubernetes et réseau | Quatre nœuds Ready, Cilium et local-path opérationnels |
| Backend d'état HTTP | AppRole réel : écriture, lecture, verrouillage, plan sans changement et destruction de la seule ressource de test |
| OpenBao Infra et App | Trois pods par cluster, identifiant partagé et un seul leader reconnu |
| Reprise OpenBao | Remplacement du pod 0 de chaque cluster, même identifiant après reprise, accord de leader conservé |
| Propriété Helm HA | Trois répliques persistées, aucune auto-initialisation dans la configuration HA, plan Tofu vide après reprise |
| Certificats | Trois ClusterIssuers Ready ; Job PKI Flux terminé |
| GitOps SSH | Clé de déploiement enregistrée dans Gitea, stockée dans OpenBao puis fournie à Flux par ESO ; révision Git vérifiée |
| Réparation ESO | Secret SSH supprimé puis recréé : UID différent et données identiques, jamais affichées |
| PostgreSQL CNPG | Trois instances demandées, trois prêtes ; cette vérification est obligatoire dans le contrôleur de recette |
| Garage S3 | Trois pods Ready, Job layout/buckets terminé, écriture et relecture identique de 1 Kio par l'API S3 ; seul l'objet jetable a été supprimé |
| Bootstrap auxiliaire | Agent Woodpecker connecté au backend Docker/Podman, point de santé répondant ; Matchbox HTTP répondant après correction ciblée |
| Rendu Helm | 18 charts, aucune erreur ; schémas CRD indisponibles explicitement ignorés |

## Défauts trouvés et corrections

1. La CLI Talos 1.14 ne provisionne pas les montages attendus par Talos 1.12.
   Le démarrage a réellement échoué avant Kubernetes. CLI 1.12.9 téléchargée
   depuis la release officielle et somme vérifiée ; le script local refuse
   désormais une version différente avant de modifier le runtime ou les contextes.
2. Le bootstrap masquait les erreurs de lancement Podman. Elles sont propagées.
   Une collision de redirection locale a nécessité un démarrage depuis la VM du banc.
3. L'agent Woodpecker utilisait le port 3000 de Gitea, lisait un secret créé trop
   tard et montait un volume vide à la place du socket Podman. Port dédié,
   secret disponible dès le lancement et montage du vrai socket ajoutés.
4. Matchbox quittait immédiatement : son répertoire d'assets n'existait pas.
   Un volume dédié matérialise ce répertoire. Cela ne valide pas le démarrage PXE.
5. Le rendu CI Scaleway cherchait d'anciens placeholders ; il utilise maintenant
   le même `templatefile` que le bootstrap local. Cinq tests CI simulés passent.
6. **Split-brain OpenBao reproduit malgré le démarrage séquentiel 1 puis 3.**
   Les nouveaux membres s'auto-initialisaient eux aussi. Les blocs `initialize`
   sont maintenant réservés à la première phase, puis retirés avant la mise
   à trois répliques. Sept tests Tofu et les tests HA réels couvrent la correction.
   Voir [OpenBao #3652](https://github.com/openbao/openbao/issues/3652).
7. Grafana conservait `creationPolicy: Merge` alors que Tofu ne créait plus
   son Secret. ESO est maintenant propriétaire dès le premier démarrage.
   Le validateur refuse cette régression et ne considère plus `SecretMissing`
   comme un succès, même si ESO indique une condition Ready à True.
8. Le délai Cilium par défaut était trop court pour le téléchargement à froid.
   Délai porté à quinze minutes ; la première tentative échouée reste comptée
   comme telle, suivie d'une installation réussie.
9. KEDA a terminé son démarrage après le délai Helm de cinq minutes,
   laissant la release en échec sans reprise. Délai porté à dix minutes
   et trois reprises d'installation autorisées.

Pour rejouer le correctif HA, seuls les six PVC OpenBao créés par ce banc ont
été supprimés explicitement, après conservation des logs. Les secrets conservés
dans son état Tofu ont ensuite été réinjectés. Ce n'est ni une procédure de
récupération de production ni une suppression automatique du code de déploiement.

Pendant la convergence à froid, la limite de 5 Gio d'un worker a provoqué
un OOM tuant Trivy. Les trois workers ont été portés à 6 Gio chacun, vérifiés
dans Podman ; le control plane dispose aussi de 6 Gio, dans une VM de 28 Gio.
Des redémarrages de contrôleurs Flux et des reprises manuelles de réconciliation
ont également eu lieu. Le verdict constate l'état final, pas un démarrage sans
intervention ni un test d'endurance après ce redimensionnement.

## Limites restantes

- Kubescape : node-agent en `StartError`, montage du service account refusé
  sur un système de fichiers en lecture seule. Ce composant n'est pas validé
  par ce banc ; une éventuelle exemption doit rester explicite dans le résultat.
- Bootstrap : pas de nouvelle recette complète et sans intervention depuis
  zéro après toutes les corrections. Les deux sidecars corrigés ont été recréés
  séparément pour préserver OpenBao ; aucun pipeline Woodpecker complet exécuté.
  Le dernier ajout du volume persistant de configuration de l'agent a été
  vérifié au rendu, mais pas déployé dans une nouvelle instance de l'agent.
- L'état Tofu interne du sidecar de bootstrap reste dans `/tmp/tofu-work`,
  sans volume persistant. Une recréation peut régénérer les CA. Prévoir sauvegarde,
  migration et garde-fou avant de recréer un bootstrap existant. Les modifications
  du manifeste seul ne déclenchent pas non plus son remplacement automatique.
- Aucune montée de version OpenBao, migration d'un cluster chargé en données,
  restauration Velero, validation noyau sur VM Talos, ni bascule Scaleway VM/EM réelle.
- Le provider Karpenter natif reste désactivé. Les tests KWOK précédents utilisent
  une API EM et des nœuds simulés ; ils ne prouvent pas le démarrage du matériel.

Le kubeconfig habituel et `kms-output/root-ca.pem` ont conservé leurs empreintes
de début de recette. Le certificat réel déjà signalé comme fixture invalide
avant cette recette n'a pas été restauré : réexporter la CA canonique avant
un déploiement hors du banc.

L'inventaire final du moteur Podman partagé conserve 49 conteneurs, dont
35 en cours d'exécution, et 126 volumes. Les deux volumes détachés
`deploy_nativedbdata` et `deploy_nativedbreplicadata` sont conservés.
La VM dédiée `st4ck-e2e-hvyapz` a été arrêtée proprement après les contrôles ;
son disque et les journaux sont conservés, sans arrêt du moteur partagé.
