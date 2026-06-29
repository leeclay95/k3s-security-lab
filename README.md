# k3s Security Lab

A fully automated Kubernetes security lab that deploys a hardened nginx webapp on a local k3d cluster backed by LocalStack AWS services. Built to demonstrate layered security controls across static analysis, runtime admission control, secrets management, and infrastructure hardening — all repeatable from a single Terraform apply sequence.

---

## What This Proves

| Layer | Tool | What it enforces |
|---|---|---|
| Static analysis | kubesec | Scores manifests before anything is deployed — CI gate |
| Admission control | OPA Gatekeeper | Cluster refuses insecure pods at apply time, no bypass possible |
| Secrets management | External Secrets Operator | Secrets never in manifests or Git; injected at runtime from Secrets Manager |
| IaC security | tfsec | Terraform scanned for misconfigurations — 0 HIGH findings |
| Image provenance | ECR (LocalStack) | Private registry with immutable tags; no public image pull at runtime |
| Encryption at rest | KMS | Secrets Manager and RDS encrypted with a customer-managed CMK |
| Least privilege | IAM role assumption | ESO assumes a scoped role; static creds can only call sts:AssumeRole |
| RBAC | ServiceAccount + empty Role | Pod identity with zero API permissions; no token automount |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  LocalStack (localhost:4566)                            │
│                                                         │
│  ┌──────┐  ┌────────────────┐  ┌─────┐  ┌──────────┐  │
│  │ KMS  │  │Secrets Manager │  │ RDS │  │CloudWatch│  │
│  │ CMK  │  │webapp/secrets  │  │ pg  │  │+ SNS     │  │
│  └──┬───┘  │webapp/db-creds │  └─────┘  └──────────┘  │
│     │      └───────┬────────┘                          │
│     └──────────────┘ (encrypts)                        │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │ IAM                                              │  │
│  │  eso-user ──(sts:AssumeRole)──► eso-role         │  │
│  │                                  │               │  │
│  │                     GetSecretValue (exact ARNs)  │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  ECR (port 5100): 000000000000.dkr.ecr.*.cloud:5100    │
└─────────────────────────────────────────────────────────┘
             │ secrets synced by ESO          │ image
             ▼                                ▼
