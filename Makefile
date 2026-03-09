include vars.mk

TF          := tofu
TF_LOCAL    := terraform/envs/local
TF_OUTSCALE := terraform/envs/outscale
TF_SCALEWAY := terraform/envs/scaleway
VMWARE      := envs/vmware-airgap

.PHONY: help

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ─── Local (libvirt/KVM) ───────────────────────────────────────────────────

.PHONY: local-init local-plan local-apply local-destroy local-kubeconfig

local-init: ## terraform init for local env
	$(TF) -chdir=$(TF_LOCAL) init

local-plan: ## terraform plan for local env
	$(TF) -chdir=$(TF_LOCAL) plan

local-apply: ## terraform apply for local env (creates VMs + bootstraps)
	$(TF) -chdir=$(TF_LOCAL) apply -auto-approve

local-destroy: ## terraform destroy for local env
	$(TF) -chdir=$(TF_LOCAL) destroy -auto-approve

local-kubeconfig: ## Write kubeconfig from local env
	$(TF) -chdir=$(TF_LOCAL) output -raw kubeconfig > ~/.kube/talos-local

# ─── Outscale ──────────────────────────────────────────────────────────────

.PHONY: outscale-init outscale-plan outscale-apply outscale-destroy

outscale-init: ## terraform init for Outscale
	$(TF) -chdir=$(TF_OUTSCALE) init

outscale-plan: ## terraform plan for Outscale
	$(TF) -chdir=$(TF_OUTSCALE) plan

outscale-apply: ## terraform apply for Outscale
	$(TF) -chdir=$(TF_OUTSCALE) apply -auto-approve

outscale-destroy: ## terraform destroy for Outscale
	$(TF) -chdir=$(TF_OUTSCALE) destroy -auto-approve

# ─── Scaleway — IAM (stage 0) ─────────────────────────────────────────────
# Run with your admin credentials. Creates scoped IAM apps for stages 1 & 2.

TF_SCW_IAM   := terraform/envs/scaleway/iam
TF_SCW_IMAGE := terraform/envs/scaleway/image

.PHONY: scaleway-bootstrap scaleway-iam-init scaleway-iam-apply scaleway-iam-destroy

scaleway-bootstrap: scaleway-iam-init scaleway-iam-apply scaleway-ci-init scaleway-ci-apply ## Bootstrap complet: IAM + Gitea + Woodpecker CI

scaleway-iam-init: ## terraform init for Scaleway IAM
	$(TF) -chdir=$(TF_SCW_IAM) init

scaleway-iam-apply: ## Create IAM apps + API keys (requires secret.tfvars)
	$(TF) -chdir=$(TF_SCW_IAM) apply -auto-approve -var-file=secret.tfvars

scaleway-iam-destroy: ## Destroy Scaleway IAM apps
	$(TF) -chdir=$(TF_SCW_IAM) destroy -auto-approve -var-file=secret.tfvars

# ─── Scaleway — Image (stage 1) ──────────────────────────────────────────
# Uses image-builder IAM credentials from stage 0.

.PHONY: scaleway-image-init scaleway-image-apply scaleway-image-destroy

scaleway-image-init: ## terraform init for Scaleway image builder
	$(TF) -chdir=$(TF_SCW_IMAGE) init

scaleway-image-apply: ## Build Talos image on Scaleway (builder VM + S3 + snapshot)
	SCW_ACCESS_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_access_key) \
	SCW_SECRET_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_secret_key) \
	$(TF) -chdir=$(TF_SCW_IMAGE) apply -auto-approve \
		-var="project_id=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)" \
		-var="scw_access_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_access_key)" \
		-var="scw_secret_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_secret_key)"

scaleway-image-destroy: ## Destroy builder VM + bucket (keeps image & snapshot)
	$(TF) -chdir=$(TF_SCW_IMAGE) state rm scaleway_instance_image.talos 2>/dev/null || true
	$(TF) -chdir=$(TF_SCW_IMAGE) state rm scaleway_instance_snapshot.talos 2>/dev/null || true
	SCW_ACCESS_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_access_key) \
	SCW_SECRET_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_secret_key) \
	$(TF) -chdir=$(TF_SCW_IMAGE) destroy -auto-approve \
		-var="project_id=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)" \
		-var="scw_access_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_access_key)" \
		-var="scw_secret_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_secret_key)"

