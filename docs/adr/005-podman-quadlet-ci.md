# ADR-005 : VM CI avec Podman Quadlet au lieu de Docker Compose

**Date** : 2026-03-11
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

La VM CI (Scaleway DEV1-M) heberge Gitea + Woodpecker CI. Le deploiement initial utilisait Docker Compose (`docker-compose.yml`) avec Docker CE installe via cloud-init.

## Problemes

1. **Docker = dependance lourde** : Docker CE + containerd + docker-compose-plugin = ~500 MB
2. **Credential helper** : `docker-credential-desktop` introuvable sur les VM headless
3. **Pas d'integration systemd** : `docker compose up -d` ne s'integre pas proprement avec systemd (restart, journald, dependencies)
4. **Incoherence** : le KMS local utilise deja `podman play kube`, Docker sur la CI = 2 runtimes

## Decision

Remplacer Docker par **Podman + Quadlet** :

1. **Pod manifest K8s** (`ci-pod.yaml`) : 3 containers dans un pod unique
   - gitea (:3000, :2222)
   - woodpecker-server (:8000, :9000)
   - woodpecker-agent (monte podman.sock)

2. **Quadlet unit** (`/etc/containers/systemd/ci.kube`) : systemd gere le lifecycle

3. **Podman socket** : l'agent Woodpecker monte `/run/podman/podman.sock` comme `/var/run/docker.sock` (API compatible Docker)

## Gestion systemd

```bash
systemctl enable --now ci      # Start + enable au boot
systemctl restart ci           # Restart complet du pod
systemctl status ci            # Etat
journalctl -u ci               # Logs
```

## Consequences

### Positives

- **Daemonless** : pas de daemon Docker, Podman fork/exec direct
- **systemd natif** : restart automatique, journald, dependencies
- **Un seul runtime** : Podman partout (KMS local + VM CI)
- **Cloud-init simple** : `apt install podman`, pas de repo Docker a configurer
- **Pod unique** : les 3 containers partagent le network namespace (localhost)

### Negatives

- **Woodpecker agent backend=docker** : utilise l'API Docker via le socket. Podman est compatible mais certains edge cases existent (build multi-stage, volume mounts)
- **Quadlet** : relativement recent (Podman 4.4+), moins documente que Docker Compose
