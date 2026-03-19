include vars.mk

TF := tofu

# ─── Provider selection ──────────────────────────────────────────────
# Set ENV to switch provider:
#   make ENV=local local-up       → libvirt/KVM
#   make scaleway-up              → Scaleway (default)
#   make ENV=outscale outscale-up → Outscale

ENV     ?= scaleway
KC_FILE := $(HOME)/.kube/talos-$(ENV)

# ─── Bootstrap OpenBao (vault-backend → KV v2) ──────────────────────
# AppRole credentials from platform-kms-output volume.
# vault-backend authenticates to OpenBao via AppRole (auto-renewable, no expiry).
KMS_OUTPUT         := kms-output
export TF_HTTP_USERNAME := $(shell cat $(KMS_OUTPUT)/approle-role-id.txt 2>/dev/null)
export TF_HTTP_PASSWORD := $(shell cat $(KMS_OUTPUT)/approle-secret-id.txt 2>/dev/null)

# ─── Stack paths ─────────────────────────────────────────────────────

TF_CNI        := stacks/cni
TF_MONITORING := stacks/monitoring
TF_PKI        := stacks/pki
TF_IDENTITY   := stacks/identity
TF_SECURITY   := stacks/security
TF_STORAGE    := stacks/storage
TF_FLUX       := stacks/flux-bootstrap
GARAGE_CHART  := stacks/storage/chart

# ─── Provider paths ──────────────────────────────────────────────────

TF_LOCAL    := envs/local
TF_OUTSCALE := envs/outscale
TF_SCALEWAY := envs/scaleway
TF_SCW_IAM  := envs/scaleway/iam
TF_SCW_IMAGE := envs/scaleway/image
TF_SCW_CI   := envs/scaleway/ci
VMWARE      := envs/vmware-airgap

.PHONY: help

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'

# ═══════════════════════════════════════════════════════════════════════
# K8s Stacks (provider-agnostic — uses kubeconfig at $(KC_FILE))
#
# Dependency graph:
#   Prerequisites: kms-bootstrap (bootstrap/, once)
#   Create:  cni → pki → monitoring → identity → security → storage → flux
#   Destroy: storage → security → identity → monitoring → pki → cni
#   Note:    in-cluster OpenBao init is handled by k8s-pki (K8s Job)
# ═══════════════════════════════════════════════════════════════════════

# ─── k8s-cni (Cilium — fast, ~30s) ───────────────────────────────────
# MUST be deployed first: without CNI, no pods can be scheduled.

.PHONY: k8s-cni-init k8s-cni-apply k8s-cni-destroy

k8s-cni-init: ## terraform init for k8s-cni
	$(TF) -chdir=$(TF_CNI) init

k8s-cni-apply: ## Deploy Cilium CNI
	$(TF) -chdir=$(TF_CNI) apply -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

k8s-cni-destroy:
	$(TF) -chdir=$(TF_CNI) destroy -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

# ─── k8s-monitoring (vm-k8s-stack + VictoriaLogs + Headlamp) ─────────
# Requires: Cilium (cni) + k8s-pki (cert-manager for TLS).

.PHONY: k8s-monitoring-init k8s-monitoring-apply k8s-monitoring-destroy

k8s-monitoring-init: ## terraform init for k8s-monitoring
	$(TF) -chdir=$(TF_MONITORING) init

k8s-monitoring-apply: ## Deploy monitoring stack
	$(TF) -chdir=$(TF_MONITORING) apply -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

k8s-monitoring-destroy:
	$(TF) -chdir=$(TF_MONITORING) destroy -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

# ─── k8s-pki (OpenBao + cert-manager + CA secrets) ────────────────────
# Requires: Cilium (cni) + kms-bootstrap (local, once)

.PHONY: k8s-pki-init k8s-pki-apply k8s-pki-destroy

k8s-pki-init: ## terraform init for k8s-pki
	$(TF) -chdir=$(TF_PKI) init

k8s-pki-apply: ## Deploy PKI + OpenBao + cert-manager
	$(TF) -chdir=$(TF_PKI) apply -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

k8s-pki-destroy:
	$(TF) -chdir=$(TF_PKI) destroy -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

# ─── k8s-identity (Kratos + Hydra + Pomerium) ─────────────────────────
# Requires: cert-manager ClusterIssuer from k8s-pki

.PHONY: k8s-identity-init k8s-identity-apply k8s-identity-destroy

k8s-identity-init: ## terraform init for k8s-identity
	$(TF) -chdir=$(TF_IDENTITY) init

k8s-identity-apply: ## Deploy Kratos + Hydra + Pomerium
	$(TF) -chdir=$(TF_IDENTITY) apply -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

k8s-identity-destroy:
	$(TF) -chdir=$(TF_IDENTITY) destroy -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

# ─── k8s-security (Trivy + Tetragon + Kyverno) ────────────────────────

.PHONY: k8s-security-init k8s-security-apply k8s-security-destroy

k8s-security-init: ## terraform init for k8s-security
	$(TF) -chdir=$(TF_SECURITY) init

k8s-security-apply: ## Deploy Trivy + Tetragon + Kyverno
	$(TF) -chdir=$(TF_SECURITY) apply -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

k8s-security-destroy:
	$(TF) -chdir=$(TF_SECURITY) destroy -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

# ─── k8s-storage (local-path + Garage + Velero + Harbor) ──────────────
# Self-contained: generates harbor_admin_password internally.