scaleway-image-clean: ## Destroy ALL image resources (VM + snapshot + image + bucket)
	SCW_ACCESS_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_access_key) \
	SCW_SECRET_KEY=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_secret_key) \
	$(TF) -chdir=$(TF_SCW_IMAGE) destroy -auto-approve \
		-var="project_id=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw project_id)" \
		-var="scw_access_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_access_key)" \
		-var="scw_secret_key=$$($(TF) -chdir=$(TF_SCW_IAM) output -raw image_builder_secret_key)"

# ─── Scaleway — Cluster (stage 2) ────────────────────────────────────────
# Uses cluster IAM credentials from stage 0.

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

# ─── Scaleway — CI VM (stage 3) ─────────────────────────────────────
# Woodpecker CI on a standalone VM, bootstrapped via cloud-init.

TF_SCW_CI := terraform/envs/scaleway/ci

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

# ─── K8s Addons (stage 4 — Cilium CNI + monitoring) ─────────────────
# Cilium MUST be deployed first: it's the CNI, no pods schedule without it.
# Monitoring (VictoriaMetrics, Loki, Grafana, Alloy) depends on Cilium.

TF_K8S_ADDONS := terraform/stacks/k8s-addons

.PHONY: k8s-addons-init k8s-addons-apply k8s-addons-destroy

k8s-addons-init: ## terraform init for k8s-addons
	$(TF) -chdir=$(TF_K8S_ADDONS) init

k8s-addons-apply: ## Deploy Cilium + monitoring (must run before other k8s stacks)
	$(TF) -chdir=$(TF_K8S_ADDONS) apply -auto-approve \
		-var="kubernetes_host=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_host)" \
		-var="kubernetes_client_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_certificate)" \
		-var="kubernetes_client_key=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_key)" \
		-var="kubernetes_ca_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_ca_certificate)"

k8s-addons-destroy: ## Destroy monitoring + Cilium (must run AFTER other k8s stacks)
	$(TF) -chdir=$(TF_K8S_ADDONS) destroy -auto-approve \
		-var="kubernetes_host=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_host)" \
		-var="kubernetes_client_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_certificate)" \
		-var="kubernetes_client_key=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_key)" \
		-var="kubernetes_ca_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_ca_certificate)"

# ─── K8s Secrets (stage 5 — PKI + OpenBao) ──────────────────────────
# Root CA + Intermediate CA (TLS provider) + OpenBao infra/app
# Requires Cilium (stage 4) for pod scheduling.

TF_K8S_SECRETS := terraform/stacks/k8s-secrets

.PHONY: k8s-secrets-init k8s-secrets-apply k8s-secrets-destroy

k8s-secrets-init: ## terraform init for k8s-secrets
	$(TF) -chdir=$(TF_K8S_SECRETS) init

k8s-secrets-apply: ## Deploy PKI + OpenBao + identity
	$(TF) -chdir=$(TF_K8S_SECRETS) apply -auto-approve \
		-var="kubernetes_host=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_host)" \
		-var="kubernetes_client_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_certificate)" \
		-var="kubernetes_client_key=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_key)" \
		-var="kubernetes_ca_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_ca_certificate)"

k8s-secrets-destroy: ## Destroy PKI + OpenBao
	$(TF) -chdir=$(TF_K8S_SECRETS) destroy -auto-approve \
		-var="kubernetes_host=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_host)" \
		-var="kubernetes_client_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_certificate)" \
		-var="kubernetes_client_key=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_key)" \
		-var="kubernetes_ca_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_ca_certificate)"

# ─── K8s Security (stage 6 — Trivy + Tetragon + Kyverno) ────────────
# Requires Cilium (stage 4) for pod scheduling.

TF_K8S_SECURITY := terraform/stacks/k8s-security

.PHONY: k8s-security-init k8s-security-apply k8s-security-destroy

k8s-security-init: ## terraform init for k8s-security
	$(TF) -chdir=$(TF_K8S_SECURITY) init

