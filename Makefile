include vars.mk

TF := tofu

# ═══════════════════════════════════════════════════════════════════════
# Context selection — every cluster-scoped target needs these three:
#
#   ENV      = dev | staging | prod
#   INSTANCE = 'shared' (dev default), 'alice', 'eu', ...
#   REGION   = fr-par | nl-ams | pl-waw | ...
#
# The triple (ENV, INSTANCE, REGION) uniquely identifies a cluster.
# Context YAML: contexts/$(ENV)-$(INSTANCE)-$(REGION).yaml
# Context ID:   $(NAMESPACE)-$(ENV)-$(INSTANCE)-$(REGION)
#
# Override on the CLI:
#   make scaleway-apply ENV=prod INSTANCE=eu REGION=nl-ams
# ═══════════════════════════════════════════════════════════════════════

NAMESPACE ?= st4ck
ENV       ?= dev
INSTANCE  ?= shared
REGION    ?= fr-par

CTX_FILE := $(CURDIR)/contexts/$(ENV)-$(INSTANCE)-$(REGION).yaml
CTX_ID   := $(NAMESPACE)-$(ENV)-$(INSTANCE)-$(REGION)
CTX_PATH := $(NAMESPACE)/$(ENV)/$(INSTANCE)/$(REGION)
KC_FILE  := $(HOME)/.kube/$(CTX_ID)

# Provider selection (which envs/ subdir hosts the cluster infra).
PROVIDER ?= scaleway

# ─── Bootstrap OpenBao (vault-backend → KV v2) ──────────────────────────
# AppRole credentials from platform-kms-output volume. vault-backend speaks
# HTTP on :8080 (localhost or tunnelled from remote CI VM).
KMS_OUTPUT         := kms-output
VB_HOST            ?= localhost
VB_PORT            ?= 8080
VB_URL             := http://$(VB_HOST):$(VB_PORT)
# Lazy (=, not :=) so each sub-make/tofu call re-reads from disk. Critical
# during scaleway-bootstrap-vm where kms-output/ is populated mid-run.
export TF_HTTP_USERNAME = $(shell cat $(KMS_OUTPUT)/approle-role-id.txt 2>/dev/null)
export TF_HTTP_PASSWORD = $(shell cat $(KMS_OUTPUT)/approle-secret-id.txt 2>/dev/null)

# ─── Stack paths ─────────────────────────────────────────────────────────

TF_CNI        := stacks/cni
TF_MONITORING := stacks/monitoring
TF_PKI        := stacks/pki
TF_IDENTITY   := stacks/identity
TF_SECURITY   := stacks/security
TF_STORAGE    := stacks/storage
TF_FLUX       := stacks/flux-bootstrap
GARAGE_CHART  := stacks/storage/chart
LPP_CHART     := stacks/storage/chart-local-path

# ─── Provider paths ──────────────────────────────────────────────────────

TF_LOCAL     := envs/local
TF_SCALEWAY  := envs/scaleway
TF_SCW_IAM   := envs/scaleway/iam
TF_SCW_IMAGE := envs/scaleway/image
TF_SCW_CI    := envs/scaleway/ci
VMWARE       := envs/vmware-airgap

# ─── Backend-config helper ───────────────────────────────────────────────
# All state-using stages share the same base URL; only the path differs.
# Usage: $(call tf_init,<dir>,<path_under_/state/>)
#
# Backend selection:
#   - default: vault-backend (HTTP). Loud failure if unreachable — better
#     than silently switching backends, which would orphan state already
#     stored in vault-backend.
#   - LOCAL_BACKEND=1 explicitly opts into local state via OpenTofu's
#     override-file convention: a file matching *_override.tf overlays the
#     same blocks in other .tf files. We drop a `_local_backend_override.tf`
#     into the module dir, which switches the backend block to "local"
#     without editing the tracked backend.tf. After `make scaleway-migrate-state-up`,
#     the override is removed and the module reverts to HTTP backend.
#     Used during the chicken-and-egg first CI VM bootstrap, where
#     vault-backend lives ON the VM we're provisioning.
LOCAL_BACKEND ?=

define _local_backend_override
terraform {
  backend "local" {}
}
endef
export _local_backend_override

define tf_init
	@if [ -n "$(LOCAL_BACKEND)" ]; then \
		echo ">>> [tf_init] LOCAL_BACKEND=1 — overlay local backend in $(1)"; \
		printf '%s\n' "$$_local_backend_override" > $(1)/_local_backend_override.tf; \
		$(TF) -chdir=$(1) init -reconfigure -input=false; \
	else \
		rm -f $(1)/_local_backend_override.tf; \
		$(TF) -chdir=$(1) init -reconfigure -input=false \
			-backend-config="address=$(VB_URL)/state/$(2)" \
			-backend-config="lock_address=$(VB_URL)/state/$(2)" \
			-backend-config="unlock_address=$(VB_URL)/state/$(2)"; \
	fi
endef

# Stack-scoped state paths — hierarchical under the current context.
STATE_CLUSTER    := $(CTX_PATH)/cluster
STATE_CI         := $(CTX_PATH)/ci
STATE_IMAGE      := $(NAMESPACE)/_image/$(REGION)
STATE_CNI        := $(CTX_PATH)/cni
STATE_PKI        := $(CTX_PATH)/pki
STATE_MONITORING := $(CTX_PATH)/monitoring
STATE_IDENTITY   := $(CTX_PATH)/identity
STATE_SECURITY   := $(CTX_PATH)/security
STATE_STORAGE    := $(CTX_PATH)/storage
STATE_FLUX       := $(CTX_PATH)/flux-bootstrap

.PHONY: help

help: ## Show this help
	@echo "Context: ENV=$(ENV) INSTANCE=$(INSTANCE) REGION=$(REGION)  →  $(CTX_ID)"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'

context: ## Show the current context (derived from ENV/INSTANCE/REGION)
	@echo "NAMESPACE = $(NAMESPACE)"
	@echo "ENV       = $(ENV)"
	@echo "INSTANCE  = $(INSTANCE)"
	@echo "REGION    = $(REGION)"
	@echo "CTX_ID    = $(CTX_ID)"
	@echo "CTX_FILE  = $(CTX_FILE)"
	@echo "CTX_PATH  = $(CTX_PATH)"
	@echo "KC_FILE   = $(KC_FILE)"
	@echo "VB_URL    = $(VB_URL)"
	@test -f "$(CTX_FILE)" || { echo ""; echo "WARN: $(CTX_FILE) does not exist — create it before apply."; exit 0; }

# ═══════════════════════════════════════════════════════════════════════
# K8s stacks — applied to the cluster identified by (ENV, INSTANCE, REGION).
# Each stack has its own state path under the context.
# ═══════════════════════════════════════════════════════════════════════

K8S_COMMON_VARS = \
	-var="kubeconfig_path=$(KC_FILE)"

# Stacks that read pki outputs via data.terraform_remote_state need the
# parameterized HTTP backend address + AppRole creds. Same path as
# `tf_init` builds for the pki stack (STATE_PKI under CTX_PATH).
K8S_PKI_REMOTE_STATE_VARS = \
	-var="pki_state_address=$(VB_URL)/state/$(STATE_PKI)" \
	-var="pki_state_username=$(TF_HTTP_USERNAME)" \
	-var="pki_state_password=$(TF_HTTP_PASSWORD)"

# ─── k8s-cni ─────────────────────────────────────────────────────────────

.PHONY: k8s-cni-init k8s-cni-apply k8s-cni-destroy

k8s-cni-init: ## terraform init for k8s-cni (context-scoped state)
	$(call tf_init,$(TF_CNI),$(STATE_CNI))

k8s-cni-apply: k8s-cni-init ## Deploy Cilium CNI to the current context
	$(TF) -chdir=$(TF_CNI) apply -auto-approve $(K8S_COMMON_VARS)

k8s-cni-destroy: k8s-cni-init
	$(TF) -chdir=$(TF_CNI) destroy -auto-approve $(K8S_COMMON_VARS)

# ─── k8s-monitoring ──────────────────────────────────────────────────────

.PHONY: k8s-monitoring-init k8s-monitoring-apply k8s-monitoring-destroy

k8s-monitoring-init:
	$(call tf_init,$(TF_MONITORING),$(STATE_MONITORING))

k8s-monitoring-apply: k8s-monitoring-init ## Deploy monitoring stack
	$(TF) -chdir=$(TF_MONITORING) apply -auto-approve $(K8S_COMMON_VARS)

k8s-monitoring-destroy: k8s-monitoring-init
	$(TF) -chdir=$(TF_MONITORING) destroy -auto-approve $(K8S_COMMON_VARS)

# ─── k8s-pki ─────────────────────────────────────────────────────────────

.PHONY: k8s-pki-init k8s-pki-apply k8s-pki-destroy

k8s-pki-init:
	$(call tf_init,$(TF_PKI),$(STATE_PKI))

k8s-pki-apply: k8s-pki-init ## Deploy PKI + OpenBao + cert-manager
	$(TF) -chdir=$(TF_PKI) apply -auto-approve $(K8S_COMMON_VARS)

k8s-pki-destroy: k8s-pki-init
	$(TF) -chdir=$(TF_PKI) destroy -auto-approve $(K8S_COMMON_VARS)

# ─── k8s-identity ────────────────────────────────────────────────────────

.PHONY: k8s-identity-init k8s-identity-apply k8s-identity-destroy

