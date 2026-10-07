FROM --platform=$BUILDPLATFORM golang:1.26.5 AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY pkg ./pkg
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /controller ./cmd/controller

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /controller /controller
USER 65532:65532
ENTRYPOINT ["/controller"]
