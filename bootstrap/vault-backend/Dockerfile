# vault-backend — build from source
# https://github.com/gherynos/vault-backend
#
# Pinned commit: 224c7a17a943ba3d3d5b137a78b915f1ea8c79ff (2026-03-19)
# Go version matches upstream Dockerfile

ARG GO_VERSION=1.25.5
ARG VAULT_BACKEND_COMMIT=224c7a17a943ba3d3d5b137a78b915f1ea8c79ff

# ── Stage 1: build ──────────────────────────────────────────────────
FROM docker.io/library/golang:${GO_VERSION} AS build

ARG VAULT_BACKEND_COMMIT

WORKDIR /src
RUN git clone https://github.com/gherynos/vault-backend.git . && \
    git checkout ${VAULT_BACKEND_COMMIT}

RUN go mod download
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /go/bin/vault-backend

# ── Stage 2: minimal runtime ───────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

COPY --from=build /go/bin/vault-backend /vault-backend

EXPOSE 8080

CMD ["/vault-backend"]