┌────────────────────────────────────────────────────────┐
│  k3d cluster: webapp-test                              │
│                                                        │
│  ┌───────────────────────────────────────────────┐    │
│  │ gatekeeper-system                             │    │
│  │  Webhook: block-privileged, require-non-root, │    │
│  │  require-limits, block-host-ns, block-caps    │    │
│  └───────────────────────────────────────────────┘    │
│                                                        │
│  ┌───────────────────────────────────────────────┐    │
│  │ external-secrets                              │    │
│  │  ESO controller → LocalStack STS → role creds │    │
│  │  SecretStore → Secrets Manager → K8s Secrets  │    │
│  └───────────────────────────────────────────────┘    │
│                                                        │
│  ┌───────────────────────────────────────────────┐    │
│  │ webapp namespace                              │    │
│  │  webapp-sa (automountServiceAccountToken=false│    │
│  │  webapp pod (ECR image, readOnlyRootFilesystem│    │
│  │    env: SECRET_KEY, DB_PASSWORD, DB_URL       │    │
│  │    all from K8s Secrets managed by ESO        │    │
│  └───────────────────────────────────────────────┘    │
│                                                        │
│  NodePort 30080 → container 8080                       │
└────────────────────────────────────────────────────────┘
```

---

## Prerequisites

```bash
# Required tools
docker          # Docker Engine (k3d runs cluster nodes as containers)
k3d             # Local k3s clusters via Docker
kubectl         # Kubernetes CLI
terraform       # >= 1.3
helm            # Helm 3
kubesec         # Static manifest scanner
tfsec           # Terraform static analysis
aws             # AWS CLI v2 (uses AWS_ENDPOINT_URL env var for LocalStack)
gh              # GitHub CLI (for repo management only)

# LocalStack running with these services
curl -s http://localhost:4566/_localstack/health | jq '.services | keys'
# Required: secretsmanager, kms, iam, sts, ecr, rds, s3, cloudwatch, logs, sns
```

---

## Apply Order

Three independent Terraform roots applied in sequence. Each root is isolated so secrets and infrastructure survive cluster destroy/recreate.

### 1. Secrets (persistent — apply once)

```bash
cd terraform/secrets
terraform init
terraform apply -var="db_password=hunter2" -var="api_key=abc123" -var="secret_key=s3cr3t"
```

### 2. Infrastructure (persistent — apply once, re-apply to update)

```bash
cd terraform/infra
terraform init
terraform apply -var="db_password=hunter2"
terraform output kms_key_arn
```

Re-apply secrets with KMS encryption now that the key exists:

```bash
cd terraform/secrets
terraform apply -var="kms_key_arn=$(cd ../infra && terraform output -raw kms_key_arn)" -var="db_password=hunter2" -var="api_key=abc123" -var="secret_key=s3cr3t"
```

### 3. Cluster (disposable — destroy and recreate freely)

Three-pass required because Helm and Kubernetes providers validate against a live cluster at plan time:

```bash
cd terraform/cluster
terraform init

# Pass 1 — create the cluster
terraform apply -target=null_resource.k3d_cluster -target=time_sleep.cluster_ready

# Pass 2 — Helm charts (Gatekeeper, ESO)
terraform apply -target=helm_release.gatekeeper -target=helm_release.eso -target=null_resource.eso_endpoint -target=time_sleep.eso_ready -target=time_sleep.gatekeeper_ready

# Pass 3 — everything else
terraform apply
```

---

## tfsec Results

```
tfsec ./terraform -m HIGH --concise-output
# No problems detected.
```

All four original HIGH findings resolved:

| Finding | Fix |
|---|---|
| ECR mutable tags | `image_tag_mutability = "IMMUTABLE"` |
| IAM wildcard resource | Exact secret ARNs via data source — no `webapp/*` glob |
| SNS unencrypted | `kms_master_key_id` on topic |
| RDS storage unencrypted | `storage_encrypted = true` with KMS CMK |

---

## Testing Security Controls

### Gatekeeper — live admission denial

```bash
# Try to deploy a privileged pod — Gatekeeper blocks it
kubectl run badpod -n webapp --image=nginx --overrides='{"spec":{"containers":[{"name":"badpod","image":"nginx","securityContext":{"privileged":true}}]}}'
# Error from server: admission webhook denied the request

# See the violation recorded on the constraint
kubectl describe k8sblockprivileged.constraints.gatekeeper.sh/block-privileged
kubectl get events -n webapp --field-selector reason=FailedCreate

# Restore clean state
cd terraform/cluster && terraform apply
```

### kubesec — static manifest score

```bash
./scan.sh
# deployment.yaml score: +12 (was -85 before hardening)
```

### ESO — secret rotation test

```bash
# Update a secret value in LocalStack
aws --endpoint-url=http://localhost:4566 secretsmanager put-secret-value --secret-id webapp/secrets --secret-string '{"db_password":"newpass","api_key":"newkey","secret_key":"newval"}'

# ESO syncs within refreshInterval (1 minute) — watch it update
kubectl get secret webapp-secret -n webapp -w
```

### Drift — Terraform detects and reverts manual changes

```bash
# Manually add an insecure setting
kubectl patch deployment webapp -n webapp --patch '{"spec":{"template":{"spec":{"containers":[{"name":"webapp","securityContext":{"privileged":true}}]}}}}'
# Blocked by Gatekeeper — confirms the webhook is live

# If not blocked (e.g. on a non-webhook path), Terraform plan shows drift
cd terraform/cluster && terraform plan
terraform apply  # reverts to hardened state
```

---

## Key Commands

```bash
# App
curl http://172.24.0.2:30080

# Pod status + image
kubectl get pods -n webapp -o wide
kubectl get pod -n webapp -o jsonpath='{.items[0].spec.containers[0].image}'

# Secrets synced by ESO
kubectl get externalsecret -n webapp
kubectl get secret webapp-secret webapp-db-secret -n webapp

# Gatekeeper constraints
kubectl get constraints
kubectl get constrainttemplates

# IAM role assumption (what ESO does each sync)
aws --endpoint-url=http://localhost:4566 sts assume-role --role-arn arn:aws:iam::000000000000:role/eso-role --role-session-name test

# ECR login
aws --endpoint-url=http://localhost:4566 ecr get-login-password | docker login --username AWS --password-stdin 000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100
```

---

## Project Structure

```
.
├── deployment.yaml          # Hardened nginx deployment (insecure settings commented inline)
├── service.yaml             # NodePort 30080 → container 8080
├── serviceaccount.yaml      # webapp-sa + zero-permission Role + RoleBinding
├── namespace.yaml           # webapp namespace
├── gatekeeper-templates.yaml  # 5 ConstraintTemplates (applied before constraints)
├── gatekeeper-constraints.yaml # 5 Constraints scoped to webapp namespace
├── eso-secretstore.yaml     # SecretStore with IAM role assumption
├── eso-externalsecret.yaml  # Syncs webapp/secrets → webapp-secret
├── eso-db-externalsecret.yaml # Syncs webapp/db-credentials → webapp-db-secret
├── registries.yaml          # k3d registry mirror config for LocalStack ECR
├── scan.sh                  # kubesec batch scan script
├── RESULTS.md               # Full build log with errors and fixes
└── terraform/
    ├── infra/               # KMS, IAM, ECR, RDS, CloudWatch, SNS
    ├── secrets/             # Secrets Manager secrets (prevent_destroy)
    └── cluster/             # k3d cluster, Gatekeeper, ESO, webapp
```
