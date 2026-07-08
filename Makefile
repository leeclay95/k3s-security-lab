# k3s security lab — one-command deploy.
#
# Terraform orchestrates the whole stack from the terraform/cluster root:
#   - creates the local k3d cluster (null_resource + k3d CLI)
#   - `helm install`s the Gatekeeper and ESO controllers
#   - `helm install`s the webapp platform chart (RBAC, ESO SecretStore/
#     ExternalSecrets, Gatekeeper templates + constraints) at charts/webapp/
#   - manages the webapp Deployment + Service as native kubernetes_* resources
#     so `terraform plan` detects and reverts out-of-band drift
#
# The apply is staged because the helm & kubernetes providers validate against
# a LIVE cluster at plan time — the cluster doesn't exist on pass 1, so we
# create it first with -target, install the controllers on pass 2, then let the
# final unconstrained apply reconcile everything else.

TF_CLUSTER := terraform/cluster
TF_INFRA   := terraform/infra
TF_SECRETS := terraform/secrets
TF         := terraform
APPROVE    := -input=false -auto-approve
# kubectl targets must hit the lab cluster regardless of the active context
# (Terraform pins this same context in providers.tf).
KUBECTL    := kubectl --context k3d-webapp-test
# floci is the local AWS emulator (Secrets Manager, STS, ECR) on :4566 that ESO
# and the webapp image registry talk to. -p floci pins the compose project name
# so we reuse the running stack instead of spawning a port-4566 duplicate.
COMPOSE    := docker compose -p floci

.DEFAULT_GOAL := help

.PHONY: help deploy destroy floci-up floci-down status url redeploy-webapp infra secrets clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

deploy: floci-up ## Start floci + create cluster + install Helm charts + deploy webapp (one command)
	cd $(TF_CLUSTER) && $(TF) init -input=false
	@echo "==> Pass 1/3: create the k3d cluster"
	cd $(TF_CLUSTER) && $(TF) apply $(APPROVE) -target=null_resource.k3d_cluster -target=time_sleep.cluster_ready
	@echo "==> Pass 2/3: install Gatekeeper + ESO controllers"
	cd $(TF_CLUSTER) && $(TF) apply $(APPROVE) -target=helm_release.gatekeeper -target=time_sleep.gatekeeper_ready -target=helm_release.eso -target=time_sleep.eso_ready
	@echo "==> Pass 3/3: webapp chart + Deployment/Service + everything else"
	cd $(TF_CLUSTER) && $(TF) apply $(APPROVE)
	@echo "==> Done. App: $$(cd $(TF_CLUSTER) && $(TF) output -raw app_url)"

destroy: ## Tear down the k3d cluster (secrets/ and infra/ are left intact)
	cd $(TF_CLUSTER) && $(TF) destroy $(APPROVE)

floci-up: ## Start the floci AWS emulator (:4566) via docker compose
	$(COMPOSE) up -d

floci-down: ## Stop the floci AWS emulator
	$(COMPOSE) down

redeploy-webapp: ## Reapply only the webapp Deployment/Service (revert drift)
	cd $(TF_CLUSTER) && $(TF) apply $(APPROVE) -target=kubernetes_deployment.webapp -target=kubernetes_service.webapp

status: ## Show cluster / webapp / ESO / Gatekeeper state
	$(KUBECTL) get pods -A
	@echo "---"
	$(KUBECTL) get externalsecret,secretstore -n webapp
	@echo "---"
	$(KUBECTL) get constraints

url: ## Print the webapp URL
	@cd $(TF_CLUSTER) && $(TF) output -raw app_url

# --- Optional: AWS-side prerequisites (LocalStack) --------------------------
# ESO pulls webapp/secrets and webapp/db-credentials from LocalStack Secrets
# Manager, so those secrets must exist before the webapp pod can start. These
# roots take sensitive vars — supply them via a gitignored terraform.tfvars in
# each root (or -var on the CLI). Apply order is: infra -> secrets -> deploy.

infra: ## Apply terraform/infra (KMS, IAM, ECR, RDS) — needs terraform.tfvars
	cd $(TF_INFRA) && $(TF) init -input=false && $(TF) apply $(APPROVE)

secrets: ## Apply terraform/secrets (Secrets Manager) — needs terraform.tfvars
	cd $(TF_SECRETS) && $(TF) init -input=false && $(TF) apply $(APPROVE)

clean: ## Remove local terraform state backups
	find $(TF) -name 'terraform.tfstate.*.backup' -delete