k8s-security-apply: ## Deploy Trivy + Tetragon + Kyverno
	$(TF) -chdir=$(TF_K8S_SECURITY) apply -auto-approve \
		-var="kubernetes_host=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_host)" \
		-var="kubernetes_client_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_certificate)" \
		-var="kubernetes_client_key=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_key)" \
		-var="kubernetes_ca_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_ca_certificate)"

k8s-security-destroy: ## Destroy Trivy + Tetragon + Kyverno
	$(TF) -chdir=$(TF_K8S_SECURITY) destroy -auto-approve \
		-var="kubernetes_host=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_host)" \
		-var="kubernetes_client_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_certificate)" \
		-var="kubernetes_client_key=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_key)" \
		-var="kubernetes_ca_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_ca_certificate)"

# ─── K8s Storage (stage 7 — local-path + Garage + Velero) ────────────
# Requires Cilium (stage 4) for pod scheduling.

TF_K8S_STORAGE := terraform/stacks/k8s-storage

.PHONY: k8s-storage-init k8s-storage-apply k8s-storage-destroy

k8s-storage-init: ## terraform init for k8s-storage
	$(TF) -chdir=$(TF_K8S_STORAGE) init

k8s-storage-apply: ## Deploy local-path + Garage + Velero
	$(TF) -chdir=$(TF_K8S_STORAGE) apply -auto-approve \
		-var="kubernetes_host=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_host)" \
		-var="kubernetes_client_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_certificate)" \
		-var="kubernetes_client_key=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_key)" \
		-var="kubernetes_ca_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_ca_certificate)"

k8s-storage-destroy: ## Destroy local-path + Garage + Velero
	$(TF) -chdir=$(TF_K8S_STORAGE) destroy -auto-approve \
		-var="kubernetes_host=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_host)" \
		-var="kubernetes_client_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_certificate)" \
		-var="kubernetes_client_key=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_client_key)" \
		-var="kubernetes_ca_certificate=$$($(TF) -chdir=$(TF_SCALEWAY) output -raw kubernetes_ca_certificate)"

# ─── Composite targets (enforce correct ordering) ──────────────────────
#
# Dependency graph:
#   Creation:  cluster → addons (Cilium) → {secrets, security, storage}
#   Destruction: {secrets, security, storage} → addons (Cilium) → cluster
#
# Cilium is the CNI — without it, no pods can be scheduled.
# Destroying Cilium before other stacks leaves pods stuck in ContainerCreating.

.PHONY: scaleway-up scaleway-down scaleway-k8s-up scaleway-k8s-down scaleway-teardown scaleway-nuke

scaleway-up: scaleway-apply scaleway-wait scaleway-k8s-up ## Create cluster + all k8s stacks (correct order)

scaleway-wait: ## Wait for K8s API server to be reachable
	@echo "Waiting for API server..."
	@for i in $$(seq 1 30); do \
		$(TF) -chdir=$(TF_SCALEWAY) output -raw kubeconfig 2>/dev/null \
			| kubectl --kubeconfig /dev/stdin get nodes >/dev/null 2>&1 && break; \
		echo "  attempt $$i/30..."; sleep 10; \
	done
	@echo "API server ready."

scaleway-k8s-up: k8s-addons-apply ## Deploy all k8s stacks (Cilium first, then rest sequentially)
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
	$(MAKE) k8s-secrets-apply
	$(MAKE) k8s-security-apply
	$(MAKE) k8s-storage-apply

scaleway-k8s-down: ## Destroy all k8s stacks (workloads first, then Cilium)
	-$(MAKE) k8s-storage-destroy
	-$(MAKE) k8s-security-destroy
	-$(MAKE) k8s-secrets-destroy
	$(MAKE) k8s-addons-destroy

scaleway-down: scaleway-k8s-down scaleway-destroy ## Destroy all k8s stacks + cluster (correct order)

scaleway-teardown: scaleway-down scaleway-ci-destroy ## Destroy cluster + CI (keeps IAM + image/snapshot)