.PHONY: k8s-storage-init k8s-storage-apply k8s-storage-destroy garage-chart

garage-chart: ## Fetch Garage Helm chart (v2.2.0) from upstream
	@mkdir -p $(GARAGE_CHART)
	@curl -sL "https://git.deuxfleurs.fr/Deuxfleurs/garage/archive/v2.2.0.tar.gz" | \
		tar -xz --strip-components=4 -C $(GARAGE_CHART) "garage/script/helm/garage/"
	@echo "Garage Helm chart fetched to $(GARAGE_CHART)/"

k8s-storage-init: garage-chart ## terraform init for k8s-storage (fetches Garage chart)
	$(TF) -chdir=$(TF_STORAGE) init

k8s-storage-apply: ## Deploy local-path + Garage + Velero + Harbor
	$(TF) -chdir=$(TF_STORAGE) apply -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

k8s-storage-destroy:
	$(TF) -chdir=$(TF_STORAGE) destroy -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

# ─── Flux bootstrap (installs Flux + GitRepository + root Kustomization) ──

.PHONY: flux-bootstrap-init flux-bootstrap-apply flux-bootstrap-destroy

flux-bootstrap-init: ## terraform init for flux-bootstrap
	$(TF) -chdir=$(TF_FLUX) init

flux-bootstrap-apply: ## Install Flux and configure GitOps sync
	$(TF) -chdir=$(TF_FLUX) apply -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

flux-bootstrap-destroy:
	$(TF) -chdir=$(TF_FLUX) destroy -auto-approve \
		-var="kubeconfig_path=$(KC_FILE)"

# ─── Composite: all k8s stacks ───────────────────────────────────────

.PHONY: k8s-init k8s-up k8s-down

k8s-init: k8s-cni-init k8s-monitoring-init k8s-pki-init k8s-identity-init k8s-security-init k8s-storage-init flux-bootstrap-init ## terraform init all k8s stacks

k8s-up: ## Deploy all k8s stacks (sequential — parallel caused PVC/webhook races)
	@curl -so /dev/null -w '%{http_code}' http://localhost:8080/state/test 2>/dev/null | grep -qE '^(2|4)' || { echo "ERROR: vault-backend not reachable at :8080. Run 'make bootstrap' first."; exit 1; }
	$(MAKE) k8s-cni-apply
	$(MAKE) k8s-storage-init
	$(TF) -chdir=$(TF_STORAGE) apply -auto-approve -var="kubeconfig_path=$(KC_FILE)" -target=helm_release.local_path_provisioner -target=kubernetes_namespace.storage
	$(MAKE) k8s-pki-apply
	$(MAKE) k8s-monitoring-apply
	$(MAKE) k8s-identity-apply
	$(MAKE) k8s-security-apply
	$(MAKE) k8s-storage-apply
	$(MAKE) flux-bootstrap-apply

k8s-down: ## Destroy all k8s stacks (correct order)
	@curl -so /dev/null -w '%{http_code}' http://localhost:8080/state/test 2>/dev/null | grep -qE '^(2|4)' || { echo "ERROR: vault-backend not reachable at :8080. Run 'make bootstrap' first."; exit 1; }
	@# Remove Kyverno webhooks first to prevent them blocking other deletions
	@KUBECONFIG=$(KC_FILE) kubectl delete mutatingwebhookconfiguration -l app.kubernetes.io/instance=kyverno --ignore-not-found 2>/dev/null || true
	@KUBECONFIG=$(KC_FILE) kubectl delete validatingwebhookconfiguration -l app.kubernetes.io/instance=kyverno --ignore-not-found 2>/dev/null || true
	-$(MAKE) k8s-storage-destroy
	-$(MAKE) k8s-security-destroy
	-$(MAKE) k8s-identity-destroy
	-$(MAKE) k8s-monitoring-destroy
	-$(MAKE) k8s-pki-destroy
	-$(MAKE) k8s-cni-destroy
	@for stack in cni monitoring pki identity security storage; do \
		rm -f stacks/$$stack/terraform.tfstate.backup; \
	done
	@pkill -f 'kubectl port-forward' 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════
# Local (libvirt/KVM)
# ═══════════════════════════════════════════════════════════════════════

.PHONY: local-init local-plan local-apply local-destroy local-kubeconfig local-up local-down

local-init: ## terraform init for local env
	$(TF) -chdir=$(TF_LOCAL) init

local-plan: ## terraform plan for local env
	$(TF) -chdir=$(TF_LOCAL) plan

local-apply: ## terraform apply for local env (creates VMs + bootstraps)
	$(TF) -chdir=$(TF_LOCAL) apply -auto-approve

local-destroy: ## terraform destroy for local env
	$(TF) -chdir=$(TF_LOCAL) destroy -auto-approve

local-kubeconfig: ## Write kubeconfig from local env
	@$(TF) -chdir=$(TF_LOCAL) output -raw kubeconfig > $(HOME)/.kube/talos-local

local-up: local-apply local-kubeconfig ## Create local cluster + deploy k8s stacks
	$(MAKE) ENV=local k8s-up

local-down: ## Destroy local k8s stacks + cluster
	$(MAKE) ENV=local k8s-down
	$(MAKE) local-destroy

# ═══════════════════════════════════════════════════════════════════════
# Outscale
# ═══════════════════════════════════════════════════════════════════════

