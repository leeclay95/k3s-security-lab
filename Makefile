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
# Wrap terraform steps so a TRANSIENT provider-startup failure under load
# (this box thrashes; the AWS provider can hit "timeout while waiting for plugin
# to start") is retried instead of aborting the whole deploy. Every wrapped step
# is idempotent. RETRY takes the entire 'cd DIR && terraform ...' as one string.
# See scripts/retry.sh (args: <max_attempts> <sleep_seconds> <command...>).
RETRY      := ./scripts/retry.sh 3 15 sh -c
# kubectl targets must hit the lab cluster regardless of the active context
# (Terraform pins this same context in providers.tf).
KUBECTL    := kubectl --context k3d-webapp-test
# The Argo Application + namespace the argo-* / webapp-ui targets act on.
# Defaults to the real migration (webapp). For the isolated demo, override:
#   make argo-pause ARGO_APP=webapp-demo
#   make webapp-ui  WEBAPP_NS=webapp-argo
ARGO_APP   ?= webapp
WEBAPP_NS  ?= webapp
# Local ports the port-forward targets bind. Override when one is already taken:
#   make argo-ui   ARGO_PORT=8091
#   make webapp-ui WEBAPP_PORT=8090
ARGO_PORT   ?= 8081
WEBAPP_PORT ?= 8080
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

.PHONY: help deploy destroy nuke bootstrap cluster-up floci-up floci-down argo-app argo-ui argo-password webapp-ui argo-pause argo-resume access status url infra secrets clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

cluster-up: ## Start the k3d cluster if it exists but was stopped (e.g. after a reboot)
	@# Terraform's null_resource can't tell a stopped cluster from a healthy one,
	@# so self-heal here: if the cluster exists but its server is down, start it.
	@# After a restart k3s strips k3d's host.k3d.internal record from CoreDNS, so
	@# re-assert it durably (else ESO can't reach floci — the classic post-reboot
	@# SecretStore InvalidProviderConfig). No-op/quiet if the cluster is absent.
	@if k3d cluster list webapp-test >/dev/null 2>&1; then \
		k3d cluster start webapp-test 2>/dev/null || true; \
		./scripts/coredns-hostfix.sh webapp-test || true; \
	fi

deploy: bootstrap cluster-up ## Full ordered deploy: floci + secrets + infra + cluster + webapp
	$(RETRY) 'cd $(TF_CLUSTER) && $(TF) init -input=false'
	@echo "==> Pass 1/3: create the k3d cluster"
	$(RETRY) 'cd $(TF_CLUSTER) && $(TF) apply $(APPROVE) -target=null_resource.k3d_cluster -target=time_sleep.cluster_ready'
	@echo "==> Make host.k3d.internal resolution durable (survives reboots) before ESO installs"
	./scripts/coredns-hostfix.sh webapp-test
	@echo "==> Pass 2/3: install Gatekeeper + ESO + Argo CD controllers"
	$(RETRY) 'cd $(TF_CLUSTER) && $(TF) apply $(APPROVE) -target=helm_release.gatekeeper -target=time_sleep.gatekeeper_ready -target=helm_release.eso -target=time_sleep.eso_ready -target=helm_release.argocd -target=time_sleep.argocd_ready'
	@echo "==> Pass 3/3: import image, wait for ESO CRDs, plant Argo Application, wait for webapp Healthy"
	$(RETRY) 'cd $(TF_CLUSTER) && $(TF) apply $(APPROVE)'
	@echo "==> Done. webapp owned by Argo CD and verified Healthy. Access info:"
	@$(MAKE) --no-print-directory access

destroy: ## Reliably tear down the k3d cluster end-to-end (floci/secrets/infra intact)
	@# Reliability contract: the cluster is GONE when this returns, no matter what
	@# state Terraform/Helm are in. Two layers:
	@#   1. graceful `terraform destroy` to keep TF state in sync — but tolerated
	@#      (leading '-'), because it destroys the k3d cluster LAST, gated behind
	@#      `helm uninstall` of ESO/Argo/Gatekeeper. A stuck release (e.g. a
	@#      half-uninstalled ESO) makes that hang until "context deadline exceeded"
	@#      and abort BEFORE the cluster is ever deleted.
	@#   2. `k3d cluster delete` backstop — removes the node container and ALL
	@#      cluster state (every namespace, Argo, ESO, webapp) in one shot. It does
	@#      not depend on TF/Helm state or API reachability, so it always succeeds.
	@# Then reset the cluster-root state: everything in terraform/cluster lives and
	@# dies with the cluster, so clearing it guarantees the next `make deploy`
	@# starts from a clean slate instead of reconciling now-nonexistent resources.
	@echo "==> Graceful attempt: terraform destroy (best-effort, time-boxed to 120s)"
	@# Time-boxed so a stuck `helm uninstall` (context-deadline hang, seen when ESO
	@# is half-removed) can't stall teardown — the backstop below is authoritative.
	-timeout 120 sh -c 'cd $(TF_CLUSTER) && $(TF) destroy $(APPROVE)'
	@echo "==> Backstop: force-delete the k3d cluster (guarantees teardown)"
	-k3d cluster delete webapp-test
	@echo "==> Reset cluster-root Terraform state (it is 100% cluster-ephemeral)"
	-rm -f $(TF_CLUSTER)/terraform.tfstate $(TF_CLUSTER)/terraform.tfstate.backup
	@echo "==> Destroyed. Verify (expect: no webapp-test cluster):"
	-k3d cluster list webapp-test