k8s-identity-init:
	$(call tf_init,$(TF_IDENTITY),$(STATE_IDENTITY))

k8s-identity-apply: k8s-identity-init ## Deploy Kratos + Hydra + Pomerium
	@echo "[identity] phase 1/3: deploy CNPG operator + identity-pg cluster CR"
	$(TF) -chdir=$(TF_IDENTITY) apply -auto-approve $(K8S_COMMON_VARS) $(K8S_PKI_REMOTE_STATE_VARS) \
		-target=helm_release.cnpg_operator \
		-target=kubectl_manifest.identity_pg_cluster \
		-target=kubernetes_namespace.identity
	@echo "[identity] phase 2/3: wait for CNPG to materialise the identity-pg-app secret (~60s)"
	@KUBECONFIG=$(KC_FILE) kubectl -n identity wait --for=create secret/identity-pg-app --timeout=180s
	@echo "[identity] phase 3/3: full apply (Kratos/Hydra/Pomerium consume the now-existing PG DSN)"
	$(TF) -chdir=$(TF_IDENTITY) apply -auto-approve $(K8S_COMMON_VARS) $(K8S_PKI_REMOTE_STATE_VARS)

k8s-identity-destroy: k8s-identity-init
	$(TF) -chdir=$(TF_IDENTITY) destroy -auto-approve $(K8S_COMMON_VARS) $(K8S_PKI_REMOTE_STATE_VARS)

# ─── k8s-security ────────────────────────────────────────────────────────

.PHONY: k8s-security-init k8s-security-apply k8s-security-destroy

k8s-security-init:
	$(call tf_init,$(TF_SECURITY),$(STATE_SECURITY))

k8s-security-apply: k8s-security-init ## Deploy Trivy + Tetragon + Kyverno
	$(TF) -chdir=$(TF_SECURITY) apply -auto-approve $(K8S_COMMON_VARS)

k8s-security-destroy: k8s-security-init
	$(TF) -chdir=$(TF_SECURITY) destroy -auto-approve $(K8S_COMMON_VARS)

# ─── k8s-storage ─────────────────────────────────────────────────────────

.PHONY: k8s-storage-init k8s-storage-apply k8s-storage-destroy garage-chart lpp-chart

garage-chart: ## Fetch Garage Helm chart (v2.2.0) from upstream
	@mkdir -p $(GARAGE_CHART)
	@curl -sL "https://git.deuxfleurs.fr/Deuxfleurs/garage/archive/v2.2.0.tar.gz" | \
		tar -xz --strip-components=4 -C $(GARAGE_CHART) "garage/script/helm/garage/"
	@echo "Garage Helm chart fetched to $(GARAGE_CHART)/"

lpp-chart: ## Fetch local-path-provisioner Helm chart (v0.0.35) from Rancher upstream
	@mkdir -p $(LPP_CHART)
	@# strip-components=4 puts Chart.yaml directly in $(LPP_CHART)/ (matches what
	# helm_release.local_path_provisioner expects via chart="${path.module}/chart-local-path")
	@curl -sL "https://github.com/rancher/local-path-provisioner/archive/refs/tags/v0.0.35.tar.gz" | \
		tar -xz --strip-components=4 -C $(LPP_CHART) "local-path-provisioner-0.0.35/deploy/chart/local-path-provisioner/"
	@echo "local-path-provisioner Helm chart fetched to $(LPP_CHART)/"

k8s-storage-init: garage-chart lpp-chart
	$(call tf_init,$(TF_STORAGE),$(STATE_STORAGE))

k8s-storage-apply: k8s-storage-init ## Deploy local-path + Garage + Velero + Harbor
	$(TF) -chdir=$(TF_STORAGE) apply -auto-approve $(K8S_COMMON_VARS) $(K8S_PKI_REMOTE_STATE_VARS)

k8s-storage-destroy: k8s-storage-init
	$(TF) -chdir=$(TF_STORAGE) destroy -auto-approve $(K8S_COMMON_VARS) $(K8S_PKI_REMOTE_STATE_VARS)

# ─── flux-bootstrap ──────────────────────────────────────────────────────

.PHONY: flux-bootstrap-init flux-bootstrap-apply flux-bootstrap-destroy

flux-bootstrap-init:
	$(call tf_init,$(TF_FLUX),$(STATE_FLUX))

flux-bootstrap-apply: flux-bootstrap-init ## Install Flux + GitRepository + root Kustomization
	@echo "--- Scanning Gitea SSH host key from $(VB_HOST):2222 ---"
	$(eval GITEA_KNOWN_HOSTS := $(shell ssh-keyscan -p 2222 -t ed25519,rsa $(VB_HOST) 2>/dev/null))
	@test -n "$(GITEA_KNOWN_HOSTS)" || { echo "ERROR: ssh-keyscan failed for $(VB_HOST):2222. Is Gitea running?"; exit 1; }
	$(TF) -chdir=$(TF_FLUX) apply -auto-approve $(K8S_COMMON_VARS) \
		-var="gitea_known_hosts=$(GITEA_KNOWN_HOSTS)"

flux-bootstrap-destroy: flux-bootstrap-init
	$(eval GITEA_KNOWN_HOSTS := $(shell ssh-keyscan -p 2222 -t ed25519,rsa $(VB_HOST) 2>/dev/null || echo "destroy-noop ssh-ed25519 AAAA"))
	$(TF) -chdir=$(TF_FLUX) destroy -auto-approve $(K8S_COMMON_VARS) \
		-var="gitea_known_hosts=$(GITEA_KNOWN_HOSTS)"

# ─── KaaS stacks — Kamaji + CAPI + autoscaling + gateway (management cluster) ──

TF_CAPI           := stacks/capi
TF_KAMAJI         := stacks/kamaji
TF_AUTOSCALING    := stacks/autoscaling
TF_GATEWAY_API    := stacks/gateway-api
TF_MANAGED        := stacks/managed-cluster

STATE_CAPI        := $(CTX_PATH)/capi
STATE_KAMAJI      := $(CTX_PATH)/kamaji
STATE_AUTOSCALING := $(CTX_PATH)/autoscaling
STATE_GATEWAY_API := $(CTX_PATH)/gateway-api
STATE_MANAGED     := $(CTX_PATH)/managed-cluster

.PHONY: k8s-capi-init k8s-capi-apply k8s-capi-destroy

k8s-capi-init:
	$(call tf_init,$(TF_CAPI),$(STATE_CAPI))

k8s-capi-apply: k8s-capi-init ## Install CAPI + CAPS + CABPT + Kamaji CP provider
	$(TF) -chdir=$(TF_CAPI) apply -auto-approve $(K8S_COMMON_VARS) \
		-var="scw_access_key=$(SCW_CLUSTER_AK)" \
		-var="scw_secret_key=$(SCW_CLUSTER_SK)" \
		-var="scw_project_id=$(SCW_PROJECT_ID)" \
		-var="scw_region=$(REGION)"

k8s-capi-destroy: k8s-capi-init
	$(TF) -chdir=$(TF_CAPI) destroy -auto-approve $(K8S_COMMON_VARS) \
		-var="scw_access_key=$(SCW_CLUSTER_AK)" \
		-var="scw_secret_key=$(SCW_CLUSTER_SK)" \
		-var="scw_project_id=$(SCW_PROJECT_ID)" \
		-var="scw_region=$(REGION)"

.PHONY: k8s-kamaji-init k8s-kamaji-apply k8s-kamaji-destroy

k8s-kamaji-init:
	$(call tf_init,$(TF_KAMAJI),$(STATE_KAMAJI))

k8s-kamaji-apply: k8s-kamaji-init ## Install Kamaji operator + Ænix etcd-operator
	$(TF) -chdir=$(TF_KAMAJI) apply -auto-approve $(K8S_COMMON_VARS)

k8s-kamaji-destroy: k8s-kamaji-init
	$(TF) -chdir=$(TF_KAMAJI) destroy -auto-approve $(K8S_COMMON_VARS)

.PHONY: k8s-autoscaling-init k8s-autoscaling-apply k8s-autoscaling-destroy

k8s-autoscaling-init:
	$(call tf_init,$(TF_AUTOSCALING),$(STATE_AUTOSCALING))

k8s-autoscaling-apply: k8s-autoscaling-init ## Install Karpenter + HPA/VPA/KEDA + Prometheus Adapter
	$(TF) -chdir=$(TF_AUTOSCALING) apply -auto-approve $(K8S_COMMON_VARS)

k8s-autoscaling-destroy: k8s-autoscaling-init
	$(TF) -chdir=$(TF_AUTOSCALING) destroy -auto-approve $(K8S_COMMON_VARS)

.PHONY: k8s-gateway-api-init k8s-gateway-api-apply k8s-gateway-api-destroy

k8s-gateway-api-init:
	$(call tf_init,$(TF_GATEWAY_API),$(STATE_GATEWAY_API))

k8s-gateway-api-apply: k8s-gateway-api-init ## Install Gateway API CRDs + shared Cilium Gateway
	$(TF) -chdir=$(TF_GATEWAY_API) apply -auto-approve $(K8S_COMMON_VARS)

k8s-gateway-api-destroy: k8s-gateway-api-init
	$(TF) -chdir=$(TF_GATEWAY_API) destroy -auto-approve $(K8S_COMMON_VARS)