.PHONY: outscale-init outscale-plan outscale-apply outscale-destroy outscale-kubeconfig outscale-up outscale-down

outscale-init: ## terraform init for Outscale
	$(TF) -chdir=$(TF_OUTSCALE) init

outscale-plan: ## terraform plan for Outscale
	$(TF) -chdir=$(TF_OUTSCALE) plan

outscale-apply: ## terraform apply for Outscale
	$(TF) -chdir=$(TF_OUTSCALE) apply -auto-approve

outscale-destroy: ## terraform destroy for Outscale
	$(TF) -chdir=$(TF_OUTSCALE) destroy -auto-approve

outscale-kubeconfig: ## Write kubeconfig from Outscale env
	@$(TF) -chdir=$(TF_OUTSCALE) output -raw kubeconfig > $(HOME)/.kube/talos-outscale

outscale-up: outscale-apply outscale-kubeconfig ## Create Outscale cluster + deploy k8s stacks
	$(MAKE) ENV=outscale k8s-up

outscale-down: ## Destroy Outscale k8s stacks + cluster
	$(MAKE) ENV=outscale k8s-down
	$(MAKE) outscale-destroy

# ═══════════════════════════════════════════════════════════════════════
# Scaleway — IAM (stage 0)
# Run with your admin credentials. Creates scoped IAM apps for stages 1 & 2.
# ═══════════════════════════════════════════════════════════════════════

.PHONY: scaleway-bootstrap scaleway-iam-init scaleway-iam-apply scaleway-iam-destroy

scaleway-bootstrap: scaleway-iam-init scaleway-iam-apply scaleway-ci-init scaleway-ci-apply ## Bootstrap complet: IAM + CI VM (platform pod)

scaleway-iam-init: ## terraform init for Scaleway IAM
	$(TF) -chdir=$(TF_SCW_IAM) init

scaleway-iam-apply: ## Create IAM apps + API keys (requires secret.tfvars)
	$(TF) -chdir=$(TF_SCW_IAM) apply -auto-approve -var-file=secret.tfvars

scaleway-iam-destroy: ## Destroy Scaleway IAM apps
	$(TF) -chdir=$(TF_SCW_IAM) destroy -auto-approve -var-file=secret.tfvars

# ─── Scaleway — Image (stage 1: two-phase apply) ─────────────────────
# Phase 1: start builder VM (cloud-init builds + uploads image to S3)
# Gate:    wait for S3 upload to complete
# Phase 2: import snapshots + create bootable images

.PHONY: scaleway-image-init scaleway-image-build scaleway-image-wait scaleway-image-apply scaleway-image-destroy

SCW_IMAGE_VARS = \
	-var="project_id=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)" \
	-var="scw_access_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_access_key)" \
	-var="scw_secret_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_secret_key)"

SCW_IMAGE_ENV = \
	SCW_ACCESS_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_access_key) \
	SCW_SECRET_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_secret_key)

scaleway-image-init: ## terraform init for Scaleway image builder
	$(TF) -chdir=$(TF_SCW_IMAGE) init

scaleway-image-build: ## Phase 1: start builder VM
	$(SCW_IMAGE_ENV) $(TF) -chdir=$(TF_SCW_IMAGE) apply -auto-approve \
		-target=scaleway_object_bucket.talos_image \
		-target=scaleway_instance_ip.builder \
		-target=scaleway_instance_server.builder \
		$(SCW_IMAGE_VARS)

scaleway-image-wait: ## Gate: wait for S3 upload (~15 min)
	@BUCKET="talos-image-$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)" && \
		ENDPOINT="https://$$BUCKET.s3.fr-par.scw.cloud/.upload-complete" && \
		echo "Waiting for image upload (polling $$ENDPOINT)..." && \
		for i in $$(seq 1 60); do \
			STATUS=$$(curl -s -o /dev/null -w "%{http_code}" "$$ENDPOINT" 2>/dev/null || echo "000"); \
			[ "$$STATUS" = "200" ] && echo "Upload complete!" && exit 0; \
			echo "  attempt $$i/60 (HTTP $$STATUS)"; sleep 15; \
		done; echo "ERROR: Timeout" && exit 1

scaleway-image-apply: scaleway-image-build scaleway-image-wait ## Build Talos image (full: VM + wait + snapshots)
	$(SCW_IMAGE_ENV) $(TF) -chdir=$(TF_SCW_IMAGE) apply -auto-approve $(SCW_IMAGE_VARS)

scaleway-image-destroy: ## Destroy builder VM + bucket (keeps images & snapshots)
	$(TF) -chdir=$(TF_SCW_IMAGE) state rm scaleway_instance_image.talos 2>/dev/null || true
	$(TF) -chdir=$(TF_SCW_IMAGE) state rm scaleway_instance_snapshot.talos 2>/dev/null || true
	$(TF) -chdir=$(TF_SCW_IMAGE) state rm scaleway_instance_image.talos_block 2>/dev/null || true
	$(TF) -chdir=$(TF_SCW_IMAGE) state rm scaleway_block_snapshot.talos 2>/dev/null || true
	$(SCW_IMAGE_ENV) $(TF) -chdir=$(TF_SCW_IMAGE) destroy -auto-approve $(SCW_IMAGE_VARS)

