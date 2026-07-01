# Helm + Terraform Integration — End-to-End

How the k3s security lab's Kubernetes layer is deployed, how Helm and Terraform divide
ownership, and specifically how `terraform apply` is able to detect and correct live
edits made directly against the cluster (e.g. `kubectl edit`, `kubectl patch`).

---

## 1. Layer overview

```
terraform/infra     → LocalStack AWS resources (KMS, IAM, ECR, RDS, CloudWatch, SNS)
terraform/secrets   → LocalStack Secrets Manager secrets
terraform/cluster   → k3d cluster + Gatekeeper + ESO + webapp   ← this directory
```

`terraform/cluster` is disposable: destroy and recreate freely, infra/secrets are untouched.

Inside this root, three things happen in order:

1. **k3d cluster** created directly by `null_resource` + `local-exec` (not a real Terraform-managed
   resource — k3d has no Terraform provider)
2. **Gatekeeper** and **External Secrets Operator (ESO)** installed as Helm releases
3. **webapp** installed as a Helm release for everything CRD-dependent (`SecretStore`,
   `ExternalSecret`s, Gatekeeper `ConstraintTemplate`/`Constraint`), while the Deployment,
   Service, ServiceAccount, RBAC (Role/RoleBinding), and the `aws-credentials` Secret are
   all native Terraform `kubernetes_*` resources instead

That split is the answer to "how does Terraform catch live edits" — see §4.

---

## 2. Apply order / dependency graph

```
null_resource.k3d_cluster
        │
time_sleep.cluster_ready (15s — API server warm-up)
        │
        ├──> helm_release.gatekeeper ──> time_sleep.gatekeeper_ready (15s)
        │
        ├──> helm_release.eso ─────────> time_sleep.eso_ready (10s)
        │
        └──> null_resource.ecr_image_import (k3d image import, sideloads the ECR image
             into containerd so the cluster never pulls from LocalStack's registry at runtime)
                        │
        (all of the above) ──> helm_release.webapp ──┬──> kubernetes_service_account.webapp
                                                       ├──> kubernetes_role.webapp
                                                       ├──> kubernetes_role_binding.webapp (needs SA + Role)
                                                       ├──> kubernetes_secret.aws_credentials
                                                       ├──> kubernetes_service.webapp
                                                       └──> kubernetes_deployment.webapp (needs SA)
```

Two-pass apply is required because the Helm/Kubernetes providers validate connectivity
against a live cluster at **plan time**, and the cluster doesn't exist yet on a fresh run:

```bash
terraform init
terraform apply -target=null_resource.k3d_cluster -target=time_sleep.cluster_ready   # pass 1
terraform apply                                                                       # pass 2
```

---

## 3. What each file does

| File | Resource(s) | Purpose |
|---|---|---|
| `providers.tf` | `helm`, `kubernetes`, `null`, `time` provider blocks | `helm` and `kubernetes` both point at the `k3d-webapp-test` kubeconfig context |
| `cluster.tf` | `null_resource.k3d_cluster`, `time_sleep.cluster_ready` | Creates the k3d cluster via `local-exec` (`k3d cluster create ... --port 8080:80@loadbalancer --port 30080:30080@server:0`); the second port mapping exposes the webapp's NodePort to the host |
| `gatekeeper.tf` | `helm_release.gatekeeper`, `time_sleep.gatekeeper_ready` | Installs the Gatekeeper controller only (`gatekeeper-system` namespace). The actual policies live in the webapp chart, not here |
| `eso.tf` | `helm_release.eso`, `time_sleep.eso_ready` | Installs the ESO controller with `extraEnv` values pointing `AWS_ENDPOINT_URL_SECRETS_MANAGER` / `AWS_ENDPOINT_URL_STS` at `http://host.k3d.internal:4566` (LocalStack) |
| `webapp.tf` | `null_resource.ecr_image_import`, `helm_release.webapp`, `kubernetes_deployment.webapp`, `kubernetes_service.webapp`, `kubernetes_service_account.webapp`, `kubernetes_role.webapp`, `kubernetes_role_binding.webapp`, `kubernetes_secret.aws_credentials` | See §4 — split-ownership deploy of the application |
| `outputs.tf` | — | `app_url`, `helm_release` name |

---

## 4. The webapp: split ownership between Helm and Terraform

### The problem this solves

`helm_release` in Terraform does **not** do object-level drift detection. `terraform plan`
only compares:

- the config attributes you wrote (`chart`, `set{}` blocks, `namespace`, `timeout`, …), and
- the release metadata Helm itself reports (revision, status, recorded values)

against Terraform state. It never reads the live Deployment/Service/etc. and diffs it
against the rendered chart. So if you `kubectl edit deployment webapp` and add a
capability, `terraform plan` reports "No changes" — nothing it tracks actually changed.
Helm *does* reconcile that drift, but only when something explicitly triggers a new
`helm upgrade` (a real config diff, or a manual `helm upgrade` command) — Terraform never
decides to call it on its own for out-of-band edits. (An experimental Helm provider
setting was tried here first and rejected — see §4's "provider bugs" below.)

Terraform's native `kubernetes_*` resources (`kubernetes_deployment`, `kubernetes_service`,
etc.) don't have this gap — they're typed resources that Terraform reads directly from the
Kubernetes API on every `plan`/`refresh` and diffs field-by-field. This is exactly how the
project's original pre-Helm design caught live edits.

