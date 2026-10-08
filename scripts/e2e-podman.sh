#!/usr/bin/env bash
# Run only kube play inside the pinned Lima VM; Lima owns macOS forwarding.
set -euo pipefail
: "${E2E_REAL_PODMAN:?}" "${E2E_LIMACTL:?}" "${E2E_LIMA_INSTANCE:?}"
: "${E2E_PODMAN_SOCKET:?}" "${E2E_RUN_DIR:?}" "${LIMA_HOME:?}"
if [[ "${CONTAINER_HOST:-}" != "$E2E_PODMAN_SOCKET" ||
      "${DOCKER_HOST:-}" != "$E2E_PODMAN_SOCKET" ]]; then
  echo "Refusing Podman: connection changed outside the isolated run" >&2
  exit 2
fi
if [[ ( "${1:-}" == kube && "${2:-}" == play ) ||
      ( "${1:-}" == play && "${2:-}" == kube ) ]]; then
  shift 2
  manifest=""
  for arg in "$@"; do
    case "$arg" in
      --help)
        [[ "$#" == 1 ]] || exit 2
        exec "$E2E_LIMACTL" shell --workdir=/ "$E2E_LIMA_INSTANCE" sudo -n \
          env -u CONTAINER_HOST -u CONTAINER_CONNECTION -u DOCKER_HOST \
          podman --remote=false kube play --help ;;
      --build=false|--log-driver=k8s-file) ;;
      "$E2E_RUN_DIR"/bootstrap/*/platform-pod.yaml)
        [[ -z "$manifest" && -f "$arg" ]] || exit 2
        parent=$(cd "$(dirname "$arg")" && pwd -P)
        [[ "$parent/platform-pod.yaml" == "$arg" && ! -L "$arg" ]] || exit 2
        manifest="$arg" ;;
      *) echo "Refusing unexpected kube play argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ -n "$manifest" ]] || exit 2
  exec "$E2E_LIMACTL" shell --workdir=/ "$E2E_LIMA_INSTANCE" sudo -n \
    env -u CONTAINER_HOST -u CONTAINER_CONNECTION -u DOCKER_HOST \
    podman --remote=false kube play --build=false --log-driver=k8s-file "$manifest"
fi
exec "$E2E_REAL_PODMAN" --url "$E2E_PODMAN_SOCKET" "$@"