scaleway-image-clean: ## Destroy ALL image resources (VM + snapshots + images + bucket)
	$(SCW_IMAGE_ENV) $(TF) -chdir=$(TF_SCW_IMAGE) destroy -auto-approve $(SCW_IMAGE_VARS)

# ─── Scaleway — Cluster (stage 2) ────────────────────────────────────

.PHONY: scaleway-init scaleway-plan scaleway-apply scaleway-destroy

scaleway-init: ## terraform init for Scaleway cluster
	$(TF) -chdir=$(TF_SCALEWAY) init

scaleway-plan: ## terraform plan for Scaleway cluster
	SCW_ACCESS_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw cluster_access_key) \
	SCW_SECRET_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw cluster_secret_key) \
	$(TF) -chdir=$(TF_SCALEWAY) plan \
		-var="project_id=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)"

scaleway-apply: ## terraform apply for Scaleway cluster
	SCW_ACCESS_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw cluster_access_key) \
	SCW_SECRET_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw cluster_secret_key) \
	$(TF) -chdir=$(TF_SCALEWAY) apply -auto-approve \
		-var="project_id=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)"

scaleway-destroy: ## terraform destroy for Scaleway cluster
	SCW_ACCESS_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw cluster_access_key) \
	SCW_SECRET_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw cluster_secret_key) \
	$(TF) -chdir=$(TF_SCALEWAY) destroy -auto-approve \
		-var="project_id=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)"

# ─── Scaleway — CI VM (stage 3) ──────────────────────────────────────

.PHONY: scaleway-ci-init scaleway-ci-apply scaleway-ci-destroy

scaleway-ci-init: ## terraform init for CI VM
	$(TF) -chdir=$(TF_SCW_CI) init

scaleway-ci-apply: ## Deploy Gitea + Woodpecker CI VM
	SCW_ACCESS_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw ci_access_key) \
	SCW_SECRET_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw ci_secret_key) \
	$(TF) -chdir=$(TF_SCW_CI) apply -auto-approve \
		-var="project_id=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)" \
		-var="scw_project_id=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)" \
		-var="scw_image_access_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_access_key)" \
		-var="scw_image_secret_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_secret_key)" \
		-var="scw_cluster_access_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw cluster_access_key)" \
		-var="scw_cluster_secret_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw cluster_secret_key)"

scaleway-ci-destroy: ## Destroy Gitea + Woodpecker CI VM
	SCW_ACCESS_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw ci_access_key) \
	SCW_SECRET_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw ci_secret_key) \
	$(TF) -chdir=$(TF_SCW_CI) destroy -auto-approve \
		-var="project_id=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)" \
		-var="scw_project_id=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)" \
		-var="scw_image_access_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_access_key)" \
		-var="scw_image_secret_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_secret_key)" \
		-var="scw_cluster_access_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw cluster_access_key)" \
		-var="scw_cluster_secret_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw cluster_secret_key)"

# ═══════════════════════════════════════════════════════════════════════
# Composite targets (enforce correct ordering)
# ═══════════════════════════════════════════════════════════════════════

.PHONY: scaleway-demo scaleway-up scaleway-down scaleway-teardown scaleway-nuke scaleway-wait

scaleway-demo: ## Full demo: deploy cluster + open Headlamp & Grafana live
	@echo "========================================="
	@echo "  Talos Demo -- full deploy with live dashboard"
	@echo "========================================="
	$(MAKE) scaleway-apply
	$(MAKE) scaleway-wait
	$(MAKE) k8s-cni-apply
	$(MAKE) k8s-pki-apply
	$(MAKE) k8s-monitoring-apply
	@$(KUBECONFIG_CMD) > $(KC_FILE) 2>/dev/null
	@KUBECONFIG=$(KC_FILE) kubectl create serviceaccount headlamp-admin -n kube-system 2>/dev/null || true
	@KUBECONFIG=$(KC_FILE) kubectl create clusterrolebinding headlamp-admin-token --clusterrole=cluster-admin --serviceaccount=kube-system:headlamp-admin 2>/dev/null || true
	@TOKEN=$$(KUBECONFIG=$(KC_FILE) kubectl create token headlamp-admin -n kube-system --duration=48h) && \
		echo "$$TOKEN" | pbcopy && \
		echo "" && \
		echo "  Headlamp: http://localhost:4466 (token in clipboard)" && \
		echo "" && \
		KUBECONFIG=$(KC_FILE) kubectl port-forward -n monitoring svc/headlamp 4466:80 >/dev/null 2>&1 &
	@sleep 2 && open http://localhost:4466
	@echo "Deploying remaining stacks (watch progress in Headlamp)..."
	$(MAKE) k8s-identity-apply
	$(MAKE) k8s-security-apply
	$(MAKE) k8s-storage-apply
	$(MAKE) flux-bootstrap-apply
	@KUBECONFIG=$(KC_FILE) kubectl port-forward -n monitoring svc/grafana 3000:80 >/dev/null 2>&1 &
	@GRAFANA_PASS=$$(KUBECONFIG=$(KC_FILE) kubectl get secret grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d) && \
		echo "$$GRAFANA_PASS" | pbcopy && \
		echo "" && \
		echo "=========================================" && \
		echo "  Demo ready -- all stacks deployed" && \
		echo "  Headlamp: http://localhost:4466" && \
		echo "  Grafana:  http://localhost:3000 (user: admin, password in clipboard)" && \
		echo "========================================="
	@sleep 2 && open http://localhost:3000