### The fix — the `enabled` flag pattern

Every resource that's a plain built-in Kubernetes type (not a CRD) was pulled out of Helm's
ownership and given to Terraform directly, using the same pattern each time:

1. The chart template gets wrapped in `{{- if .Values.<name>.enabled }} ... {{- end }}`.
   Default is `true` in `values.yaml`, so the chart stays complete and self-contained for
   anyone running `helm install`/`helm template` standalone, outside Terraform.
2. `webapp.tf`'s `helm_release.webapp` sets that value to `"false"`, so when Terraform
   installs the chart, it deliberately excludes that resource.
3. `webapp.tf` defines the matching native `kubernetes_*` resource, `depends_on =
   [helm_release.webapp]` (needs the namespace, which the chart creates via
   `create_namespace = true`).

Applied to five resources:

| Resource | Chart template | Values flag | Native Terraform resource |
|---|---|---|---|
| Deployment | `templates/deployment.yaml` | `deployment.enabled` | `kubernetes_deployment.webapp` |
| Service | `templates/service.yaml` | `service.enabled` | `kubernetes_service.webapp` |
| ServiceAccount + Role + RoleBinding | `templates/serviceaccount.yaml` | `serviceAccount.enabled` | `kubernetes_service_account.webapp`, `kubernetes_role.webapp`, `kubernetes_role_binding.webapp` |
| `aws-credentials` Secret | `templates/eso-aws-credentials.yaml` | `awsCredentialsSecret.enabled` | `kubernetes_secret.aws_credentials` |

Everything CRD-backed — `SecretStore`, `ExternalSecret`s, the Gatekeeper
`ConstraintTemplate`/`Constraint` objects — stays chart-managed via `helm_release.webapp`.
Converting those would mean `kubernetes_manifest`, which validates against live CRDs at
**plan time**, reintroducing the 3-pass fragility this design avoids (see §5's CRD race
for what happens when CRD timing goes wrong even *inside* a single Helm release — doing
the same thing across Terraform resource boundaries is worse, not better).

### Two provider bugs hit along the way

- **`experiments { manifest = true }`** (a Helm provider setting) was tried first and
  rejected — it only tracks whether the *rendered chart output* changed between applies,
  not whether the *live cluster objects* drifted from that render. Doesn't help.
- **Zero-permission `Role`** (`rules: []`) couldn't be expressed cleanly:
  - `kubernetes_role` requires at least one `rule` block — no way to set zero rules.
  - `kubernetes_manifest` can express `rules: []` literally, but its provider crashed
    (`provider produced inconsistent result after apply`) round-tripping the empty list.
  - A `kubernetes_role` `rule` block with all-empty `api_groups`/`resources`/`verbs` lists
    also **crashed the provider entirely** (`terraform-provider-kubernetes_v2.38.0 plugin
    crashed!`) — a confirmed bug with all-empty list attributes in nested blocks, not just
    a validation error.
  - Landed on the narrowest rule the provider will actually apply without crashing:
    read-only access to `events` in the `webapp` namespace. `nginx` never calls the K8s
    API regardless, so this is unused in practice — same real-world security posture as
    `rules: []`, just not byte-identical.

### Verified behavior

```bash
# Deployment
kubectl patch deployment webapp -n webapp --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/securityContext/capabilities/add","value":["SYS_ADMIN"]}]'

# Service
kubectl patch svc webapp -n webapp --type=json \
  -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":31111}]'

# ServiceAccount
kubectl patch serviceaccount webapp-sa -n webapp --type=json \
  -p='[{"op":"replace","path":"/automountServiceAccountToken","value":true}]'

# aws-credentials Secret
kubectl patch secret aws-credentials -n webapp \
  -p="{\"data\":{\"access-key\":\"$(echo -n hacked | base64)\"}}"

terraform plan   # → each drifted resource shown as "will be updated in-place" with the
                 #   exact field-level diff (e.g. capabilities.add: ["SYS_ADMIN"] -> [],
                 #   node_port: 31111 -> 30080, automount_service_account_token: true -> false)

terraform apply  # → reverts all of it

terraform plan   # → "No changes. Your infrastructure matches the configuration."
```

---

## 5. Gatekeeper policy ordering — the CRD race, and its fix

Gatekeeper policies are deployed as Helm **hooks** inside the webapp chart:

- `gatekeeper-templates.yaml` — 5 `ConstraintTemplate`s, `helm.sh/hook: post-install,post-upgrade`,
  `helm.sh/hook-weight: "0"`
- `gatekeeper-constraints.yaml` — 5 `Constraint`s (one per template), same hooks,
  `helm.sh/hook-weight: "5"`