# ─── Managed tenant cluster — 1 CR renders everything ───────────────────
# Usage (tenant 'alice' in fr-par):
#   make managed-cluster-apply ENV=tenant INSTANCE=alice REGION=fr-par

.PHONY: managed-cluster-init managed-cluster-apply managed-cluster-destroy

managed-cluster-init:
	$(call tf_init,$(TF_MANAGED),$(STATE_MANAGED))

managed-cluster-apply: managed-cluster-init ## Provision a tenant cluster from the current context
	@test -f "$(CTX_FILE)" || { echo "ERROR: $(CTX_FILE) not found"; exit 1; }
	$(TF) -chdir=$(TF_MANAGED) apply -auto-approve $(K8S_COMMON_VARS) \
		-var="context_file=$(CTX_FILE)" \
		-var="scw_project_id=$(SCW_PROJECT_ID)" \
		-var="talos_image_name=$$($(TF) -chdir=$(TF_SCW_IMAGE) output -raw image_name 2>/dev/null || echo 'UNSET')"

managed-cluster-destroy: managed-cluster-init
	$(TF) -chdir=$(TF_MANAGED) destroy -auto-approve $(K8S_COMMON_VARS) \
		-var="context_file=$(CTX_FILE)" \
		-var="scw_project_id=$(SCW_PROJECT_ID)" \
		-var="talos_image_name=$$($(TF) -chdir=$(TF_SCW_IMAGE) output -raw image_name 2>/dev/null || echo 'UNSET')"

# ─── KaaS bring-up (order matters) ──────────────────────────────────────
.PHONY: kaas-up kaas-down

kaas-up: ## Bring up the full KaaS control plane on the current mgmt cluster
	$(MAKE) k8s-capi-apply
	$(MAKE) k8s-kamaji-apply
	$(MAKE) k8s-autoscaling-apply
	$(MAKE) k8s-gateway-api-apply

kaas-down: ## Tear down the KaaS control plane (keeps core k8s stacks)
	-$(MAKE) k8s-gateway-api-destroy
	-$(MAKE) k8s-autoscaling-destroy
	-$(MAKE) k8s-kamaji-destroy
	-$(MAKE) k8s-capi-destroy

# ─── Composite: all k8s stacks for current context ──────────────────────

.PHONY: k8s-init k8s-up k8s-down

k8s-init: k8s-cni-init k8s-monitoring-init k8s-pki-init k8s-identity-init k8s-security-init k8s-storage-init flux-bootstrap-init ## terraform init every k8s stack

k8s-up: ## Deploy every k8s stack to the current context (ENV, INSTANCE, REGION)
	@curl -so /dev/null -w '%{http_code}' $(VB_URL)/state/test 2>/dev/null | grep -qE '^(2|4)' || { echo "ERROR: vault-backend not reachable at $(VB_URL). Run 'make bootstrap' or 'make bootstrap-tunnel'."; exit 1; }
	$(MAKE) k8s-cni-apply
	$(MAKE) k8s-storage-init
	$(TF) -chdir=$(TF_STORAGE) apply -auto-approve $(K8S_COMMON_VARS) $(K8S_PKI_REMOTE_STATE_VARS) -target=helm_release.local_path_provisioner -target=kubernetes_namespace.storage
	$(MAKE) k8s-pki-apply
	$(MAKE) k8s-monitoring-apply
	$(MAKE) k8s-identity-apply
	$(MAKE) k8s-security-apply
	$(MAKE) k8s-storage-apply
	$(MAKE) flux-bootstrap-apply

k8s-down: ## Destroy every k8s stack on the current context (correct order)
	@curl -so /dev/null -w '%{http_code}' $(VB_URL)/state/test 2>/dev/null | grep -qE '^(2|4)' || { echo "ERROR: vault-backend not reachable at $(VB_URL)."; exit 1; }
	@# Remove Kyverno webhooks first to prevent them blocking other deletions
	@KUBECONFIG=$(KC_FILE) kubectl delete mutatingwebhookconfiguration -l app.kubernetes.io/instance=kyverno --ignore-not-found 2>/dev/null || true
	@KUBECONFIG=$(KC_FILE) kubectl delete validatingwebhookconfiguration -l app.kubernetes.io/instance=kyverno --ignore-not-found 2>/dev/null || true
	-$(MAKE) flux-bootstrap-destroy
	-$(MAKE) k8s-storage-destroy
	-$(MAKE) k8s-security-destroy
	-$(MAKE) k8s-identity-destroy
	-$(MAKE) k8s-monitoring-destroy
	-$(MAKE) k8s-pki-destroy
	-$(MAKE) k8s-cni-destroy
	@pkill -f 'kubectl port-forward' 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════
# Local (libvirt/KVM) — unchanged
# ═══════════════════════════════════════════════════════════════════════

.PHONY: local-init local-plan local-apply local-destroy local-kubeconfig local-up local-down

local-init:
	$(TF) -chdir=$(TF_LOCAL) init

local-plan:
	$(TF) -chdir=$(TF_LOCAL) plan

local-apply: ## terraform apply for local libvirt cluster
	$(TF) -chdir=$(TF_LOCAL) apply -auto-approve

local-destroy:
	$(TF) -chdir=$(TF_LOCAL) destroy -auto-approve

local-kubeconfig:
	@$(TF) -chdir=$(TF_LOCAL) output -raw kubeconfig > $(HOME)/.kube/talos-local

local-up: local-apply local-kubeconfig ## Create local cluster + deploy k8s stacks
	$(MAKE) k8s-up ENV=dev INSTANCE=local REGION=host KC_FILE=$(HOME)/.kube/talos-local

local-down:
	$(MAKE) k8s-down ENV=dev INSTANCE=local REGION=host KC_FILE=$(HOME)/.kube/talos-local
	$(MAKE) local-destroy

# ═══════════════════════════════════════════════════════════════════════
# Scaleway — stage 0: IAM (one-time admin — single project, 9 IAM apps)
# Runs with your admin credentials (secret.tfvars). Local state.
# ═══════════════════════════════════════════════════════════════════════

.PHONY: scaleway-iam-init scaleway-iam-apply scaleway-iam-destroy scaleway-iam-claude-config scaleway-iam-claude-activate

scaleway-iam-init: ## terraform init for Scaleway IAM
	$(call tf_init,$(TF_SCW_IAM),scaleway-iam)

scaleway-iam-apply: scaleway-iam-init ## Create project + 9 IAM apps + API keys + Claude-scoped apps (requires secret.tfvars)
	$(TF) -chdir=$(TF_SCW_IAM) apply -auto-approve -var-file=secret.tfvars

scaleway-iam-claude-config: ## Print the ~/.config/scw/config.yaml snippet (multi-profile: admin + st4ck-readonly + optional st4ck-admin)
	@$(TF) -chdir=$(TF_SCW_IAM) output -raw scw_config_snippet

scaleway-iam-claude-activate: ## Save scw config snippet to ~/.config/scw/config.yaml (backs up existing file first)
	@test -f $(HOME)/.config/scw/config.yaml && cp $(HOME)/.config/scw/config.yaml $(HOME)/.config/scw/config.yaml.bak-$$(date +%s) && echo "Backed up existing config to .bak-$$(date +%s)"
	@mkdir -p $(HOME)/.config/scw
	@$(TF) -chdir=$(TF_SCW_IAM) output -raw scw_config_snippet > $(HOME)/.config/scw/config.yaml
	@echo "Wrote $(HOME)/.config/scw/config.yaml (profile 'st4ck-readonly' active)"
	@echo "Don't forget to edit the admin profile's access_key/secret_key manually."

scaleway-iam-destroy: ## Destroy Scaleway IAM (project + apps)
	$(TF) -chdir=$(TF_SCW_IAM) destroy -auto-approve -var-file=secret.tfvars

# ─── IAM output helpers (consumed by downstream stages) ─────────────────

define scw_iam_out
$$($(TF) -chdir=$(TF_SCW_IAM) output -raw $(1))
endef

SCW_PROJECT_ID      = $(call scw_iam_out,project_id)
SCW_IMG_AK          = $(call scw_iam_out,image_builder_$(ENV)_access_key)
SCW_IMG_SK          = $(call scw_iam_out,image_builder_$(ENV)_secret_key)
SCW_CLUSTER_AK      = $(call scw_iam_out,cluster_$(ENV)_access_key)
SCW_CLUSTER_SK      = $(call scw_iam_out,cluster_$(ENV)_secret_key)
SCW_CI_AK           = $(call scw_iam_out,ci_$(ENV)_access_key)
SCW_CI_SK           = $(call scw_iam_out,ci_$(ENV)_secret_key)

# ═══════════════════════════════════════════════════════════════════════
# Scaleway — stage 1: Image (per region, semver + schematic sha7)
# Two-phase apply (builder VM → wait S3 → snapshot+image).
# ═══════════════════════════════════════════════════════════════════════

.PHONY: scaleway-image-init scaleway-image-build scaleway-image-wait scaleway-image-apply scaleway-image-destroy scaleway-image-clean

# ENV must be set so we pick the right image-builder IAM key.
SCW_IMAGE_VARS = \
	-var="project_id=$(SCW_PROJECT_ID)" \
	-var="scw_access_key=$(SCW_IMG_AK)" \
	-var="scw_secret_key=$(SCW_IMG_SK)" \
	-var="region=$(REGION)"

