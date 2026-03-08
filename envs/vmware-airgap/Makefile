SCRIPTS := scripts

.PHONY: help image-cache build-ova gen-configs validate-cache bootstrap clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

image-cache: ## Build OCI image cache (requires Internet)
	$(SCRIPTS)/build-image-cache.sh

validate-cache: image-cache ## Validate all images are in the cache
	$(SCRIPTS)/validate-cache.sh

build-ova: validate-cache ## Build OVA with embedded image cache
	$(SCRIPTS)/build-ova.sh

gen-configs: ## Generate per-node machine configs with static IPs
	$(SCRIPTS)/gen-configs.sh

bootstrap: ## Bootstrap etcd + retrieve kubeconfig (post-deployment)
	$(SCRIPTS)/bootstrap.sh

all: build-ova gen-configs ## Build OVA and generate all configs

clean: ## Remove generated artifacts
	rm -rf _out/ image-cache.oci