scaleway-up: scaleway-apply scaleway-wait scaleway-kubeconfig k8s-up ## Create cluster + all k8s stacks (correct order)

scaleway-wait: ## Wait for K8s API server to be reachable
	@echo "Waiting for API server..."
	@for i in $$(seq 1 30); do \
		$(TF) -chdir=$(TF_SCALEWAY) output -raw kubeconfig 2>/dev/null \
			| kubectl --kubeconfig /dev/stdin get nodes >/dev/null 2>&1 && break; \
		echo "  attempt $$i/30..."; sleep 10; \
	done
	@echo "API server ready."

scaleway-down: k8s-down scaleway-destroy ## Destroy all k8s stacks + cluster (correct order)

scaleway-teardown: scaleway-down scaleway-ci-destroy ## Destroy cluster + CI (keeps IAM + image/snapshot)

scaleway-nuke: ## DANGEROUS: destroy everything including IAM and image
	@echo "This will destroy ALL Scaleway resources: cluster, k8s stacks, CI, image, snapshot, IAM."
	@echo "   Only IAM admin credentials (secret.tfvars) will remain."
	@echo ""
	@read -p "Type 'yes-destroy-everything' to confirm: " confirm && [ "$$confirm" = "yes-destroy-everything" ] || (echo "Aborted."; exit 1)
	-$(MAKE) scaleway-down
	-$(MAKE) scaleway-ci-destroy
	-$(MAKE) scaleway-image-clean
	-$(MAKE) scaleway-iam-destroy

# ═══════════════════════════════════════════════════════════════════════
# Bootstrap (podman platform pod — OpenBao KMS + Gitea + Woodpecker)
#
# Single pod: OpenBao 3-node Raft (tfstate + PKI CA chain) +
#             vault-backend (HTTP proxy) + Gitea + Woodpecker.
# Setup sidecar auto-handles: KMS init, CI setup, repo push, WP secrets.
# Must run BEFORE any tofu command (provides state backend + CA certs).
# Source: bootstrap/
# ═══════════════════════════════════════════════════════════════════════

.PHONY: bootstrap bootstrap-init bootstrap-stop bootstrap-update bootstrap-export bootstrap-tunnel kms-bootstrap kms-stop state-snapshot state-restore

# Aliases (backward compat)
kms-bootstrap: bootstrap
kms-stop: bootstrap-stop

TF_BOOTSTRAP   := bootstrap
BOOTSTRAP_DIR  ?= /tmp/platform-local
BOOTSTRAP_HOST ?= localhost

bootstrap-init: ## terraform init for bootstrap
	$(TF) -chdir=$(TF_BOOTSTRAP) init

bootstrap: bootstrap-init ## Start platform pod (everything auto-initializes inside)
	@command -v podman >/dev/null 2>&1 || { echo "Error: podman required"; exit 1; }
	@mkdir -p $(BOOTSTRAP_DIR)
	$(TF) -chdir=$(TF_BOOTSTRAP) apply -auto-approve \
		-var="source_dir=$(CURDIR)" \
		-var="bootstrap_dir=$(BOOTSTRAP_DIR)"
	@$(TF) -chdir=$(TF_BOOTSTRAP) output -raw status

bootstrap-export: ## Copy tokens + certs from PVC to kms-output/
	@mkdir -p $(KMS_OUTPUT)
	@podman cp platform-tofu-setup:/kms-output/. $(KMS_OUTPUT)/
	@echo "Exported to $(KMS_OUTPUT)/"
	@ls $(KMS_OUTPUT)/

