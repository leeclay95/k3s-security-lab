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

### Ownership

| Layer | Owner | Managed by |
|---|---|---|
| k3d cluster, floci prereqs (infra/secrets), image import | **Terraform** | `terraform/` roots + Makefile |
| Gatekeeper, ESO, **Argo CD** controllers | **Terraform** | `helm_release` in `terraform/cluster/` |
| webapp workload — Deployment, Service, RBAC, ConfigMap, ESO config, Gatekeeper policies | **Argo CD** | `Application webapp` → `charts/webapp` from Git |

Terraform installs Argo CD and plants the `Application`
(`argocd/webapp-application.yaml`, applied by `terraform/cluster/argocd.tf`);
from there Argo is the **single reconciler** of the `webapp` namespace and
self-heals drift continuously. See [Config drift](#config-drift--argo-cd-self-heals-out-of-band-changes-gitops).

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

> **TL;DR:** `make deploy` runs this entire chain in order for you — floci →
> secrets → infra → secrets (re-applied with KMS) → cluster (staged). Secret
> values default to the lab examples; override with
> `make deploy DB_PASSWORD=… API_KEY=… SECRET_KEY=…`. The manual steps below are
> the reference for what it automates and why the order matters (infra's IAM
> policy reads the `webapp/secrets` secret, so **secrets must exist first**).

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

One command from the repo root — the `Makefile` runs the staged apply for you:

```bash
make deploy     # create cluster, install Helm charts (Gatekeeper, ESO, webapp), deploy webapp
make destroy    # tear down the cluster (secrets/ and infra/ survive)
make status     # pods, ExternalSecrets, Gatekeeper constraints
make url        # print the webapp URL
```

`make deploy` stages the apply internally because the Helm and Kubernetes
providers validate against a **live** cluster at plan time: it creates the k3d
cluster first (`-target`), then installs the Gatekeeper + ESO controllers, then
runs the final unconstrained apply for the webapp and everything else.

To run it by hand instead:

```bash
cd terraform/cluster && terraform init
terraform apply -target=null_resource.k3d_cluster -target=time_sleep.cluster_ready
terraform apply
```

### Destroy and recreate the cluster

`make destroy` removes only the k3d cluster — `terraform/secrets` and
`terraform/infra` (LocalStack secrets, KMS, RDS, etc.) survive, so the recreate
picks them straight back up.

```bash
make destroy            # tear down the cluster
make deploy             # bring it back (cluster + Helm charts + webapp)

make destroy && make deploy   # or both in one line
```

After it comes back up:

```bash
make status             # pods, ExternalSecrets, Gatekeeper constraints
make url                # prints http://localhost:30080
```

> **Note:** LocalStack must be running before `make deploy` (`docker ps | grep
> localstack`), or ESO reports `SecretSyncedError` and the webapp pod won't
> receive its secrets.

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
| `gatekeeper-templates.yaml` | 5 ConstraintTemplates (Helm hook wt 0 / Argo sync-wave 0) |
| `gatekeeper-constraints.yaml` | 5 Constraints (Helm hook wt 5 / Argo sync-wave 1) |
| `values-argocd.yaml` | Values for the Argo CD-managed deployment (`helmHooks: false`) |

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

### Gatekeeper — test the admission policies

Five constraints are enforced (`enforcementAction: deny`) and scoped to the
`webapp` namespace. Gatekeeper is an admission webhook, so violations are
**rejected at apply time** — the object never reaches the cluster.

**See what's active:**

```bash
kubectl get constrainttemplates          # the 5 policy templates
kubectl get constraints                   # the 5 constraints + live violation counts
```

**Test each policy** — every command below should be **denied** by the webhook:

```bash
# 1. block-privileged — privileged container
kubectl run t1 -n webapp --image=nginx --overrides='{"spec":{"containers":[{"name":"t1","image":"nginx","securityContext":{"privileged":true}}]}}'

# 2. require-non-root — no runAsNonRoot
kubectl run t2 -n webapp --image=nginx
# denied: containers must set runAsNonRoot: true

# 3. require-resource-limits — no cpu/memory limits
kubectl run t3 -n webapp --image=nginx --overrides='{"spec":{"containers":[{"name":"t3","image":"nginx","securityContext":{"runAsNonRoot":true}}]}}'
# denied: container has no resource limits

# 4. block-host-namespaces — hostNetwork/hostPID/hostIPC
kubectl run t4 -n webapp --image=nginx --overrides='{"spec":{"hostNetwork":true,"containers":[{"name":"t4","image":"nginx"}]}}'

# 5. block-dangerous-caps — added SYS_ADMIN capability
kubectl run t5 -n webapp --image=nginx --overrides='{"spec":{"containers":[{"name":"t5","image":"nginx","securityContext":{"capabilities":{"add":["SYS_ADMIN"]}}}]}}'
```

Each returns `Error from server: admission webhook "validation.gatekeeper.sh"
denied the request: [<constraint>] <message>`.

**Confirm the compliant webapp still passes** — Argo's deployment satisfies all
five (non-root, limits, dropped caps, no host namespaces), so it stays Healthy:

```bash
kubectl get pods -n webapp                # webapp pod Running — it meets every policy
```

**Inspect violations / audit** (Gatekeeper also audits existing objects, not just
new ones):

```bash
kubectl describe k8srequirelimits.constraints.gatekeeper.sh/require-resource-limits
kubectl get constraints -o custom-columns='NAME:.metadata.name,ACTION:.spec.enforcementAction,VIOLATIONS:.status.totalViolations'
```

> These policies are part of the chart Argo owns. To change them, edit
> `charts/webapp/templates/gatekeeper-*.yaml`, commit, and Argo syncs the new
> policy — the GitOps path for security controls too.

### Config drift — Argo CD self-heals out-of-band changes (GitOps)

The webapp is owned by **Argo CD**, not Terraform (see [Ownership](#ownership)).
Argo continuously reconciles the live `webapp` namespace against `charts/webapp`
in Git: any out-of-band `kubectl` edit is reverted by `selfHeal`, and objects
deleted from the cluster are recreated by `prune` — no `terraform apply` needed.

#### Accessing the apps

```bash
make access        # prints all URLs + how to log in
```

| What | How |
|---|---|
| **webapp** | `http://localhost:30080` (NodePort, host-mapped — survives pod rollovers) |
| **Argo CD UI** | `make argo-ui` → `https://localhost:8081`, user `admin` |
| **Argo admin password** | `kubectl --context k3d-webapp-test -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d` |

The Argo UI serves HTTPS with a self-signed cert — accept the browser warning.
After first login, change the admin password and delete the bootstrap secret.

#### Quick CLI drift tests

```bash
# scale out of band — Argo scales it back to the Git value (1)
kubectl scale deploy/webapp -n webapp --replicas=5
kubectl get deploy webapp -n webapp -w        # watch it return to 1 (Ctrl-C to stop)

# delete a managed object — prune recreates it from Git
kubectl delete svc webapp -n webapp
kubectl get svc -n webapp -w                  # watch it reappear

make argo-app                                 # Application flips OutOfSync -> Synced
```

#### Full page-drift walkthrough (see it in the browser)

Self-heal is fast, so to actually *watch* the drift, **pause** it first, then
resume on demand:

```bash
# 0. baseline — the Git-declared page
curl -s http://localhost:30080 | grep -o '<title>.*</title>'     # Welcome to nginx!

# 1. PAUSE Argo's auto-revert so the drift holds
make argo-pause

# 2. mount the Matrix page over nginx's docroot on the LIVE Deployment (out-of-band)
kubectl apply -f examples/matrix-configmap.yaml
kubectl patch deployment webapp -n webapp --type=strategic -p '{"spec":{"template":{"spec":{"volumes":[{"name":"html","configMap":{"name":"matrix-index-html"}}]}}}}'
kubectl rollout status deploy/webapp -n webapp
curl -s http://localhost:30080 | grep -o '<title>.*</title>'     # the matrix has you
#    open http://localhost:30080 in the browser — the Matrix page STAYS (self-heal paused)
#    in the Argo UI the webapp app now shows OutOfSync (drift detected, not healed)

# 3. RESUME self-heal — Argo reverts the mount back to Git within seconds
make argo-resume
kubectl rollout status deploy/webapp -n webapp
curl -s http://localhost:30080 | grep -o '<title>.*</title>'     # Welcome to nginx! (reverted)

# 4. cleanup the leftover drift ConfigMap (Argo never tracked it, so it lingers)
kubectl delete -f examples/matrix-configmap.yaml
```

> **The GitOps way to actually change the page** (vs. the drift above) is to edit
> `charts/webapp/templates/configmap-index.yaml`, commit, and push — Argo then
> deploys it as an *approved* change. The `kubectl patch` is the *unapproved* path,
> which is exactly why Argo reverts it.

#### GUI drift test

With `make argo-ui` running, open the `webapp` app tile: the resource tree shows
each object's health, status flips to **OutOfSync** the instant you drift it, and
back to **Synced** as Argo reconciles. The **APP DIFF** button shows the exact diff.

> **Self-heal latency:** a single drift on a healthy app reverts within seconds.
> Argo applies an exponential **self-heal backoff** under *repeated* rapid drift,
> so during heavy testing a revert can take a minute or two — it always converges.
> `make argo-pause` / `make argo-resume` gives you deterministic control for demos.

**Try it without a full migration** — `examples/argocd-webapp-demo.yaml` runs the
same chart under Argo in an isolated `webapp-argo` namespace (Gatekeeper disabled,
nodePort 30081) so it's safe on a cluster where Terraform still owns `webapp`:

```bash
kubectl apply -f examples/argocd-webapp-demo.yaml
make argo-app                                # or: kubectl get application webapp-demo -n argocd
kubectl port-forward -n webapp-argo svc/webapp 8082:80   # 30081 isn't host-mapped
# cleanup: kubectl delete -f examples/argocd-webapp-demo.yaml && kubectl delete ns webapp-argo
```

> **Why this beats plan-time drift detection:** Terraform only catches drift when
> someone runs `terraform plan`. Argo reconciles continuously, so unapproved
> `kubectl` changes are reverted on their own — the "approved changes only through
> Git" model. Terraform's job shrinks to day-0 platform (cluster, controllers,
> AWS bootstrap, image import).

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
