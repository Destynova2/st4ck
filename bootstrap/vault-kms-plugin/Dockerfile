# vault-kms-plugin — build from source (bank-vaults)
# https://github.com/bank-vaults/vault-kms-plugin
#
# This is the KMS v2 plugin that kube-apiserver uses for envelope encryption
# of Secrets at rest. Backed by OpenBao Transit engine. Deployed as a sidecar
# next to each Kamaji-hosted tenant apiserver (via KamajiControlPlane.spec.deployment.extraContainers).
#
# Pinned commit: update when bumping the version. Upstream stable ~2026-03.

ARG GO_VERSION=1.25.5
ARG VAULT_KMS_PLUGIN_COMMIT=main

# ── Stage 1: build ──────────────────────────────────────────────────
FROM docker.io/library/golang:${GO_VERSION} AS build

ARG VAULT_KMS_PLUGIN_COMMIT

WORKDIR /src
RUN git clone https://github.com/bank-vaults/vault-kms-plugin.git . && \
    git checkout ${VAULT_KMS_PLUGIN_COMMIT}

RUN go mod download
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /go/bin/vault-kms-plugin ./cmd/vault-kms-plugin

# ── Stage 2: minimal runtime ────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

COPY --from=build /go/bin/vault-kms-plugin /vault-kms-plugin

# UDS socket path (the apiserver talks to it via --encryption-provider-config → unix:///run/kms/socket)
VOLUME ["/run/kms"]

ENTRYPOINT ["/vault-kms-plugin"]
