# k3s security lab — one-command deploy.
#
# Terraform provisions the day-0 platform from the terraform/cluster root:
#   - creates the local k3d cluster (null_resource + k3d CLI)
#   - `helm install`s the Gatekeeper, ESO, and Argo CD controllers
#   - imports the webapp image onto the node, then plants the Argo CD
#     Application (argocd/webapp-application.yaml)
#
# Argo CD then owns the webapp: it syncs the whole charts/webapp chart from Git
# into the `webapp` namespace and self-heals any out-of-band drift continuously.
#
# The apply is staged because the helm provider validates against a LIVE cluster
# at plan time — the cluster doesn't exist on pass 1, so we create it first with
# -target, install the controllers on pass 2, then apply the rest.

TF_CLUSTER := terraform/cluster
TF_INFRA   := terraform/infra
TF_SECRETS := terraform/secrets
TF         := terraform
APPROVE    := -input=false -auto-approve
# kubectl targets must hit the lab cluster regardless of the active context
# (Terraform pins this same context in providers.tf).
KUBECTL    := kubectl --context k3d-webapp-test
# The Argo Application + namespace the argo-* / webapp-ui targets act on.
# Defaults to the real migration (webapp). For the isolated demo, override:
#   make argo-pause ARGO_APP=webapp-demo
#   make webapp-ui  WEBAPP_NS=webapp-argo
ARGO_APP   ?= webapp
WEBAPP_NS  ?= webapp
# floci is the local AWS emulator (Secrets Manager, STS, ECR) on :4566 that ESO
# and the webapp image registry talk to. -p floci pins the compose project name
# so we reuse the running stack instead of spawning a port-4566 duplicate.
COMPOSE    := docker compose -p floci

# Secret values fed to the infra/secrets roots. Default to the documented lab
# examples; override on the CLI for real values, e.g.
#   make deploy DB_PASSWORD=... API_KEY=... SECRET_KEY=...
# Pass the SAME values every run — re-applying with different ones rewrites the
# secrets in floci.
DB_PASSWORD ?= hunter2
API_KEY     ?= abc123
SECRET_KEY  ?= s3cr3t

.DEFAULT_GOAL := help

.PHONY: help deploy destroy bootstrap floci-up floci-down argo-app argo-ui webapp-ui argo-pause argo-resume access status url infra secrets clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

deploy: bootstrap ## Full ordered deploy: floci + secrets + infra + cluster + webapp
	cd $(TF_CLUSTER) && $(TF) init -input=false
	@echo "==> Pass 1/3: create the k3d cluster"
	cd $(TF_CLUSTER) && $(TF) apply $(APPROVE) -target=null_resource.k3d_cluster -target=time_sleep.cluster_ready
	@echo "==> Pass 2/3: install Gatekeeper + ESO + Argo CD controllers"
	cd $(TF_CLUSTER) && $(TF) apply $(APPROVE) -target=helm_release.gatekeeper -target=time_sleep.gatekeeper_ready -target=helm_release.eso -target=time_sleep.eso_ready -target=helm_release.argocd -target=time_sleep.argocd_ready
	@echo "==> Pass 3/3: import image + plant Argo Application (Argo then syncs the webapp from Git)"
	cd $(TF_CLUSTER) && $(TF) apply $(APPROVE)
	@echo "==> Done. webapp owned by Argo CD. Access info:"
	@$(MAKE) --no-print-directory access

destroy: ## Tear down the k3d cluster (secrets/ and infra/ are left intact)
	cd $(TF_CLUSTER) && $(TF) destroy $(APPROVE)

floci-up: ## Start the floci AWS emulator (:4566) via docker compose
	$(COMPOSE) up -d

floci-down: ## Stop the floci AWS emulator
	$(COMPOSE) down