bootstrap-export-remote: ## Copy tokens from remote bootstrap VM via SSH
	@test -n "$(BOOTSTRAP_HOST)" -a "$(BOOTSTRAP_HOST)" != "localhost" || { echo "Set BOOTSTRAP_HOST=<ip>"; exit 1; }
	@mkdir -p $(KMS_OUTPUT)
	scp $(BOOTSTRAP_HOST):/opt/talos/kms-output/* $(KMS_OUTPUT)/
	@echo "Exported from $(BOOTSTRAP_HOST) to $(KMS_OUTPUT)/"

bootstrap-tunnel: ## SSH tunnel to remote bootstrap (vault-backend + OpenBao)
	@test -n "$(BOOTSTRAP_HOST)" -a "$(BOOTSTRAP_HOST)" != "localhost" || { echo "Set BOOTSTRAP_HOST=<ip>"; exit 1; }
	@echo "Tunneling to $(BOOTSTRAP_HOST) — ports 8080 (state) + 8200 (OpenBao)"
	ssh -N -L 8080:localhost:8080 -L 8200:localhost:8200 $(BOOTSTRAP_HOST)

bootstrap-stop: ## Stop the platform pod
	@podman play kube --down $(BOOTSTRAP_DIR)/platform-pod.yaml 2>/dev/null || true

state-snapshot: ## Backup OpenBao Raft snapshot (all states)
	@ROOT_TOKEN=$$(cat $(KMS_OUTPUT)/root-token.txt) && \
		curl -sf -H "X-Vault-Token: $$ROOT_TOKEN" \
			http://127.0.0.1:8200/v1/sys/storage/raft/snapshot \
			-o $(KMS_OUTPUT)/raft-snapshot-$$(date +%Y%m%d-%H%M%S).snap && \
		echo "Raft snapshot saved to $(KMS_OUTPUT)/"

state-restore: ## Restore OpenBao Raft snapshot (SNAPSHOT=path)
	@test -n "$(SNAPSHOT)" || { echo "Usage: make state-restore SNAPSHOT=path/to/file.snap"; exit 1; }
	@ROOT_TOKEN=$$(cat $(KMS_OUTPUT)/root-token.txt) && \
		curl -sf -X PUT -H "X-Vault-Token: $$ROOT_TOKEN" \
			--data-binary @$(SNAPSHOT) \
			http://127.0.0.1:8200/v1/sys/storage/raft/snapshot && \
		echo "Raft snapshot restored from $(SNAPSHOT)"

# ═══════════════════════════════════════════════════════════════════════
# Upgrade workflow (preflight + upgrade + bootstrap-update)
# ═══════════════════════════════════════════════════════════════════════

.PHONY: preflight upgrade bootstrap-update

preflight: ## Pre-upgrade checks (variables, files, connectivity, validate)
	@echo "=== Preflight checks ==="
	@FAIL=0; \
	printf "  %-45s" "TF_VAR_admin_password set:"; \
	if [ -n "$${TF_VAR_admin_password:-}" ]; then echo "OK"; else echo "FAIL (export TF_VAR_admin_password)"; FAIL=1; fi; \
	printf "  %-45s" "kms-output/approle-role-id.txt:"; \
	if [ -f "$(KMS_OUTPUT)/approle-role-id.txt" ]; then echo "OK"; else echo "FAIL"; FAIL=1; fi; \
	printf "  %-45s" "kms-output/approle-secret-id.txt:"; \
	if [ -f "$(KMS_OUTPUT)/approle-secret-id.txt" ]; then echo "OK"; else echo "FAIL"; FAIL=1; fi; \
	printf "  %-45s" "vault-backend reachable (:8080):"; \
	if curl -so /dev/null -w '%{http_code}' http://localhost:8080/state/test 2>/dev/null | grep -qE '^(2|4)'; then echo "OK"; else echo "FAIL (run make bootstrap)"; FAIL=1; fi; \
	echo ""; \
	echo "  Validating stacks..."; \
	for dir in $(STACKS); do \
		printf "    %-43s" "$$dir:"; \
		rm -rf "$$dir/.terraform" "$$dir/.terraform.lock.hcl"; \
		if $(TF) -chdir="$$dir" init -backend=false -input=false >/dev/null 2>&1 \
			&& $(TF) -chdir="$$dir" validate >/dev/null 2>&1; then \
			echo "OK"; \
		else echo "FAIL"; FAIL=1; fi; \
	done; \
	echo ""; \
	if [ $$FAIL -eq 0 ]; then echo "=== All preflight checks passed ==="; \
	else echo "=== PREFLIGHT FAILED — fix errors above ==="; exit 1; fi

upgrade: preflight ## Full upgrade: preflight → snapshot → bootstrap-update → provider → k8s
	@echo ""
	@echo "========================================="
	@echo "  Upgrade — ENV=$(ENV)"
	@echo "========================================="
	@echo ""
	@echo "--- Taking state snapshot (backup) ---"
	$(MAKE) state-snapshot
	@echo ""
	@if git diff HEAD~1 --name-only 2>/dev/null | grep -q '^bootstrap/'; then \
		echo "--- bootstrap/ changed — updating platform pod ---"; \
		$(MAKE) bootstrap-update; \
		echo ""; \
	else \
		echo "--- bootstrap/ unchanged — skipping ---"; \
		echo ""; \
	fi
	@echo "--- Applying provider $(ENV) ---"
	$(MAKE) $(ENV)-apply
	@echo ""
	@echo "--- Deploying all k8s stacks ---"
	$(MAKE) k8s-up
	@echo ""
	@echo "========================================="
	@echo "  Upgrade complete (ENV=$(ENV))"
	@echo "========================================="
	@echo "  Changed files (last commit):"
	@git diff HEAD~1 --stat 2>/dev/null || echo "  (could not determine)"
	@echo "========================================="

bootstrap-update: ## Update running bootstrap pod in-place (preserves PVC data)
	@command -v podman >/dev/null 2>&1 || { echo "Error: podman required"; exit 1; }
	@test -f "$(BOOTSTRAP_DIR)/platform-pod.yaml" || { echo "Error: $(BOOTSTRAP_DIR)/platform-pod.yaml not found. Run make bootstrap first."; exit 1; }
	@test -f "$(BOOTSTRAP_DIR)/configmap.yaml" || { echo "Error: $(BOOTSTRAP_DIR)/configmap.yaml not found. Run make bootstrap first."; exit 1; }
	@echo "--- Updating platform pod (--replace) ---"
	podman play kube --replace $(BOOTSTRAP_DIR)/platform-pod.yaml \
		--configmap=$(BOOTSTRAP_DIR)/configmap.yaml
	@echo "--- Platform pod updated (PVC data preserved) ---"

# ═══════════════════════════════════════════════════════════════════════
# Arbor (staging tree — pre-pull images, charts, git)
# ═══════════════════════════════════════════════════════════════════════

ARBOR_DIR := arbor

.PHONY: arbor arbor-verify

arbor: ## Pre-stage all images, Helm charts, and git repo for deployment
	@echo "=== Arbor: staging deployment artifacts ==="
	@mkdir -p $(ARBOR_DIR)/charts
	@echo ""
	@echo "--- Pulling container images from platform-pod.yaml ---"
	@grep -E '^\s+image:' bootstrap/platform-pod.yaml \
		| sed 's/.*image:\s*//' | sort -u | while read -r img; do \
		echo "  podman pull $$img"; \
		podman pull "$$img"; \
	done
	@echo ""
	@echo "--- Pulling Helm charts from stacks ---"
	@for dir in stacks/*/; do \
		stack=$$(basename "$$dir"); \
		vars="$$dir/variables.tf"; \
		main="$$dir/main.tf"; \
		[ -f "$$main" ] || continue; \
		grep -E 'repository\s*=' "$$main" | sed 's/.*=\s*"\(.*\)"/\1/' | while read -r repo; do \
			chart=$$(grep -A1 "repository.*$$repo" "$$main" | grep 'chart\s*=' | head -1 | sed 's/.*=\s*"\(.*\)"/\1/'); \
			[ -z "$$chart" ] && continue; \
			echo "$$chart" | grep -q '/' && continue; \
			version=$$(grep -B5 "chart.*$$chart" "$$main" | grep 'version\s*=' | head -1 | sed 's/.*=\s*"\{0,1\}\(var\.\)\{0,1\}//;s/"\{0,1\}\s*$$//' ); \
			if echo "$$version" | grep -q '^var\.'; then \
				varname=$$(echo "$$version" | sed 's/var\.//'); \
				version=$$(grep -A3 "variable.*$$varname" "$$vars" | grep 'default' | sed 's/.*=\s*"\(.*\)"/\1/'); \
			fi; \
			[ -z "$$version" ] && continue; \
			echo "  helm pull $$chart ($$version) from $$repo"; \
			helm pull "$$chart" --repo "$$repo" --version "$$version" \
				-d $(ARBOR_DIR)/charts 2>/dev/null || \
			echo "    WARN: failed to pull $$chart $$version from $$repo"; \
		done; \
	done
	@echo ""
	@echo "--- Generating manifest ---"
	@{ \
		echo '{'; \
		echo '  "generated": "'$$(date -u +%Y-%m-%dT%H:%M:%SZ)'",' ; \
		echo '  "images": ['; \
		grep -E '^\s+image:' bootstrap/platform-pod.yaml \
			| sed 's/.*image:\s*//' | sort -u | while read -r img; do \
			digest=$$(podman image inspect "$$img" --format '{{index .Digest}}' 2>/dev/null || echo "unknown"); \
			echo "    {\"image\": \"$$img\", \"sha256\": \"$$digest\"},"; \
		done; \
		echo '    null'; \
		echo '  ],'; \
		echo '  "charts": ['; \
		for f in $(ARBOR_DIR)/charts/*.tgz; do \
			[ -f "$$f" ] || continue; \
			sha=$$(shasum -a 256 "$$f" | cut -d' ' -f1); \
			echo "    {\"file\": \"$$(basename $$f)\", \"sha256\": \"$$sha\"},"; \
		done; \
		echo '    null'; \
		echo '  ]'; \
		echo '}'; \
	} > $(ARBOR_DIR)/manifest.json
	@echo "  Manifest written to $(ARBOR_DIR)/manifest.json"
	@echo ""
	@echo "=== Arbor staging complete ==="

