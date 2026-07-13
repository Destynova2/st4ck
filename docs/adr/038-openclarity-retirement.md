# ADR-038 : Retrait d'OpenClarity — consolidation sur trivy-operator

**Date** : 2026-07-13
**Statut** : Accepté — exécuté le 2026-07-13 (commit c688f73) (remplace ADR-027)
**Décideurs** : Équipe plateforme
**Reliés à** : ADR-027 (OpenClarity multi-scanner), ADR-018 (Tetragon)
**Preuves** : `docs/reviews/2026-07-13-harbor-arm-openclarity.md` (Q2)

## Contexte

OpenClarity est **mort** : dépôt archivé le 2026-05-29 (org GitHub archivée
dans la foulée), dernière release v1.1.3 du 2025-02-05, aucun successeur
annoncé. Le dernier signe de vie était un colmatage de dépendances
(bascule Postgres vers `bitnamilegacy`). Continuer à le déployer, c'est
embarquer un composant sans correctifs CVE dans le stack… sécurité.

## Décision proposée

1. **Retirer OpenClarity du stack security** : le cluster CNPG
   `openclarity-pg`, les ExternalSecrets/PushSecrets associés, les deux
   Kustomizations `security-openclarity-eso`/`security-openclarity`, les
   values et le pin `openclarity_version` du registre.
2. **trivy-operator (déjà déployé) devient le remplaçant assumé** — il
   couvre 5 des 7 piliers d'OpenClarity : SBOM, vulnérabilités, secrets
   dans les images, misconfig/posture (NSA/CIS/PSS), RBAC assessment.
3. **Option malware/FIM** (seul manque réellement additif) : déployer
   uniquement le `node-agent` de Kubescape (CNCF Incubating, moteur
   ClamAV adapté k8s, FIM fanotify, arm64, ~1-2 % CPU) avec kubevuln et
   le moteur de posture **désactivés** (sinon double scan avec
   trivy-operator). À activer si le besoin malware est confirmé, pas par
   défaut.
4. **NeuVector écarté** : redondance triple avec Tetragon (runtime),
   Kyverno (admission) et trivy-operator (scan), pour 3-4× le coût.
5. **Trous assumés, documentés** : rootkits (chkrootkit) et matching
   exploit-DB n'ont **aucun successeur k8s maintenu en 2026**.

## Conséquences

- −1 base Postgres, −2 Kustomizations, −1 composant amd64-only (avec
  Harbor, c'était l'un des deux seuls bloqueurs ARM du parc).
- Le retrait sur clusters existants exige le nettoyage d'état tofu
  (ressources openclarity_* dans stacks/security) et la suppression des
  CRs Flux — à dérouler comme la procédure cosign de `7714a55`.
- ADR-027 passe « Remplacé par ADR-038 ».