scaleway-nuke: ## DANGEROUS: destroy everything including IAM and image
	@echo "⚠  This will destroy ALL Scaleway resources: cluster, k8s stacks, CI, image, snapshot, IAM."
	@echo "   Only IAM admin credentials (secret.tfvars) will remain."
	@echo ""
	@read -p "Type 'yes-destroy-everything' to confirm: " confirm && [ "$$confirm" = "yes-destroy-everything" ] || (echo "Aborted."; exit 1)
	-$(MAKE) scaleway-down
	-$(MAKE) scaleway-ci-destroy
	-$(MAKE) scaleway-image-clean
	-$(MAKE) scaleway-iam-destroy

# ─── VMware airgap (scripts, not Terraform) ────────────────────────────────

.PHONY: vmware-image-cache vmware-build-ova vmware-gen-configs vmware-bootstrap

vmware-image-cache: ## Build OCI image cache for airgap (requires Internet)
	@$(MAKE) -C $(VMWARE) image-cache

vmware-build-ova: ## Build OVA with embedded image cache
	@$(MAKE) -C $(VMWARE) build-ova

vmware-gen-configs: ## Generate per-node machine configs (static IPs)
	@$(MAKE) -C $(VMWARE) gen-configs

vmware-bootstrap: ## Bootstrap etcd + kubeconfig (post-deployment)
	@$(MAKE) -C $(VMWARE) bootstrap

# ─── Scaleway — Tests ────────────────────────────────────────────────────

.PHONY: scaleway-test scaleway-iam-test scaleway-image-test scaleway-cluster-test k8s-addons-test

scaleway-test: scaleway-iam-test scaleway-image-test scaleway-cluster-test k8s-addons-test ## Run all Scaleway tofu tests

scaleway-iam-test: ## tofu test for IAM stage
	$(TF) -chdir=$(TF_SCW_IAM) test

scaleway-image-test: ## tofu test for image stage
	$(TF) -chdir=$(TF_SCW_IMAGE) test

scaleway-cluster-test: ## tofu test for cluster stage
	$(TF) -chdir=$(TF_SCALEWAY) test

k8s-addons-test: ## tofu test for k8s-addons stack
	$(TF) -chdir=$(TF_K8S_ADDONS) test

# ─── UI Access ─────────────────────────────────────────────────────────────

KUBECONFIG_CMD = $(TF) -chdir=$(TF_SCALEWAY) output -raw kubeconfig
KC_FILE = $(HOME)/.kube/talos-scaleway

.PHONY: scaleway-kubeconfig scaleway-headlamp scaleway-grafana

scaleway-kubeconfig: ## Export kubeconfig to ~/.kube/talos-scaleway
	@$(KUBECONFIG_CMD) > $(KC_FILE) 2>/dev/null
	@echo "export KUBECONFIG=$(KC_FILE)"

scaleway-headlamp: scaleway-kubeconfig ## Open Headlamp UI (token copied to clipboard)
	@KUBECONFIG=$(KC_FILE) kubectl create serviceaccount headlamp-admin -n kube-system 2>/dev/null || true
	@KUBECONFIG=$(KC_FILE) kubectl create clusterrolebinding headlamp-admin-token --clusterrole=cluster-admin --serviceaccount=kube-system:headlamp-admin 2>/dev/null || true
	@TOKEN=$$(KUBECONFIG=$(KC_FILE) kubectl create token headlamp-admin -n kube-system --duration=48h) && \
		echo "$$TOKEN" | pbcopy && \
		echo "Token copied to clipboard. Paste it in the Headlamp login page." && \
		echo "" && \
		KUBECONFIG=$(KC_FILE) kubectl port-forward -n monitoring svc/headlamp 4466:80 &  \
		sleep 2 && open http://localhost:4466

scaleway-grafana: scaleway-kubeconfig ## Open Grafana UI
	@echo "Opening Grafana..." && \
		KUBECONFIG=$(KC_FILE) kubectl port-forward -n monitoring svc/grafana 3000:80 & \
		sleep 2 && open http://localhost:3000

# ─── Common ────────────────────────────────────────────────────────────────

.PHONY: cilium-manifests validate clean

cilium-manifests: ## Generate Cilium static manifests from Helm
	./configs/cilium/generate-manifests.sh

validate: ## Validate all generated machine configs
	./scripts/validate.sh

clean: ## Remove all build artifacts
	rm -rf $(OUT_DIR)
	rm -rf $(VMWARE)/_out $(VMWARE)/image-cache.oci
