# Activer le depot Woodpecker

Le bootstrap cree Gitea, le depot et l'application OAuth. Son message de fin
ne prouve pas que Woodpecker a active le depot ni qu'un job CI a fonctionne.
L'activation est une operation explicite apres connexion OAuth dans le
navigateur. Aucun mot de passe Gitea n'est scrape et aucun secret Scaleway,
OpenBao ou backend Terraform n'est injecte par ce parcours.

## Prerequis

1. Attendre la fin du setup, verifier Gitea et Woodpecker dans le navigateur,
   puis se connecter a Woodpecker avec le compte Gitea admin du bootstrap.
2. Creer le token personnel dans le profil Woodpecker et le conserver dans
   un fichier prive hors Git, possede par l'utilisateur courant, permissions
   `0600` ou `0400`. Le helper exige `--token-file` : aucun token en argument
   ou variable d'environnement. Le fichier ne doit pas etre un lien symbolique.
3. Utiliser HTTPS, ou une adresse HTTP loopback a travers un tunnel SSH.
   L'URL doit cibler le bon serveur. Les redirections HTTP et les proxies
   implicites sont refuses pour ne pas transmettre le token ailleurs.
4. Verifier que le depot cible contient la revision approuvee et son
   `.woodpecker.yml`. Le push initial du bootstrap publie le `HEAD` source
   sur `main` sans forcer : une divergence distante doit etre resolue avant
   de poursuivre, pas effacee par un bootstrap.

Le token et son mode d'authentification Bearer sont decrits dans
[l'API officielle Woodpecker](https://woodpecker-ci.org/api).

## Activation

Depuis le checkout d'administration, avec Python 3.9+ (bibliotheque standard
uniquement), adapter le port et le nom du compte Gitea :

```bash
python3 scripts/setup-woodpecker.py \
  --server-url http://127.0.0.1:8000 \
  --repo talos/talos \
  --token-file "$HOME/.config/st4ck/woodpecker-token"
```

Le helper verifie l'identite authentifiee, recherche exactement `owner/name`
dans les depots de la forge, active avec l'identifiant de forge trouve puis
relit l'etat par nom complet. Les identifiants Gitea et Woodpecker ne sont
pas interchangeables et ne sont jamais supposes egaux a `1`. Une activation
deja faite est seulement relue ; un conflit HTTP 409 n'est accepte que si
la relecture confirme la meme identite et l'etat actif. Une erreur reseau,
une permission insuffisante ou une reponse incoherente termine en erreur.

Le JSON de succes contient `active: true` et
`pipeline_execution: "not_verified"`. Il ne contient pas le token.
Les schemas/routes sont verifies dans les sources officielles
[Woodpecker 3.18.1](https://github.com/woodpecker-ci/woodpecker/blob/v3.18.1/server/router/api.go) ;
les tests du helper simulent l'API et ne remplacent pas une validation live
avec le digest serveur effectivement deploye.

## Webhook et preuve CI

Gitea doit pouvoir atteindre l'adresse de webhook configuree sur le serveur
Woodpecker. Dans le pod partage, l'adresse interne est
`http://127.0.0.1:8000`, meme si le port publie sur l'hote est different.
Woodpecker 3.x fournit
[`WOODPECKER_EXPERT_WEBHOOK_HOST`](https://github.com/woodpecker-ci/woodpecker/blob/v3.18.1/cmd/server/flags.go)
pour ce cas. Verifier ce reglage dans le manifeste deploye ; ne pas remplacer
les URLs OAuth navigateur par l'adresse interne du webhook.

Apres correction du serveur, ajouter `--repair` a la commande d'activation
pour demander a Woodpecker de reenregistrer le webhook du depot trouve.
Cette option est explicite et exige les permissions d'administration du depot.
Elle n'atteste pas de la livraison d'un evenement.

Publier ensuite une revision de test approuvee sur le depot de recette, ou
relivrer un evenement via Gitea. Verifier ensemble : livraison HTTP du hook,
revision du checkout Woodpecker et resultat de **tous** les jobs attendus.
Un controle d'images ou des tests hors Woodpecker ne prouvent pas ce parcours.
Ne jamais lancer une activation ou un job sur une VM partagee sans accord de
son responsable. Revoquer le token personnel quand il n'est plus necessaire.

## Migration d'un ancien bootstrap

L'ancien `terraform_data.wp_setup` pouvait annoncer un succes sans token,
avec un depot inactif et des secrets absents. Son retrait ne supprime pas les
objets distants : il n'avait pas de provisioner de destruction. L'activation
explicite ci-dessus reste necessaire si elle n'a jamais ete confirmee.

La pipeline actuelle valide seulement le code et les manifests. Auditer et
revoquer separement les anciennes credentials de deploiement Woodpecker
devenues inutiles. Le helper ne les injecte, ne les affiche et ne les supprime
pas. Les fichiers OAuth partages restent aux memes adresses Terraform
`local_file.gitea_client` et `local_file.gitea_secret`, avec permissions `0600`.