SCW_IMAGE_ENV = \
	SCW_ACCESS_KEY=$(SCW_IMG_AK) \
	SCW_SECRET_KEY=$(SCW_IMG_SK)

scaleway-image-init: ## terraform init for Scaleway image builder (per-region state)
	$(call tf_init,$(TF_SCW_IMAGE),$(STATE_IMAGE))

scaleway-image-build: scaleway-image-init ## Phase 1: start builder VM
	$(SCW_IMAGE_ENV) $(TF) -chdir=$(TF_SCW_IMAGE) apply -auto-approve \
		-target=scaleway_object_bucket.talos_image \
		-target=scaleway_instance_ip.builder \
		-target=scaleway_instance_server.builder \
		$(SCW_IMAGE_VARS)

scaleway-image-wait: ## Gate: wait for S3 upload (~15 min)
	@BUCKET=$$($(TF) -chdir=$(TF_SCW_IMAGE) output -raw -state=terraform.tfstate 2>/dev/null scaleway_object_bucket.talos_image.name 2>/dev/null || echo "") && \
		[ -n "$$BUCKET" ] || BUCKET=$$($(TF) -chdir=$(TF_SCW_IMAGE) state show scaleway_object_bucket.talos_image 2>/dev/null | grep '^\s*name\s' | sed 's/.*=\s*"\(.*\)"/\1/') && \
		ENDPOINT="https://$$BUCKET.s3.$(REGION).scw.cloud/.upload-complete" && \
		echo "Waiting for image upload (polling $$ENDPOINT)..." && \
		for i in $$(seq 1 60); do \
			STATUS=$$(curl -s -o /dev/null -w "%{http_code}" "$$ENDPOINT" 2>/dev/null || echo "000"); \
			[ "$$STATUS" = "200" ] && echo "Upload complete!" && exit 0; \
			echo "  attempt $$i/60 (HTTP $$STATUS)"; sleep 15; \
		done; echo "ERROR: Timeout" && exit 1

scaleway-image-apply: scaleway-image-build scaleway-image-wait ## Build Talos image in $(REGION) (full two-phase flow)
	$(SCW_IMAGE_ENV) $(TF) -chdir=$(TF_SCW_IMAGE) apply -auto-approve $(SCW_IMAGE_VARS)

scaleway-image-destroy: scaleway-image-init ## Destroy builder VM + bucket (keeps images & snapshots)
	-$(TF) -chdir=$(TF_SCW_IMAGE) state rm scaleway_instance_image.talos 2>/dev/null
	-$(TF) -chdir=$(TF_SCW_IMAGE) state rm scaleway_instance_snapshot.talos 2>/dev/null
	-$(TF) -chdir=$(TF_SCW_IMAGE) state rm scaleway_instance_image.talos_block 2>/dev/null
	-$(TF) -chdir=$(TF_SCW_IMAGE) state rm scaleway_block_snapshot.talos 2>/dev/null
	$(SCW_IMAGE_ENV) $(TF) -chdir=$(TF_SCW_IMAGE) destroy -auto-approve $(SCW_IMAGE_VARS)

scaleway-image-clean: scaleway-image-init ## Destroy ALL image resources (VM + snapshots + images + bucket)
	$(SCW_IMAGE_ENV) $(TF) -chdir=$(TF_SCW_IMAGE) destroy -auto-approve $(SCW_IMAGE_VARS)

# ═══════════════════════════════════════════════════════════════════════
# Scaleway — stage 2: Cluster (per ENV/INSTANCE/REGION)
# ═══════════════════════════════════════════════════════════════════════

.PHONY: scaleway-init scaleway-plan scaleway-apply scaleway-destroy

# Resolve the image name for the current REGION from the image stage outputs.
SCW_IMAGE_NAME = $$($(TF) -chdir=$(TF_SCW_IMAGE) output -raw image_name)

SCW_CLUSTER_VARS = \
	-var="context_file=$(CTX_FILE)" \
	-var="project_id=$(SCW_PROJECT_ID)" \
	-var="talos_image_name=$(SCW_IMAGE_NAME)"

SCW_CLUSTER_ENV = \
	SCW_ACCESS_KEY=$(SCW_CLUSTER_AK) \
	SCW_SECRET_KEY=$(SCW_CLUSTER_SK)

scaleway-init: ## terraform init for cluster (context-scoped state)
	$(call tf_init,$(TF_SCALEWAY),$(STATE_CLUSTER))

scaleway-plan: scaleway-init
	@test -f "$(CTX_FILE)" || { echo "ERROR: $(CTX_FILE) not found"; exit 1; }
	$(SCW_CLUSTER_ENV) $(TF) -chdir=$(TF_SCALEWAY) plan $(SCW_CLUSTER_VARS)

scaleway-apply: scaleway-init ## Create Talos cluster for ENV=$(ENV) INSTANCE=$(INSTANCE) REGION=$(REGION)
	@test -f "$(CTX_FILE)" || { echo "ERROR: $(CTX_FILE) not found"; exit 1; }
	$(SCW_CLUSTER_ENV) $(TF) -chdir=$(TF_SCALEWAY) apply -auto-approve $(SCW_CLUSTER_VARS)

scaleway-destroy: scaleway-init ## Destroy the Talos cluster for the current context
	$(SCW_CLUSTER_ENV) $(TF) -chdir=$(TF_SCALEWAY) destroy -auto-approve $(SCW_CLUSTER_VARS)

# ═══════════════════════════════════════════════════════════════════════
# Scaleway — stage 3: CI VM (Gitea + Woodpecker + platform pod)
# One CI VM per (ENV, INSTANCE, REGION) context.
# For shared dev CI: make scaleway-ci-apply ENV=dev INSTANCE=shared REGION=fr-par
# For prod EU CI:    make scaleway-ci-apply ENV=prod INSTANCE=eu REGION=fr-par
# ═══════════════════════════════════════════════════════════════════════

.PHONY: scaleway-ci-init scaleway-ci-apply scaleway-ci-destroy

SCW_CI_VARS = \
	-var="context_file=$(CTX_FILE)" \
	-var="project_id=$(SCW_PROJECT_ID)" \
	-var="scw_access_key=$(SCW_CI_AK)" \
	-var="scw_secret_key=$(SCW_CI_SK)" \
	-var="scw_image_access_key=$(SCW_IMG_AK)" \
	-var="scw_image_secret_key=$(SCW_IMG_SK)" \
	-var="scw_cluster_access_key=$(SCW_CLUSTER_AK)" \
	-var="scw_cluster_secret_key=$(SCW_CLUSTER_SK)"

scaleway-ci-init: ## terraform init for CI VM (context-scoped state)
	$(call tf_init,$(TF_SCW_CI),$(STATE_CI))

scaleway-ci-apply: scaleway-ci-init ## Deploy CI VM for the current context
	@test -f "$(CTX_FILE)" || { echo "ERROR: $(CTX_FILE) not found"; exit 1; }
	$(TF) -chdir=$(TF_SCW_CI) apply -auto-approve $(SCW_CI_VARS)

scaleway-ci-destroy: scaleway-ci-init
	$(TF) -chdir=$(TF_SCW_CI) destroy -auto-approve $(SCW_CI_VARS)

# ═══════════════════════════════════════════════════════════════════════
# Scaleway — bootstrap helpers (chicken-and-egg: vault-backend lives ON the
# CI VM we're provisioning, so the very first run uses LOCAL state, then
# migrates to vault-backend once the SSH tunnel is up).
# ═══════════════════════════════════════════════════════════════════════

.PHONY: scaleway-bootstrap-vm scaleway-fetch-creds scaleway-tunnel-start scaleway-tunnel-stop scaleway-migrate-state-up

CI_TUNNEL_PIDFILE := /tmp/st4ck-vb-tunnel-$(ENV)-$(INSTANCE)-$(REGION).pid

scaleway-bootstrap-vm: ## ONE-SHOT first-time bootstrap of the CI VM (uses local state, then migrates)
	@echo ">>> [1/4] tofu apply CI VM (local state — vault-backend lives ON this VM)"
	@$(MAKE) scaleway-ci-apply LOCAL_BACKEND=1 ENV=$(ENV) INSTANCE=$(INSTANCE) REGION=$(REGION)
	@echo ">>> [2/4] fetch kms-output from CI VM"
	@$(MAKE) scaleway-fetch-creds ENV=$(ENV) INSTANCE=$(INSTANCE) REGION=$(REGION)
	@echo ">>> [3/4] open SSH tunnel localhost:8080 -> CI VM:8080 (background)"
	@$(MAKE) scaleway-tunnel-start ENV=$(ENV) INSTANCE=$(INSTANCE) REGION=$(REGION)
	@echo ">>> [4/4] migrate IAM + CI state from local to vault-backend"
	@$(MAKE) scaleway-migrate-state-up ENV=$(ENV) INSTANCE=$(INSTANCE) REGION=$(REGION)
	@echo ""
	@echo "================================================================"
	@echo "  CI VM ready. From now on use 'make scaleway-image-apply' etc."
	@echo "  Tunnel PID: $$(cat $(CI_TUNNEL_PIDFILE) 2>/dev/null || echo '?')"
	@echo "  Stop tunnel: make scaleway-tunnel-stop"
	@echo "================================================================"

# Common SSH opts for ephemeral VMs: clean stale known_hosts entries + skip
# strict checking. Scaleway re-allocates IPs across destroy/create cycles, so
# the host key under the same IP changes — without -R, ssh blocks the
# connection for safety even with StrictHostKeyChecking=no.
SSH_OPTS = -i ~/.ssh/talos_scaleway -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR

scaleway-fetch-creds: ## scp kms-output/ from the CI VM to local
	@CI_IP=$$($(TF) -chdir=$(TF_SCW_CI) output -raw ci_ip); \
	ssh-keygen -R "$$CI_IP" >/dev/null 2>&1 || true; \
	mkdir -p $(KMS_OUTPUT) && \
	scp $(SSH_OPTS) "root@$$CI_IP:/opt/talos/kms-output/*" $(KMS_OUTPUT)/ && \
	echo "[fetch-creds] $$(ls $(KMS_OUTPUT) | wc -l) files copied to $(KMS_OUTPUT)/"

scaleway-tunnel-start: ## Open background SSH tunnel local:8080 (vault-backend) + :2222 (Gitea SSH) -> CI VM
	@if [ -f $(CI_TUNNEL_PIDFILE) ] && kill -0 $$(cat $(CI_TUNNEL_PIDFILE)) 2>/dev/null; then \
		echo "[tunnel] already running (pid $$(cat $(CI_TUNNEL_PIDFILE)))"; \
	else \
		CI_IP=$$($(TF) -chdir=$(TF_SCW_CI) output -raw ci_ip); \
		ssh-keygen -R "$$CI_IP" >/dev/null 2>&1 || true; \
		ssh $(SSH_OPTS) -L 8080:localhost:8080 -L 2222:localhost:2222 -N -f "root@$$CI_IP" && \
		pgrep -f "ssh.*$$CI_IP.*-L 8080" | head -1 > $(CI_TUNNEL_PIDFILE) && \
		echo "[tunnel] up (pid $$(cat $(CI_TUNNEL_PIDFILE)))"; \
	fi

scaleway-tunnel-stop: ## Kill the background SSH tunnel
	@if [ -f $(CI_TUNNEL_PIDFILE) ]; then \
		kill $$(cat $(CI_TUNNEL_PIDFILE)) 2>/dev/null && echo "[tunnel] killed"; \
		rm -f $(CI_TUNNEL_PIDFILE); \
	else echo "[tunnel] not running"; fi

scaleway-migrate-state-up: ## Migrate IAM + CI states from local files to vault-backend
	@echo "[migrate-up] IAM (local -> vault-backend)"
	@rm -f $(TF_SCW_IAM)/_local_backend_override.tf
	@$(TF) -chdir=$(TF_SCW_IAM) init -migrate-state -force-copy -input=false \
	  -backend-config="address=$(VB_URL)/state/scaleway-iam" \
	  -backend-config="lock_address=$(VB_URL)/state/scaleway-iam" \
	  -backend-config="unlock_address=$(VB_URL)/state/scaleway-iam"
	@echo "[migrate-up] CI (local -> vault-backend)"
	@rm -f $(TF_SCW_CI)/_local_backend_override.tf
	@$(TF) -chdir=$(TF_SCW_CI) init -migrate-state -force-copy -input=false \
	  -backend-config="address=$(VB_URL)/state/$(STATE_CI)" \
	  -backend-config="lock_address=$(VB_URL)/state/$(STATE_CI)" \
	  -backend-config="unlock_address=$(VB_URL)/state/$(STATE_CI)"

scaleway-migrate-state-down: ## Migrate IAM + CI states from vault-backend BACK to local (before destroy)
	@echo "[migrate-down] IAM (vault-backend -> local)"
	@printf '%s\n' "$$_local_backend_override" > $(TF_SCW_IAM)/_local_backend_override.tf
	@$(TF) -chdir=$(TF_SCW_IAM) init -migrate-state -force-copy -input=false
	@echo "[migrate-down] CI (vault-backend -> local)"
	@printf '%s\n' "$$_local_backend_override" > $(TF_SCW_CI)/_local_backend_override.tf
	@$(TF) -chdir=$(TF_SCW_CI) init -migrate-state -force-copy -input=false

# ═══════════════════════════════════════════════════════════════════════
# Safe teardown of the CI VM
# Order matters: migrate state OFF the VM first, THEN destroy. Otherwise
# vault-backend (which lives on the VM) dies mid-destroy and leaves the
# state lock orphaned + the state file unreachable.
# ═══════════════════════════════════════════════════════════════════════

.PHONY: scaleway-teardown-vm

scaleway-teardown-vm: ## Safely destroy the CI VM (migrates state to local first to avoid lock orphan)
	@echo ">>> [1/3] migrate state from vault-backend to local"
	@$(MAKE) scaleway-migrate-state-down ENV=$(ENV) INSTANCE=$(INSTANCE) REGION=$(REGION)
	@echo ">>> [2/3] stop SSH tunnel"
	@$(MAKE) scaleway-tunnel-stop ENV=$(ENV) INSTANCE=$(INSTANCE) REGION=$(REGION)
	@echo ">>> [3/3] destroy CI VM (now safe — state is local)"
	@$(MAKE) scaleway-ci-destroy LOCAL_BACKEND=1 ENV=$(ENV) INSTANCE=$(INSTANCE) REGION=$(REGION)
	@echo ""
	@echo "================================================================"
	@echo "  CI VM destroyed. IAM state preserved locally."
	@echo "  Run 'make scaleway-bootstrap-vm' to recreate."
	@echo "================================================================"

# ═══════════════════════════════════════════════════════════════════════
# Composite targets
# ═══════════════════════════════════════════════════════════════════════

.PHONY: scaleway-up scaleway-down scaleway-teardown scaleway-nuke scaleway-wait scaleway-kubeconfig

scaleway-up: scaleway-apply scaleway-wait scaleway-kubeconfig k8s-up ## Create cluster + all k8s stacks for the current context

scaleway-wait: ## Wait for K8s API server of the current context to be reachable
	@echo "Waiting for API server ($(CTX_ID))..."
	@for i in $$(seq 1 30); do \
		$(TF) -chdir=$(TF_SCALEWAY) output -raw kubeconfig 2>/dev/null \
			| kubectl --kubeconfig /dev/stdin get nodes >/dev/null 2>&1 && break; \
		echo "  attempt $$i/30..."; sleep 10; \
	done
	@echo "API server ready."

scaleway-kubeconfig: ## Export kubeconfig to $(KC_FILE)
	@mkdir -p $(dir $(KC_FILE))
	@$(TF) -chdir=$(TF_SCALEWAY) output -raw kubeconfig > $(KC_FILE)
	@echo "export KUBECONFIG=$(KC_FILE)"

scaleway-down: k8s-down scaleway-destroy ## Destroy k8s stacks + cluster for the current context

scaleway-teardown: scaleway-down scaleway-ci-destroy ## Destroy cluster + CI for the current context (keeps IAM + image)

scaleway-nuke: ## DANGEROUS: destroy EVERYTHING — all clusters, CIs, images, IAM
	@echo "================================================================"
	@echo "DANGER: scaleway-nuke will destroy ALL Scaleway resources"
	@echo "        for namespace '$(NAMESPACE)' (every env/instance/region)."
	@echo "        Current kube context: $$(kubectl config current-context 2>/dev/null || echo 'none')"
	@echo "        Make sure no other engineer has active work on this project."
	@echo "================================================================"
	@if [ "$$CONFIRM" = "yes-destroy-everything" ]; then \
		echo "Non-interactive confirmation via CONFIRM env var."; \
	else \
		read -p "Type 'yes-destroy-everything' to confirm: " confirm && [ "$$confirm" = "yes-destroy-everything" ] || (echo "Aborted."; exit 1); \
	fi
	-$(MAKE) scaleway-down
	-$(MAKE) scaleway-ci-destroy
	-$(MAKE) scaleway-image-clean
	-$(MAKE) scaleway-iam-destroy

# ═══════════════════════════════════════════════════════════════════════
# Bootstrap (podman platform pod — OpenBao KMS + Gitea + Woodpecker)
# Single pod: OpenBao 3-node Raft + vault-backend + Gitea + Woodpecker.
# Must run BEFORE any tofu command that uses the http backend.
# ═══════════════════════════════════════════════════════════════════════

.PHONY: vault-backend-build bootstrap bootstrap-init bootstrap-stop bootstrap-update bootstrap-export bootstrap-export-remote bootstrap-tunnel kms-bootstrap kms-stop state-snapshot state-restore

kms-bootstrap: bootstrap
kms-stop: bootstrap-stop

VAULT_BACKEND_COMMIT := 224c7a17a943ba3d3d5b137a78b915f1ea8c79ff
TF_BOOTSTRAP   := bootstrap
BOOTSTRAP_DIR  ?= /tmp/platform-local

vault-backend-build: ## Build vault-backend from source (podman)
	podman build -t localhost/vault-backend:$(VAULT_BACKEND_COMMIT) \
		--build-arg VAULT_BACKEND_COMMIT=$(VAULT_BACKEND_COMMIT) \
		bootstrap/vault-backend/
	podman tag localhost/vault-backend:$(VAULT_BACKEND_COMMIT) localhost/vault-backend:latest
	@echo "Built localhost/vault-backend:$(VAULT_BACKEND_COMMIT)"

# Pin a concrete commit SHA before any prod deploy.
VAULT_KMS_PLUGIN_COMMIT ?= main