nuke: destroy floci-down ## destroy + stop floci (full local teardown; secrets/infra state kept)
	@echo "==> floci stopped. secrets/ and infra/ Terraform state are preserved."

floci-up: ## Start the floci AWS emulator (:4566) via docker compose
	$(COMPOSE) up -d

floci-down: ## Stop the floci AWS emulator
	$(COMPOSE) down

bootstrap: floci-up ## Start floci + apply secrets->infra->secrets(KMS) in the required order
	@echo "==> floci up; applying secrets (pass 1, no KMS)"
	$(RETRY) 'cd $(TF_SECRETS) && $(TF) init -input=false && $(TF) apply $(APPROVE) -var="db_password=$(DB_PASSWORD)" -var="api_key=$(API_KEY)" -var="secret_key=$(SECRET_KEY)"'
	@echo "==> applying infra (KMS, IAM role for ESO, ECR, RDS)"
	$(RETRY) 'cd $(TF_INFRA) && $(TF) init -input=false && $(TF) apply $(APPROVE) -var="db_password=$(DB_PASSWORD)"'
	@echo "==> re-applying secrets WITH KMS from infra output"
	$(RETRY) 'cd $(TF_SECRETS) && $(TF) apply $(APPROVE) -var="kms_key_arn=$$(cd ../infra && $(TF) output -raw kms_key_arn)" -var="db_password=$(DB_PASSWORD)" -var="api_key=$(API_KEY)" -var="secret_key=$(SECRET_KEY)"'

argo-app: ## Show the webapp Argo CD Application (sync/health + managed resources)
	-$(KUBECTL) get application $(ARGO_APP) -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
	@echo "---"
	-$(KUBECTL) get application $(ARGO_APP) -n argocd -o jsonpath='{range .status.resources[*]}{.kind}/{.name}  {.status}{"\n"}{end}'

argo-ui: ## Port-forward the Argo CD UI (user admin); override port with ARGO_PORT=
	@echo "Argo CD UI -> https://localhost:$(ARGO_PORT)  (user: admin)"
	@echo "password:      make argo-password"
	@echo "(port in use? re-run with a different local port, e.g. make argo-ui ARGO_PORT=8091)"
	$(KUBECTL) port-forward -n argocd svc/argocd-server $(ARGO_PORT):443

argo-password: ## Print the Argo CD initial admin password
	@$(KUBECTL) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

webapp-ui: ## Port-forward the webapp to localhost (default :8080); override with WEBAPP_PORT=
	@echo "webapp -> http://localhost:$(WEBAPP_PORT)  (or directly at http://localhost:30080)"
	@echo "(port in use? re-run with a different local port, e.g. make webapp-ui WEBAPP_PORT=8090)"
	$(KUBECTL) port-forward -n $(WEBAPP_NS) svc/webapp $(WEBAPP_PORT):80

argo-pause: ## Pause Argo self-heal on the webapp app (drift will persist until resumed)
	$(KUBECTL) patch application $(ARGO_APP) -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":true}}}}'
	@echo "self-heal PAUSED — out-of-band changes now stick until 'make argo-resume'"

argo-resume: ## Resume Argo self-heal (reverts any outstanding drift within seconds)
	$(KUBECTL) patch application $(ARGO_APP) -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":true}}}}'
	@echo "self-heal RESUMED — Argo reverts drift back to Git"

access: ## Print how to reach the webapp and the Argo CD UI
	@echo "webapp:      http://localhost:30080          (NodePort, host-mapped — no port-forward needed)"
	@echo "             make webapp-ui                  (alt: port-forward to :$(WEBAPP_PORT); override WEBAPP_PORT=)"
	@echo "Argo CD UI:  make argo-ui                    (port-forward https://localhost:$(ARGO_PORT), user admin; override ARGO_PORT=)"
	@echo "             make argo-password              (prints the admin password)"

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
