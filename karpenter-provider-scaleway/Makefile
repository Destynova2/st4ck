# karpenter-provider-scaleway — M0 spike build targets

GO ?= go

.PHONY: all build test lint fmt vet tidy clean help e2e-kwok

all: build test lint ## Build, test and lint

build: ## Compile every package and the controller binary
	$(GO) build ./...

test: ## Run the unit suite (fake backend only, no network)
	$(GO) test ./...

lint: fmt-check vet ## gofmt + go vet (golangci-lint if installed)
	@if command -v golangci-lint >/dev/null 2>&1; then \
		golangci-lint run ./...; \
	else \
		echo "golangci-lint not installed, skipped"; \
	fi

fmt: ## Rewrite sources with gofmt
	gofmt -w .

fmt-check: ## Fail if any file is not gofmt-clean
	@out=$$(gofmt -l .); if [ -n "$$out" ]; then \
		echo "gofmt needed on:"; echo "$$out"; exit 1; \
	fi

vet: ## go vet
	$(GO) vet ./...

tidy: ## go mod tidy
	$(GO) mod tidy

e2e-kwok: ## Full NodeClaim cycle against a kwok cluster (requires kwokctl + podman/docker)
	hack/kwok-e2e/run.sh

clean: ## Remove build artifacts
	$(GO) clean ./...

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