vault-kms-plugin-build: ## Build vault-kms-plugin (OpenBao Transit KMS for kube-apiserver) from source
	podman build -t localhost/vault-kms-plugin:$(VAULT_KMS_PLUGIN_COMMIT) \
		--build-arg VAULT_KMS_PLUGIN_COMMIT=$(VAULT_KMS_PLUGIN_COMMIT) \
		bootstrap/vault-kms-plugin/
	podman tag localhost/vault-kms-plugin:$(VAULT_KMS_PLUGIN_COMMIT) localhost/vault-kms-plugin:latest
	@echo "Built localhost/vault-kms-plugin:$(VAULT_KMS_PLUGIN_COMMIT)"

bootstrap-init:
	$(TF) -chdir=$(TF_BOOTSTRAP) init

bootstrap: bootstrap-init ## Start the platform pod locally (podman)
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

bootstrap-export-remote: ## Copy tokens from remote CI VM via SSH (set VB_HOST=user@ip or use SSH config)
	@test "$(VB_HOST)" != "localhost" || { echo "Set VB_HOST=<ip> first"; exit 1; }
	@mkdir -p $(KMS_OUTPUT)
	scp $(VB_HOST):/opt/talos/kms-output/* $(KMS_OUTPUT)/
	@echo "Exported from $(VB_HOST) to $(KMS_OUTPUT)/"

bootstrap-tunnel: ## SSH tunnel to remote bootstrap (forwards :8080 + :8200 to localhost)
	@test "$(VB_HOST)" != "localhost" || { echo "Set VB_HOST=<ip> first"; exit 1; }
	@echo "Tunneling to $(VB_HOST) — ports 8080 (state) + 8200 (OpenBao)"
	ssh -N -L 8080:localhost:8080 -L 8200:localhost:8200 $(VB_HOST)

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

# ─── Disaster Recovery ──────────────────────────────────────────────────

.PHONY: dr-backup dr-backup-kms dr-backup-cnpg dr-verify-backup

DR_BACKUP_DIR ?= $(HOME)/talos-dr-backups

dr-backup-kms:
	@BACKUP_DIR=$(DR_BACKUP_DIR)/$$(date +%Y%m%d-%H%M%S) && \
		mkdir -p $$BACKUP_DIR && \
		cp -r $(KMS_OUTPUT) $$BACKUP_DIR/kms-output && \
		ROOT_TOKEN=$$(cat $(KMS_OUTPUT)/root-token.txt) && \
		curl -sf -H "X-Vault-Token: $$ROOT_TOKEN" \
			http://127.0.0.1:8200/v1/sys/storage/raft/snapshot \
			-o $$BACKUP_DIR/raft.snap && \
		echo "DR backup saved to $$BACKUP_DIR/"

dr-backup-cnpg:
	@KUBECONFIG=$(KC_FILE) kubectl -n identity apply -f - <<< '{"apiVersion":"postgresql.cnpg.io/v1","kind":"Backup","metadata":{"name":"identity-pg-manual-'"$$(date +%s)"'","namespace":"identity"},"spec":{"method":"barmanObjectStore","cluster":{"name":"identity-pg"}}}' && \
		echo "Manual CNPG backup triggered."

dr-backup: dr-backup-kms
	@if KUBECONFIG=$(KC_FILE) kubectl get namespace identity >/dev/null 2>&1; then \
		$(MAKE) dr-backup-cnpg; \
	else echo "Cluster not reachable, skipping CNPG backup."; fi

dr-verify-backup:
	@test -d "$(DR_BACKUP_DIR)" || { echo "No backups found at $(DR_BACKUP_DIR)"; exit 1; }
	@LATEST=$$(ls -td $(DR_BACKUP_DIR)/*/ 2>/dev/null | head -1) && \
		test -n "$$LATEST" || { echo "No backup directories found"; exit 1; } && \
		echo "Latest backup: $$LATEST" && \
		FAIL=0 && \
		for f in raft.snap kms-output/root-token.txt kms-output/approle-role-id.txt kms-output/root-ca.pem kms-output/infra-ca.pem; do \
			printf "  %-45s" "$$f:"; \
			if [ -f "$$LATEST/$$f" ]; then echo "OK"; else echo "MISSING"; FAIL=1; fi; \
		done; \
		[ $$FAIL -eq 0 ] || exit 1

# ═══════════════════════════════════════════════════════════════════════
# Upgrade workflow
# ═══════════════════════════════════════════════════════════════════════

.PHONY: preflight upgrade bootstrap-update

preflight: ## Pre-upgrade checks (variables, files, connectivity, validate)
	@FAIL=0; \
	printf "  %-45s" "kms-output/approle-role-id.txt:"; \
	if [ -f "$(KMS_OUTPUT)/approle-role-id.txt" ]; then echo "OK"; else echo "FAIL"; FAIL=1; fi; \
	printf "  %-45s" "vault-backend reachable ($(VB_URL)):"; \
	if curl -so /dev/null -w '%{http_code}' $(VB_URL)/state/test 2>/dev/null | grep -qE '^(2|4)'; then echo "OK"; else echo "FAIL"; FAIL=1; fi; \
	printf "  %-45s" "context file $(CTX_FILE):"; \
	if [ -f "$(CTX_FILE)" ]; then echo "OK"; else echo "FAIL"; FAIL=1; fi; \
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
	else echo "=== PREFLIGHT FAILED ==="; exit 1; fi

upgrade: preflight ## Full upgrade: preflight → snapshot → bootstrap-update → provider → k8s
	@echo "========================================="
	@echo "  Upgrade — ENV=$(ENV) INSTANCE=$(INSTANCE) REGION=$(REGION)"
	@echo "========================================="
	$(MAKE) state-snapshot
	@if git diff HEAD~1 --name-only 2>/dev/null | grep -q '^bootstrap/'; then \
		echo "--- bootstrap/ changed — updating platform pod ---"; \
		$(MAKE) bootstrap-update; \
	fi
	$(MAKE) scaleway-apply
	$(MAKE) k8s-up

bootstrap-update:
	@command -v podman >/dev/null 2>&1 || { echo "Error: podman required"; exit 1; }
	@test -f "$(BOOTSTRAP_DIR)/platform-pod.yaml" || { echo "Error: $(BOOTSTRAP_DIR)/platform-pod.yaml not found. Run make bootstrap first."; exit 1; }
	podman play kube --replace $(BOOTSTRAP_DIR)/platform-pod.yaml \
		--configmap=$(BOOTSTRAP_DIR)/configmap.yaml

# ═══════════════════════════════════════════════════════════════════════
# Arbor — unchanged (pre-stage images, charts, git)
# ═══════════════════════════════════════════════════════════════════════

ARBOR_DIR := arbor

.PHONY: arbor arbor-verify

arbor: vault-backend-build ## Pre-stage images, Helm charts, and git repo for deployment
	@echo "=== Arbor: staging deployment artifacts ==="
	@mkdir -p $(ARBOR_DIR)/charts
	@echo "--- Pulling container images from platform-pod.yaml ---"
	@grep -E '^\s+image:' bootstrap/platform-pod.yaml \
		| sed 's/.*image:\s*//' | sort -u | while read -r img; do \
		echo "  podman pull $$img"; podman pull "$$img"; \
	done
	@echo "--- Pulling Helm charts from stacks ---"
	@for dir in stacks/*/; do \
		main="$$dir/main.tf"; vars="$$dir/variables.tf"; [ -f "$$main" ] || continue; \
		grep -E 'repository\s*=' "$$main" | sed 's/.*=\s*"\(.*\)"/\1/' | while read -r repo; do \
			chart=$$(grep -A1 "repository.*$$repo" "$$main" | grep 'chart\s*=' | head -1 | sed 's/.*=\s*"\(.*\)"/\1/'); \
			[ -z "$$chart" ] && continue; \
			echo "$$chart" | grep -q '/' && continue; \
			version=$$(grep -B5 "chart.*$$chart" "$$main" | grep 'version\s*=' | head -1 | sed 's/.*=\s*"\{0,1\}\(var\.\)\{0,1\}//;s/"\{0,1\}\s*$$//'); \
			if echo "$$version" | grep -q '^var\.'; then \
				varname=$$(echo "$$version" | sed 's/var\.//'); \
				version=$$(grep -A3 "variable.*$$varname" "$$vars" | grep 'default' | sed 's/.*=\s*"\(.*\)"/\1/'); \
			fi; \
			[ -z "$$version" ] && continue; \
			echo "  helm pull $$chart ($$version) from $$repo"; \
			helm pull "$$chart" --repo "$$repo" --version "$$version" -d $(ARBOR_DIR)/charts 2>/dev/null \
				|| echo "    WARN: failed to pull $$chart $$version"; \
		done; \
	done
	@echo "--- Generating manifest ---"
	@{ echo '{'; echo '  "generated": "'$$(date -u +%Y-%m-%dT%H:%M:%SZ)'",'; \
		echo '  "images": ['; \
		grep -E '^\s+image:' bootstrap/platform-pod.yaml | sed 's/.*image:\s*//' | sort -u | while read -r img; do \
			digest=$$(podman image inspect "$$img" --format '{{index .Digest}}' 2>/dev/null || echo "unknown"); \
			echo "    {\"image\": \"$$img\", \"sha256\": \"$$digest\"},"; \
		done; echo '    null'; echo '  ],'; \
		echo '  "charts": ['; \
		for f in $(ARBOR_DIR)/charts/*.tgz; do [ -f "$$f" ] || continue; \
			sha=$$(shasum -a 256 "$$f" | cut -d' ' -f1); \
			echo "    {\"file\": \"$$(basename $$f)\", \"sha256\": \"$$sha\"},"; \
		done; echo '    null'; echo '  ]'; echo '}'; \
	} > $(ARBOR_DIR)/manifest.json
	@echo "=== Arbor staging complete ==="