bootstrap: floci-up ## Start floci + apply secrets->infra->secrets(KMS) in the required order
	@echo "==> floci up; applying secrets (pass 1, no KMS)"
	cd $(TF_SECRETS) && $(TF) init -input=false && $(TF) apply $(APPROVE) -var="db_password=$(DB_PASSWORD)" -var="api_key=$(API_KEY)" -var="secret_key=$(SECRET_KEY)"
	@echo "==> applying infra (KMS, IAM role for ESO, ECR, RDS)"
	cd $(TF_INFRA) && $(TF) init -input=false && $(TF) apply $(APPROVE) -var="db_password=$(DB_PASSWORD)"
	@echo "==> re-applying secrets WITH KMS from infra output"
	cd $(TF_SECRETS) && $(TF) apply $(APPROVE) -var="kms_key_arn=$$(cd ../infra && $(TF) output -raw kms_key_arn)" -var="db_password=$(DB_PASSWORD)" -var="api_key=$(API_KEY)" -var="secret_key=$(SECRET_KEY)"

argo-app: ## Show the webapp Argo CD Application (sync/health + managed resources)
	-$(KUBECTL) get application $(ARGO_APP) -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
	@echo "---"
	-$(KUBECTL) get application $(ARGO_APP) -n argocd -o jsonpath='{range .status.resources[*]}{.kind}/{.name}  {.status}{"\n"}{end}'

argo-ui: ## Port-forward the Argo CD UI to https://localhost:8081
	@echo "Argo CD UI -> https://localhost:8081 (user: admin)"
	@echo "password: kubectl --context k3d-webapp-test -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
	$(KUBECTL) port-forward -n argocd svc/argocd-server 8081:443

webapp-ui: ## Port-forward the webapp to http://localhost:8080 (also on NodePort 30080)
	@echo "webapp -> http://localhost:8080  (or directly at http://localhost:30080)"
	$(KUBECTL) port-forward -n $(WEBAPP_NS) svc/webapp 8080:80

argo-pause: ## Pause Argo self-heal on the webapp app (drift will persist until resumed)
	$(KUBECTL) patch application $(ARGO_APP) -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":true}}}}'
	@echo "self-heal PAUSED — out-of-band changes now stick until 'make argo-resume'"

argo-resume: ## Resume Argo self-heal (reverts any outstanding drift within seconds)
	$(KUBECTL) patch application $(ARGO_APP) -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}'
	@echo "self-heal RESUMED — Argo reverts drift back to Git"

access: ## Print how to reach the webapp and the Argo CD UI
	@echo "webapp:      http://localhost:30080          (NodePort, host-mapped — no port-forward needed)"
	@echo "             make webapp-ui                  (alt: port-forward to :8080)"
	@echo "Argo CD UI:  make argo-ui                    (port-forward https://localhost:8081, user admin)"
	@echo "             password: kubectl --context k3d-webapp-test -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

# Leading '-' makes make ignore each command's exit code: status is read-only,
# so a transient hiccup (e.g. the 'constraints' aggregate category not yet in
# kubectl's discovery cache right after a fresh deploy) shouldn't fail the target.
status: ## Show cluster / webapp / ESO / Gatekeeper / Argo state
	-$(KUBECTL) get pods -A
	@echo "---"
	-$(KUBECTL) get externalsecret,secretstore -n $(WEBAPP_NS)
	@echo "---"
	-$(KUBECTL) get constraints
	@echo "---"
	-$(KUBECTL) get application $(ARGO_APP) -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

url: ## Print the webapp URL
	@cd $(TF_CLUSTER) && $(TF) output -raw app_url

# --- Optional: AWS-side prerequisites (LocalStack) --------------------------
# ESO pulls webapp/secrets and webapp/db-credentials from LocalStack Secrets
# Manager, so those secrets must exist before the webapp pod can start. These
# roots take sensitive vars — supply them via a gitignored terraform.tfvars in
# each root (or -var on the CLI). Apply order is: infra -> secrets -> deploy.

infra: ## Apply terraform/infra only (KMS, IAM, ECR, RDS)
	cd $(TF_INFRA) && $(TF) init -input=false && $(TF) apply $(APPROVE) -var="db_password=$(DB_PASSWORD)"

secrets: ## Apply terraform/secrets only (Secrets Manager, no KMS) — see bootstrap for the full order
	cd $(TF_SECRETS) && $(TF) init -input=false && $(TF) apply $(APPROVE) -var="db_password=$(DB_PASSWORD)" -var="api_key=$(API_KEY)" -var="secret_key=$(SECRET_KEY)"

clean: ## Remove local terraform state backups
	find $(TF) -name 'terraform.tfstate.*.backup' -delete
