# Décisions opérationnelles

## 2026-09-23 : propriété des services

Flux possède les services de plateforme dès leur installation ; Tofu conserve
le bootstrap et les états des secrets. Migration sans destruction, dépendances
et arrêt : [ADR-043](docs/adr/043-flux-platform-ownership.md).

## 2026-09-23 : VM vers Elastic Metal

Le provider EM reste expérimental sur sa branche dédiée. La transition requiert
des réservations durables, un pilote de politique et des tests matériels ;
les règles proposées sont dans [ADR-044](docs/adr/044-scaleway-vm-metal-rules.md).

## 2026-09-26 : reprise après erreurs et bootstrap distant

Le provider intégré utilise uniquement les réservations persistantes. Un
finalizer spécifique est écrit avant tout appel de création ; un contrôleur
traite les suppressions sans providerID, absentes du parcours de terminaison
du core. Un résultat cloud inconnu conserve sa réservation et son NodeClaim.
L'arrêt Flux refuse toute réservation restante, même sans NodeClaim.

OpenBao conserve l'amorçage 1 puis 3, suivi d'une application qui enregistre
trois dans Helm. Aucun transfert de cette responsabilité vers Flux et aucune
montée de version OpenBao n'accompagnent ce correctif. La recette HA réelle
reste nécessaire avant upgrade de production.

La VM peut héberger les services bootstrap et exécuter l'administration après
installation des outils et d'un dépôt complet séparé. Le chemin distant neuf
crée IAM et CI en état local provisoire, migre ces états vers la VM, puis crée
l'image et le cluster. Voir [déploiement](docs/how-to/deploy.md).

## 2026-09-26 : Kubescape et persistance du bootstrap

Kubescape reste activé au même niveau de protection et à la même version.
L'échec de montage venait d'une injection Podman/Fedora en lecture seule,
pas d'une incompatibilité démontrée de Kubescape avec Talos. Le banc dédié
supprime cette injection avant création des nœuds ; le script local la détecte.
Aucune configuration du moteur partagé n'est modifiée.

Le setup Tofu conserve son état dans `platform-tofu-state` et refuse de
régénérer une PKI existante sans état. La recréation complète du pod conserve
les trois CA et la lignée d'état sur le nouveau banc. Les anciens déploiements
doivent migrer leur état éphémère avant remplacement ; cette migration n'est
pas automatisée dans la version du 26 septembre. Voir la [recette](docs/reviews/2026-09-26-kubescape-clean-bootstrap.md)
et les [précautions de mise à jour](docs/how-to/upgrade.md).

## 2026-09-27 : garde-fous et preuves fonctionnelles

Le garde-fou commun migre désormais l'ancien état avant suppression du pod,
compare la clé montée et les CA, et refuse toute ambiguïté. Les sources du
setup sont remplacées à chaque démarrage sans effacer état ou verrou de
providers. Le renouvellement du pod inclut les changements de template et
de sources, pas seulement ceux d'une ConfigMap.

La sauvegarde KMS inclut les deux états locaux, la clé statique, les exports,
le manifeste et le snapshot Raft. Une restauration isolée sans `force` a
conservé l'identité KMS et permis l'authentification AppRole d'origine.
Elle ne prouve pas une reprise PostgreSQL, CI ou plateforme complète.
Les anciens raccourcis destructifs de rotation des clés/CA sont bloqués en
attendant un parcours de migration supervisé et recetté.

La disponibilité d'une APIService ne prouve pas le fonctionnement de
l'autoscaling. La recette vérifie maintenant des métriques CPU/mémoire
fraîches. Elle a révélé et fait corriger le port VictoriaMetrics et le label
de nœud absent des collectes. Le provider Scaleway reste opt-in, sans
revendication de migration matérielle ou de disponibilité applicative validée.