arbor-verify:
	@FAIL=0; \
	grep -E '^\s+image:' bootstrap/platform-pod.yaml | sed 's/.*image:\s*//' | sort -u | while read -r img; do \
		printf "  %-60s" "$$img:"; \
		if podman image exists "$$img" 2>/dev/null; then echo "OK"; else echo "MISSING"; FAIL=1; fi; \
	done; \
	test -f "$(ARBOR_DIR)/manifest.json" || { echo "FAIL: $(ARBOR_DIR)/manifest.json not found"; exit 1; }; \
	for f in $(ARBOR_DIR)/charts/*.tgz; do [ -f "$$f" ] || continue; \
		sha_actual=$$(shasum -a 256 "$$f" | cut -d' ' -f1); \
		sha_expected=$$(grep "$$(basename $$f)" $(ARBOR_DIR)/manifest.json | sed 's/.*sha256.*: *"\([a-f0-9]*\)".*/\1/' | head -1); \
		printf "  %-60s" "$$(basename $$f):"; \
		if [ "$$sha_actual" = "$$sha_expected" ]; then echo "OK"; else echo "SHA256 MISMATCH"; FAIL=1; fi; \
	done; \
	[ $$FAIL -eq 0 ]

# ═══════════════════════════════════════════════════════════════════════
# VMware airgap (scripts, not Terraform)
# ═══════════════════════════════════════════════════════════════════════

.PHONY: vmware-image-cache vmware-build-ova vmware-gen-configs vmware-bootstrap

vmware-image-cache:
	@$(MAKE) -C $(VMWARE) image-cache

vmware-build-ova:
	@$(MAKE) -C $(VMWARE) build-ova

vmware-gen-configs:
	@$(MAKE) -C $(VMWARE) gen-configs

vmware-bootstrap:
	@$(MAKE) -C $(VMWARE) bootstrap

# ═══════════════════════════════════════════════════════════════════════
# Validation / tests
# ═══════════════════════════════════════════════════════════════════════

STACKS := envs/scaleway/iam envs/scaleway/image envs/scaleway envs/scaleway/ci \
	stacks/cni stacks/monitoring stacks/pki \
	stacks/identity stacks/security stacks/storage \
	stacks/flux-bootstrap stacks/external-secrets \
	stacks/capi stacks/kamaji stacks/autoscaling stacks/gateway-api \
	stacks/managed-cluster \
	modules/naming modules/context

# .tftest.hcl-tested dirs (pass1 #7 / pass2 #10). Mirrors the test-tftest
# step in .woodpecker.yml so local parity matches CI.
SCW_TEST_DIRS := envs/scaleway/iam envs/scaleway/image envs/scaleway/ci envs/scaleway

.PHONY: validate test clean scaleway-test

validate: ## Validate every Terraform stack (no apply)
	@FAIL=0; for dir in $(STACKS); do \
		if [ ! -d "$$dir" ]; then \
			printf "  %-45s" "$$dir:"; echo "SKIP (no dir)"; continue; \
		fi; \
		printf "  %-45s" "$$dir:"; \
		rm -rf "$$dir/.terraform" "$$dir/.terraform.lock.hcl"; \
		if $(TF) -chdir="$$dir" init -backend=false -input=false >/dev/null 2>&1 \
			&& $(TF) -chdir="$$dir" validate >/dev/null 2>&1; then \
			echo "OK"; \
		else echo "FAIL"; FAIL=1; fi; \
	done; [ $$FAIL -eq 0 ]

