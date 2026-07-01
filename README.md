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
│  │ gatekeeper-system (Helm chart)                │    │
│  │  Webhook: block-privileged, require-non-root, │    │
│  │  require-limits, block-host-ns, block-caps    │    │
│  └───────────────────────────────────────────────┘    │
│                                                        │
│  ┌───────────────────────────────────────────────┐    │
│  │ external-secrets (Helm chart)                 │    │
│  │  ESO controller → LocalStack STS → role creds │    │
│  │  SecretStore → Secrets Manager → K8s Secrets  │    │
│  └───────────────────────────────────────────────┘    │
│                                                        │
│  ┌───────────────────────────────────────────────┐    │
│  │ webapp namespace (Helm chart)                 │    │
│  │  webapp-sa (automountServiceAccountToken=false│    │
│  │  webapp pod (ECR image, readOnlyRootFilesystem│    │
│  │    env: SECRET_KEY, DB_PASSWORD, DB_URL       │    │
│  │    all from K8s Secrets managed by ESO        │    │
│  │  Gatekeeper policies (hook-ordered)           │    │
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

Two-pass apply — the Helm provider validates against a live cluster at plan time:

```bash
cd terraform/cluster
terraform init

# Pass 1 — create the cluster
terraform apply -target=null_resource.k3d_cluster -target=time_sleep.cluster_ready

# Pass 2 — everything else (Helm charts: Gatekeeper, ESO, webapp)
terraform apply
```

> **Note:** The previous 3-pass requirement is now reduced to 2 passes. Gatekeeper policies and ESO configuration are deployed by the webapp Helm chart with hook-based ordering, eliminating the separate kubectl apply steps.

---

## Helm Chart — `charts/webapp/`

The webapp and all its supporting resources are packaged as a local Helm chart. This replaces the previous loose YAML files and `null_resource` + `kubectl apply` calls.

### What's in the chart

| Template | Resources |
|---|---|
| `deployment.yaml` | Hardened nginx-unprivileged deployment |
| `service.yaml` | NodePort service (30080 → 8080) |
| `serviceaccount.yaml` | ServiceAccount + zero-permission Role + RoleBinding |
| `eso-aws-credentials.yaml` | AWS credentials Secret for ESO |
| `eso-secretstore.yaml` | SecretStore with IAM role assumption |
| `eso-externalsecret.yaml` | ExternalSecret for app secrets |
| `eso-db-externalsecret.yaml` | ExternalSecret for DB credentials |
| `gatekeeper-templates.yaml` | 5 ConstraintTemplates (Helm hook, weight 0) |
| `gatekeeper-constraints.yaml` | 5 Constraints (Helm hook, weight 5) |

### Customizing values

Override defaults in `values.yaml` or pass via Terraform `set {}` blocks:

```bash
# Preview rendered templates
helm template webapp charts/webapp/ --debug

# Disable Gatekeeper policies (e.g., for testing)
helm template webapp charts/webapp/ --set gatekeeper.enabled=false
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
kubectl describe k8sblockprivileged.constraints.gatekeeper.sh/block-privileged-containers
kubectl get events -n webapp --field-selector reason=FailedCreate

# Restore clean state
cd terraform/cluster && terraform apply
```

### kubesec — static manifest score

```bash
kubesec scan examples/hardened/deployment.yaml
# score: +12 (was -85 before hardening)
```

### ESO — secret rotation test

```bash
# Update a secret value in LocalStack
aws --endpoint-url=http://localhost:4566 secretsmanager put-secret-value --secret-id webapp/secrets --secret-string '{"db_password":"newpass","api_key":"newkey","secret_key":"newval"}'

# ESO syncs within refreshInterval (1 minute) — watch it update
kubectl get secret webapp-secret -n webapp -w
```

### Helm lifecycle

```bash
# View release status
helm list -n webapp

# Rollback to previous version
helm rollback webapp -n webapp

# Show diff before upgrade
helm diff upgrade webapp charts/webapp/ -n webapp
```

---

## Key Commands

```bash
# App
curl http://localhost:30080

# Pod status + image
kubectl get pods -n webapp -o wide
kubectl get pod -n webapp -o jsonpath='{.items[0].spec.containers[0].image}'

# Secrets synced by ESO
kubectl get externalsecret -n webapp
kubectl get secret webapp-secret webapp-db-secret -n webapp

# Gatekeeper constraints
kubectl get constraints
kubectl get constrainttemplates

# Helm releases
helm list -A

# IAM role assumption (what ESO does each sync)
aws --endpoint-url=http://localhost:4566 sts assume-role --role-arn arn:aws:iam::000000000000:role/eso-role --role-session-name test

# ECR login
aws --endpoint-url=http://localhost:4566 ecr get-login-password | docker login --username AWS --password-stdin 000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100
```

---

## Project Structure

```
.
├── charts/
│   └── webapp/                      # Helm chart — all K8s resources for the webapp
│       ├── Chart.yaml
│       ├── values.yaml              # Parameterized defaults (image, resources, ESO, Gatekeeper)
│       └── templates/
│           ├── _helpers.tpl
│           ├── deployment.yaml      # Hardened nginx deployment
│           ├── service.yaml         # NodePort 30080 → container 8080
│           ├── serviceaccount.yaml  # webapp-sa + zero-permission Role + RoleBinding
│           ├── eso-aws-credentials.yaml
│           ├── eso-secretstore.yaml
│           ├── eso-externalsecret.yaml
│           ├── eso-db-externalsecret.yaml
│           ├── gatekeeper-templates.yaml   # 5 ConstraintTemplates (hook weight 0)
│           └── gatekeeper-constraints.yaml # 5 Constraints (hook weight 5)
├── examples/
│   ├── hardened/                    # Reference YAML — the hardened manifests for kubesec scoring
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── serviceaccount.yaml
│   │   └── namespace.yaml
│   ├── insecure/
│   │   └── secret-bad.yaml          # Teaching example: plaintext secrets (DO NOT USE)
│   └── reference/
│       └── gatekeeper-policies.yaml # Combined template+constraint reference file
├── registries.yaml                  # k3d registry mirror config for LocalStack ECR
└── terraform/
    ├── secrets/                     # Persistent — Secrets Manager secrets (prevent_destroy)
    ├── infra/                       # Persistent — KMS, IAM, ECR, RDS, CloudWatch, SNS
    └── cluster/                     # Disposable — k3d cluster + 3 Helm releases
        ├── cluster.tf               # k3d cluster create/destroy
        ├── gatekeeper.tf            # Gatekeeper Helm chart
        ├── eso.tf                   # ESO Helm chart (with extraEnv for LocalStack)
        ├── webapp.tf                # Webapp Helm chart (single helm_release)
        ├── providers.tf             # Helm + null + time providers
        └── outputs.tf               # App URL, Helm release name
```