**The bug:** applying a `ConstraintTemplate` causes the Gatekeeper controller to dynamically
provision a backing CRD (e.g. `k8sblockprivileged.constraints.gatekeeper.sh`). Helm's default
hook behavior deletes a hook resource before recreating it on every `helm upgrade`. That
deletion — and the CRD teardown/recreation it triggers — is asynchronous. If the
weight-5 `Constraint` hook fires before the weight-0 CRD has finished re-provisioning, the
API server rejects it:

```
Error: k8sblockprivileged.constraints.gatekeeper.sh "block-privileged-containers" is
forbidden: create not allowed while custom resource definition is terminating
```

This was hit repeatedly during `helm upgrade`/`terraform apply` retries, and at one point
left the cluster with only 2 of 5 Constraints actually present (weight-0 template hooks
succeeded, weight-5 constraint hooks partially failed) — a real, temporary gap in policy
enforcement, not just a Helm bookkeeping issue.

**The fix:** `charts/webapp/templates/gatekeeper-crd-wait.yaml` — a `Job` hook at
`helm.sh/hook-weight: "3"` (between the templates and constraints) that just runs
`sleep 10`. Helm waits for hook Jobs to complete before moving to the next weight, so this
guarantees a 10-second gap for the CRDs to settle. This mirrors the fixed 10-second
`time_sleep.crds_ready` wait the pre-Helm design used for the same purpose — just
implemented as a Helm hook instead of a Terraform resource, since the CRD-dependent
ordering now happens *inside* a single Helm release rather than across Terraform resources.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: webapp-gatekeeper-crd-wait
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "3"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: wait
          image: busybox:1.36
          command: ["sleep", "10"]
```

Verified with a real `helm upgrade` against an already-deployed release (the exact
scenario that used to race) — completed cleanly, all 5 Constraints intact.

---

## 6. Current Terraform-managed resources

```
$ terraform state list
helm_release.eso
helm_release.gatekeeper
helm_release.webapp
kubernetes_deployment.webapp
kubernetes_role.webapp
kubernetes_role_binding.webapp
kubernetes_secret.aws_credentials
kubernetes_service.webapp
kubernetes_service_account.webapp
null_resource.ecr_image_import
null_resource.k3d_cluster
time_sleep.cluster_ready
time_sleep.eso_ready
time_sleep.gatekeeper_ready
```

---

## 7. What Terraform will and won't catch

| Edit made via `kubectl` to... | Does `terraform plan` see it? |
|---|---|
| The webapp `Deployment` (image, securityContext, resources, env, probes) | **Yes** — native `kubernetes_deployment` resource |
| The webapp `Service` (type, ports, `nodePort`, selector) | **Yes** — native `kubernetes_service` resource |
| `ServiceAccount` (`automountServiceAccountToken`, labels) | **Yes** — native `kubernetes_service_account` resource |
| `Role` / `RoleBinding` (rules, subjects, roleRef) | **Yes** — native `kubernetes_role` / `kubernetes_role_binding` resources |
| `aws-credentials` Secret (values) | **Yes** — native `kubernetes_secret` resource |
| `SecretStore`, `ExternalSecret`s | No — CRD-backed, stays chart-managed via `helm_release.webapp`, only reconciled on a real `helm upgrade` |
| Gatekeeper `ConstraintTemplate`/`Constraint` content | No — same reason (CRD-backed) |
| Gatekeeper/ESO controller settings (Helm values for those charts) | No — `helm_release.gatekeeper`/`helm_release.eso` have the same non-drift-detecting behavior as any `helm_release` |

Every plain built-in Kubernetes resource type in this chart is now Terraform-native and
drift-detected. What's left un-detected is specifically the CRD-backed resources and the
two controller installs — both a deliberate tradeoff (see §4's "two provider bugs" and
§5's CRD race) rather than an oversight. If similar drift-detection is ever needed for
another chart-managed resource, the same pattern applies: add an `enabled` flag to gate it
out of the chart, and define it as the matching native `kubernetes_*` Terraform resource
instead — as long as it isn't a CRD type.

---

## 8. Quick reference

```bash
# Full fresh apply (2-pass, from an empty cluster)
terraform apply -target=null_resource.k3d_cluster -target=time_sleep.cluster_ready
terraform apply

# Detect + fix drift on any Terraform-native resource (Deployment, Service,
# ServiceAccount, Role, RoleBinding, aws-credentials Secret)
terraform plan
terraform apply

# Force the remaining Helm-managed resources (SecretStore, ExternalSecrets,
# Gatekeeper policies) to reconcile — terraform apply alone won't trigger
# this unless a real config diff exists
helm upgrade webapp ../../charts/webapp -n webapp \
  --set image.repository=000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100/webapp/nginx \
  --set image.tag=1.27 \
  --set deployment.enabled=false \
  --set service.enabled=false \
  --set serviceAccount.enabled=false \
  --set awsCredentialsSecret.enabled=false

# Tear down (cluster, Gatekeeper, ESO, webapp — infra/secrets untouched)
terraform destroy
```