arbor-verify: ## Verify arbor staging tree is complete
	@echo "=== Arbor verification ==="
	@FAIL=0; \
	echo ""; \
	echo "--- Container images ---"; \
	grep -E '^\s+image:' bootstrap/platform-pod.yaml \
		| sed 's/.*image:\s*//' | sort -u | while read -r img; do \
		printf "  %-60s" "$$img:"; \
		if podman image exists "$$img" 2>/dev/null; then echo "OK"; \
		else echo "MISSING"; FAIL=1; fi; \
	done; \
	echo ""; \
	echo "--- Helm charts ---"; \
	if [ ! -f "$(ARBOR_DIR)/manifest.json" ]; then \
		echo "  FAIL: $(ARBOR_DIR)/manifest.json not found (run make arbor first)"; \
		exit 1; \
	fi; \
	for f in $(ARBOR_DIR)/charts/*.tgz; do \
		[ -f "$$f" ] || continue; \
		sha_actual=$$(shasum -a 256 "$$f" | cut -d' ' -f1); \
		basename_f=$$(basename "$$f"); \
		sha_expected=$$(grep "$$basename_f" $(ARBOR_DIR)/manifest.json | sed 's/.*sha256.*: *"\([a-f0-9]*\)".*/\1/' | head -1); \
		printf "  %-60s" "$$basename_f:"; \
		if [ "$$sha_actual" = "$$sha_expected" ]; then echo "OK"; \
		else echo "SHA256 MISMATCH"; FAIL=1; fi; \
	done; \
	echo ""; \
	if [ $$FAIL -eq 0 ]; then echo "=== Arbor verification passed ==="; \
	else echo "=== VERIFICATION FAILED ==="; exit 1; fi

# ═══════════════════════════════════════════════════════════════════════
# Day-2 operations (post-deploy)
#
# In-cluster OpenBao is initialized automatically by k8s-pki (K8s Job).
# Tokens are stored in K8s Secrets (secrets/openbao-infra-token, etc.).
# ═══════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════
# VMware airgap (scripts, not Terraform)
# ═══════════════════════════════════════════════════════════════════════