scaleway-test: ## Run `tofu test` in every envs/scaleway dir that ships .tftest.hcl files
	@FAIL=0; for dir in $(SCW_TEST_DIRS); do \
		if [ ! -d "$$dir/tests" ] || ! ls "$$dir"/tests/*.tftest.hcl >/dev/null 2>&1; then \
			printf "  %-45s" "$$dir:"; echo "SKIP (no .tftest.hcl)"; continue; \
		fi; \
		printf "  %-45s" "$$dir:"; \
		rm -rf "$$dir/.terraform" "$$dir/.terraform.lock.hcl"; \
		if $(TF) -chdir="$$dir" init -backend=false -input=false >/dev/null 2>&1 \
			&& $(TF) -chdir="$$dir" test >/dev/null 2>&1; then \
			echo "OK"; \
		else echo "FAIL"; FAIL=1; fi; \
	done; [ $$FAIL -eq 0 ]

velero-test: ## Run Velero backup/restore e2e test (Chainsaw)
	@command -v chainsaw >/dev/null 2>&1 || { echo "Error: chainsaw required"; exit 1; }
	KUBECONFIG=$(KC_FILE) chainsaw test tests/velero/

test: validate scaleway-test ## Run validation + tofu test + e2e tests

clean: ## Remove all build artifacts
	rm -rf $(OUT_DIR)
	rm -rf $(VMWARE)/_out $(VMWARE)/image-cache.oci

# ═══════════════════════════════════════════════════════════════════════
# UI Access
# ═══════════════════════════════════════════════════════════════════════

.PHONY: scaleway-headlamp scaleway-grafana scaleway-harbor

scaleway-headlamp: scaleway-kubeconfig ## Open Headlamp UI (token to clipboard)
	@KUBECONFIG=$(KC_FILE) kubectl create serviceaccount headlamp-admin -n kube-system 2>/dev/null || true
	@KUBECONFIG=$(KC_FILE) kubectl create clusterrolebinding headlamp-admin-token --clusterrole=cluster-admin --serviceaccount=kube-system:headlamp-admin 2>/dev/null || true
	@TOKEN=$$(KUBECONFIG=$(KC_FILE) kubectl create token headlamp-admin -n kube-system --duration=48h) && \
		echo "$$TOKEN" | pbcopy && \
		KUBECONFIG=$(KC_FILE) kubectl port-forward -n monitoring svc/headlamp 4466:80 >/dev/null 2>&1 & \
		sleep 2 && open http://localhost:4466

scaleway-harbor: scaleway-kubeconfig
	@PASSWORD=$$($(TF) -chdir=$(TF_STORAGE) output -raw harbor_admin_password) && \
		echo "$$PASSWORD" | pbcopy && \
		KUBECONFIG=$(KC_FILE) kubectl port-forward -n storage svc/harbor 8080:80 >/dev/null 2>&1 & \
		sleep 2 && open http://localhost:8080

scaleway-grafana: scaleway-kubeconfig
	@KUBECONFIG=$(KC_FILE) kubectl port-forward -n monitoring svc/grafana 3000:80 >/dev/null 2>&1 & \
		sleep 2 && open http://localhost:3000

# ═══════════════════════════════════════════════════════════════════════
# Brigade — multi-agent sprint launcher
# (cli-forge-chef pattern: Chef + 3 voting Sous-Chefs + Sous-Chef Merge +
#  Maître d'hôtel + ccheck + contre-chef-inter + N commis)
# ═══════════════════════════════════════════════════════════════════════

.PHONY: brigade-tier3-pass1 brigade-tier3-pass1-preflight brigade-tier3-pass1-stop

BRIGADE_SESSION := tier3-pass1
BRIGADE_PROMPTS := .claude/prompts
BRIGADE_TMUXINATOR := $(HOME)/.config/tmuxinator/$(BRIGADE_SESSION).yml

brigade-tier3-pass1-preflight: ## Verify all brigade artefacts before launch
	@echo "=== brigade-$(BRIGADE_SESSION) preflight ==="
	@RC=0; \
	for tool in tmux tmuxinator claude gh git; do \
	  if command -v $$tool >/dev/null 2>&1; then \
	    printf "  %-15s OK (%s)\n" "$$tool" "$$(command -v $$tool)"; \
	  else \
	    printf "  %-15s MISSING\n" "$$tool"; RC=1; \
	  fi; \
	done; \
	for f in $(BRIGADE_TMUXINATOR) \
	         $(BRIGADE_PROMPTS)/chef-$(BRIGADE_SESSION).md \
	         $(BRIGADE_PROMPTS)/ccheck-$(BRIGADE_SESSION).md \
	         $(BRIGADE_PROMPTS)/contre-chef-inter-$(BRIGADE_SESSION).md \
	         .claude/shared-state.md \
	         docs/reviews/2026-04-22-cycle-pass1.md; do \
	  if [ -f $$f ]; then \
	    printf "  %-15s OK (%s)\n" "file" "$$f"; \
	  else \
	    printf "  %-15s MISSING (%s)\n" "file" "$$f"; RC=1; \
	  fi; \
	done; \
	echo "  gh auth check..."; \
	if gh auth status >/dev/null 2>&1; then echo "    gh authenticated OK"; else echo "    gh NOT authenticated"; RC=1; fi; \
	if grep -q '"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"' $(HOME)/.claude/settings.json 2>/dev/null; then \
	  echo "    Agent Teams enabled OK"; \
	else \
	  echo "    Agent Teams NOT enabled — set CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 in ~/.claude/settings.json"; RC=1; \
	fi; \
	if [ $$RC -eq 0 ]; then echo "=== preflight PASS ==="; else echo "=== preflight FAIL — fix above before launching ==="; exit 1; fi

brigade-tier3-pass1: brigade-tier3-pass1-preflight ## Launch the tier3-pass1 brigade (Chef + Sous-Chefs + commis)
	@echo "=== launching brigade $(BRIGADE_SESSION) ==="
	@echo "  Watch the chef pane:    tmux attach -t $(BRIGADE_SESSION)"
	@echo "  Live ccheck log:        tail -f /tmp/$(BRIGADE_SESSION)-ccheck.log"
	@echo "  Live inter log:         tail -f /tmp/$(BRIGADE_SESSION)-inter.log"
	@echo "  Stop brigade:           make brigade-$(BRIGADE_SESSION)-stop"
	@echo
	tmuxinator start $(BRIGADE_SESSION)

brigade-tier3-pass1-stop: ## Stop the tier3-pass1 brigade (preserves worktrees)
	tmuxinator stop $(BRIGADE_SESSION) 2>/dev/null || tmux kill-session -t $(BRIGADE_SESSION) 2>/dev/null || true
	@echo "Brigade stopped. Worktrees preserved at ../st4ck-wt-{bootstrap,scaleway,k8s-day1,docs}."
	@echo "Manual cleanup if sprint fully done:"
	@echo "  for w in bootstrap scaleway k8s-day1 docs; do git worktree remove ../st4ck-wt-\$$w; done"

# ─── tier3-em-smoke (supersedes tier3-pass1) ─────────────────────────
# Phase A Tier 3 (12 fixes) + Phase B EM smoke (4 plats).
# Adds: apply pane (tofu apply for EM smoke after 3/3 quorum + PATRON ACK),
#       commis-em (cluster-3 elastic-metal + matchbox sidecar),
#       wrapper bin/tofu-apply-with-quorum.sh (created by commis-bootstrap as P3-bis).

.PHONY: brigade-tier3-em-smoke brigade-tier3-em-smoke-preflight brigade-tier3-em-smoke-stop brigade-tier3-em-smoke-cleanup

EM_SESSION := tier3-em-smoke
EM_TMUXINATOR := $(HOME)/.config/tmuxinator/$(EM_SESSION).yml

brigade-tier3-em-smoke-preflight: ## Verify all tier3-em-smoke artefacts before launch
	@echo "=== brigade-$(EM_SESSION) preflight ==="
	@PATH="$(HOME)/.local/bin:$$PATH"; export PATH; \
	RC=0; \
	for tool in tmux tmuxinator claude gh git scw jq talosctl; do \
	  if command -v $$tool >/dev/null 2>&1; then \
	    printf "  %-15s OK (%s)\n" "$$tool" "$$(command -v $$tool)"; \
	  else \
	    printf "  %-15s MISSING\n" "$$tool"; \
	    case "$$tool" in talosctl|jq) printf "                    (warning — needed for P15 EM smoke; install before P15)\n";; *) RC=1;; esac; \
	  fi; \
	done; \
	for f in $(EM_TMUXINATOR) \
	         .claude/prompts/chef-$(EM_SESSION).md \
	         .claude/prompts/ccheck-$(EM_SESSION).md \
	         .claude/prompts/contre-chef-inter-$(EM_SESSION).md \
	         .claude/shared-state.md \
	         .claude/permissions-brigade/gate/settings.local.json \
	         .claude/permissions-brigade/maitre/settings.local.json \
	         .claude/permissions-brigade/apply/settings.local.json \
	         .claude/permissions-brigade/vote-scope/settings.local.json \
	         .claude/permissions-brigade/vote-secu/settings.local.json \
	         .claude/permissions-brigade/vote-qualite/settings.local.json \
	         .claude/permissions-brigade/commis-bootstrap/settings.local.json \
	         .claude/permissions-brigade/commis-scaleway/settings.local.json \
	         .claude/permissions-brigade/commis-k8s-day1/settings.local.json \
	         .claude/permissions-brigade/commis-docs/settings.local.json \
	         .claude/permissions-brigade/commis-em/settings.local.json \
	         docs/reviews/2026-04-22-cycle-pass1.md \
	         docs/reviews/2026-04-21-cycle-pass2.md \
	         modules/em-talos-bootstrap/main.tf; do \
	  if [ -f $$f ]; then \
	    printf "  %-15s OK (%s)\n" "file" "$$f"; \
	  else \
	    printf "  %-15s MISSING (%s)\n" "file" "$$f"; RC=1; \
	  fi; \
	done; \
	echo "  scw profiles check..."; \
	if scw -p st4ck-readonly config get access-key >/dev/null 2>&1; then \
	  echo "    st4ck-readonly profile OK"; \
	else \
	  echo "    st4ck-readonly profile MISSING — run 'make scaleway-iam-claude-activate' first"; RC=1; \
	fi; \
	if scw -p st4ck-admin config get access-key >/dev/null 2>&1; then \
	  echo "    st4ck-admin profile OK (apply pane will use this for P15)"; \
	else \
	  echo "    st4ck-admin profile MISSING — required for P15. Run 'make scaleway-iam-claude-config' to view the snippet."; RC=1; \
	fi; \
	echo "  bare-metal IAM keys in OpenBao..."; \
	if curl -sS -m 2 http://localhost:8080/state/scaleway >/dev/null 2>&1; then \
	  echo "    vault-backend reachable"; \
	else \
	  echo "    vault-backend not reachable on :8080 (warning — may not block this sprint as code-only Tier 3 plats don't need it; P15 will fail if down)"; \
	fi; \
	echo "  gh auth check..."; \
	if gh auth status >/dev/null 2>&1; then echo "    gh authenticated OK"; else echo "    gh NOT authenticated"; RC=1; fi; \
	if grep -q '"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"' $(HOME)/.claude/settings.json 2>/dev/null; then \
	  echo "    Agent Teams enabled OK"; \
	else \
	  echo "    Agent Teams NOT enabled — set CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 in ~/.claude/settings.json"; RC=1; \
	fi; \
	echo "  branch protection check..."; \
	if gh api repos/Destynova2/st4ck/rulesets 2>/dev/null | grep -q 'pull_request'; then \
	  echo "    main is protected (PR mode confirmed)"; \
	else \
	  echo "    main NOT protected — sprint expects PR mode, verify configuration"; \
	fi; \
	if [ $$RC -eq 0 ]; then echo "=== preflight PASS ==="; else echo "=== preflight FAIL — fix above before launching ==="; exit 1; fi

brigade-tier3-em-smoke: brigade-tier3-em-smoke-preflight ## Launch the tier3-em-smoke brigade (Phase A Tier 3 + Phase B EM smoke)
	@echo "=== launching brigade $(EM_SESSION) ==="
	@echo "  Watch the chef pane:    tmux attach -t $(EM_SESSION)"
	@echo "  Live ccheck log:        tail -f /tmp/$(EM_SESSION)-ccheck.log"
	@echo "  Live inter log:         tail -f /tmp/$(EM_SESSION)-inter.log"
	@echo "  Apply plans audit:      ls -la .claude/plans/"
	@echo "  Stop brigade:           make brigade-$(EM_SESSION)-stop"
	@echo "  Cleanup worktrees:      make brigade-$(EM_SESSION)-cleanup"
	@echo
	@echo "  IMPORTANT: cost cap €1, EM server MUST be destroyed within 2h of P15 apply success."
	@echo "  IMPORTANT: Chef + commis run on st4ck-readonly. Apply pane switches to st4ck-admin only inside bin/tofu-apply-with-quorum.sh."
	@echo
	tmuxinator start $(EM_SESSION)

brigade-tier3-em-smoke-stop: ## Stop the tier3-em-smoke brigade (preserves worktrees)
	tmuxinator stop $(EM_SESSION) 2>/dev/null || tmux kill-session -t $(EM_SESSION) 2>/dev/null || true
	@echo "Brigade stopped. Worktrees preserved at ../st4ck-wt-{gate,maitre,apply,vote-*,commis-*}."
	@echo "  Inspect with: git worktree list"
	@echo "  Full cleanup: make brigade-$(EM_SESSION)-cleanup"
	@echo
	@echo "  SAFETY: if P15 apply succeeded but destroy did NOT, manually verify:"
	@echo "    scw -p st4ck-readonly baremetal server list -o json | jq '.[] | select(.tags | contains([\"sprint=tier3-em-smoke\"]))'"
	@echo "    If output is non-empty, the EM server is still billing — destroy via:"
	@echo "      scw -p st4ck-admin baremetal server delete <server-id> zone=fr-par-2"

brigade-tier3-em-smoke-cleanup: ## Remove all worktrees + branches for tier3-em-smoke (post-shutdown)
	@for w in gate maitre apply vote-scope vote-secu vote-qualite commis-bootstrap commis-scaleway commis-k8s-day1 commis-docs commis-em; do \
	  echo "  removing ../st4ck-wt-$$w"; \
	  git worktree remove ../st4ck-wt-$$w --force 2>/dev/null || true; \
	done
	@for b in wt/gate wt/maitre wt/apply wt/vote-scope wt/vote-secu wt/vote-qualite; do \
	  echo "  deleting branch $$b"; \
	  git branch -D $$b 2>/dev/null || true; \
	done
	@echo "Cleanup complete. The chore/phase-a-tier3-em-smoke branch is preserved (it has the sprint commits)."