.PHONY: vmware-image-cache vmware-build-ova vmware-gen-configs vmware-bootstrap

vmware-image-cache: ## Build OCI image cache for airgap (requires Internet)
	@$(MAKE) -C $(VMWARE) image-cache

vmware-build-ova: ## Build OVA with embedded image cache
	@$(MAKE) -C $(VMWARE) build-ova

vmware-gen-configs: ## Generate per-node machine configs (static IPs)
	@$(MAKE) -C $(VMWARE) gen-configs

vmware-bootstrap: ## Bootstrap etcd + kubeconfig (post-deployment)
	@$(MAKE) -C $(VMWARE) bootstrap

# ═══════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════

.PHONY: scaleway-test scaleway-iam-test scaleway-image-test scaleway-cluster-test k8s-cni-test

scaleway-test: scaleway-iam-test scaleway-image-test scaleway-cluster-test k8s-cni-test ## Run all Scaleway tofu tests

scaleway-iam-test: ## tofu test for IAM stage
	$(TF) -chdir=$(TF_SCW_IAM) test

scaleway-image-test: ## tofu test for image stage
	$(TF) -chdir=$(TF_SCW_IMAGE) test

scaleway-cluster-test: ## tofu test for cluster stage
	$(TF) -chdir=$(TF_SCALEWAY) test

k8s-cni-test: ## tofu test for k8s-cni stack
	$(TF) -chdir=$(TF_CNI) test

# ═══════════════════════════════════════════════════════════════════════
# UI Access
# ═══════════════════════════════════════════════════════════════════════

KUBECONFIG_CMD = $(TF) -chdir=$(TF_SCALEWAY) output -raw kubeconfig

.PHONY: scaleway-kubeconfig scaleway-headlamp scaleway-grafana scaleway-harbor

scaleway-kubeconfig: ## Export kubeconfig to ~/.kube/talos-scaleway
	@$(KUBECONFIG_CMD) > $(HOME)/.kube/talos-scaleway 2>/dev/null
	@echo "export KUBECONFIG=$(HOME)/.kube/talos-scaleway"

scaleway-headlamp: scaleway-kubeconfig ## Open Headlamp UI (token copied to clipboard)
	@KUBECONFIG=$(KC_FILE) kubectl create serviceaccount headlamp-admin -n kube-system 2>/dev/null || true
	@KUBECONFIG=$(KC_FILE) kubectl create clusterrolebinding headlamp-admin-token --clusterrole=cluster-admin --serviceaccount=kube-system:headlamp-admin 2>/dev/null || true
	@TOKEN=$$(KUBECONFIG=$(KC_FILE) kubectl create token headlamp-admin -n kube-system --duration=48h) && \
		echo "$$TOKEN" | pbcopy && \
		echo "Token copied to clipboard. Paste it in the Headlamp login page." && \
		echo "" && \
		KUBECONFIG=$(KC_FILE) kubectl port-forward -n monitoring svc/headlamp 4466:80 &  \
		sleep 2 && open http://localhost:4466

scaleway-harbor: scaleway-kubeconfig ## Open Harbor UI (admin password in clipboard)
	@PASSWORD=$$($(TF) -chdir=$(TF_STORAGE) output -raw harbor_admin_password) && \
		echo "$$PASSWORD" | pbcopy && \
		echo "Harbor admin password copied to clipboard (user: admin)" && \
		echo "" && \
		KUBECONFIG=$(KC_FILE) kubectl port-forward -n storage svc/harbor 8080:80 & \
		sleep 2 && open http://localhost:8080

scaleway-grafana: scaleway-kubeconfig ## Open Grafana UI
	@echo "Opening Grafana..." && \
		KUBECONFIG=$(KC_FILE) kubectl port-forward -n monitoring svc/grafana 3000:80 & \
		sleep 2 && open http://localhost:3000

# ═══════════════════════════════════════════════════════════════════════
# Tests (Chainsaw — declarative K8s e2e)
# ═══════════════════════════════════════════════════════════════════════

STACKS := envs/scaleway/image envs/scaleway envs/scaleway/ci \
	stacks/cni stacks/monitoring stacks/pki \
	stacks/identity stacks/security stacks/storage \
	stacks/flux-bootstrap

.PHONY: validate velero-test test clean

validate: ## Validate all Terraform stacks
	@FAIL=0; for dir in $(STACKS); do \
		printf "  %-45s" "$$dir:"; \
		rm -rf "$$dir/.terraform" "$$dir/.terraform.lock.hcl"; \
		if $(TF) -chdir="$$dir" init -backend=false -input=false >/dev/null 2>&1 \
			&& $(TF) -chdir="$$dir" validate >/dev/null 2>&1; then \
			echo "OK"; \
		else echo "FAIL"; FAIL=1; fi; \
	done; [ $$FAIL -eq 0 ]

velero-test: ## Run Velero backup/restore e2e test (Chainsaw)
	@command -v chainsaw >/dev/null 2>&1 || { echo "Error: chainsaw required (brew install kyverno/tap/chainsaw)"; exit 1; }
	KUBECONFIG=$(KC_FILE) chainsaw test tests/velero/

test: validate velero-test ## Run all tests (validate + e2e)

clean: ## Remove all build artifacts
	rm -rf $(OUT_DIR)
	rm -rf $(VMWARE)/_out $(VMWARE)/image-cache.oci
