# terraform/cluster — Kubernetes Cluster and Workloads

This root manages everything inside the k3d cluster: the cluster itself, Helm charts, OPA Gatekeeper policies, ESO wiring, RBAC, and the webapp deployment. It is **disposable** — destroy and recreate freely without touching secrets or shared infrastructure.

---

## Three-Pass Apply Requirement

The Helm and Kubernetes Terraform providers validate connectivity to a live cluster at **plan time**, not just apply time. On a fresh spinup the cluster does not exist yet, so providers fail to connect and refuse to plan.

The solution is staged `-target` applies:

```bash
terraform init

# Pass 1 — create the cluster, give API server time to start
terraform apply -target=null_resource.k3d_cluster -target=time_sleep.cluster_ready

# Pass 2 — install Helm charts now that providers can connect
terraform apply -target=helm_release.gatekeeper -target=helm_release.eso -target=null_resource.eso_endpoint -target=time_sleep.eso_ready -target=time_sleep.gatekeeper_ready

# Pass 3 — remaining resources (policies, webapp, ESO config)
terraform apply
```

This is not a Terraform bug — it is a fundamental constraint of providers that validate against external systems at plan time.

---

## Why `null_resource` + kubectl Instead of `kubernetes_manifest`

The `kubernetes_manifest` provider resource validates all manifests against live CRDs at plan time. This creates a three-layer chicken-and-egg problem:

1. Gatekeeper Helm chart installs the Gatekeeper CRDs
2. ConstraintTemplates must be applied after those CRDs exist
3. Constraints reference CRDs that ConstraintTemplates create dynamically — not present until templates are applied

`kubernetes_manifest` fails at plan time for steps 2 and 3 because the CRDs it needs to validate against do not exist yet. Using `null_resource` + `local-exec` + `kubectl apply -f` bypasses plan-time validation entirely — kubectl applies the manifest at apply time when the CRDs are present.

The same applies to ESO resources (SecretStore, ExternalSecret) — their CRDs are installed by the ESO Helm chart and do not exist at plan time.

---

## `cluster.tf` — k3d Cluster

### Registry config
The cluster is created with `--registry-config registries.yaml`, which configures containerd inside k3d nodes to mirror `localhost:4566` to `http://host.k3d.internal:4566`. This allows pods to reach LocalStack services via `host.k3d.internal` — the hostname k3d injects into CoreDNS that resolves to the Docker host.

### Why `time_sleep.cluster_ready`
The k3d cluster create command returns when the cluster is created but before the API server is fully ready to accept connections. A 15-second sleep after cluster creation prevents provider connection errors on pass 2.

---

## `gatekeeper.tf` — OPA Gatekeeper

### What Gatekeeper does
Gatekeeper installs a validating admission webhook. Every `kubectl apply` that creates or updates a Pod goes through the webhook. Gatekeeper evaluates the pod spec against all active Constraints and rejects it if any policy is violated. The rejection happens server-side — no client-side tool can bypass it.

### Five active policies (all scoped to `namespaces: [webapp]`)

| Constraint | Blocks |
|---|---|
| `block-privileged` | `securityContext.privileged: true` |
| `require-non-root` | Missing `runAsNonRoot: true` or `runAsUser: 0` |
| `require-resource-limits` | Missing CPU or memory limits |
| `block-host-namespaces` | `hostPID`, `hostIPC`, `hostNetwork: true` |
| `block-dangerous-caps` | `SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`, `SYS_MODULE`, `DAC_OVERRIDE` |

### Why namespace-scoped, not cluster-wide
ESO, Gatekeeper, and other system components ship without resource limits in their Helm charts. A cluster-wide `require-resource-limits` constraint would block them from starting. Scoping to `namespaces: [webapp]` enforces the policy where it matters — on application workloads — without breaking operators.

### Why two separate files (templates vs constraints)
`gatekeeper-templates.yaml` must be applied first. ConstraintTemplates create the CRDs (e.g., `K8sBlockPrivileged.constraints.gatekeeper.sh`) dynamically via Gatekeeper's CRD generation mechanism. Constraints reference those CRDs. If both files are applied together, the Constraint CRDs do not exist yet when the Constraints are processed. The 10-second `time_sleep.crds_ready` between the two apply steps gives Gatekeeper time to register the generated CRDs.

---

## `eso.tf` — External Secrets Operator

### ESO v1 API
ESO v2.7 uses `apiVersion: external-secrets.io/v1`. The previous `v1beta1` API no longer exists in this version — applying manifests with the old apiVersion returns a "no matches for kind" error.

### Why the endpoint is set via `kubectl set env`, not Helm values
The ESO Helm chart's `set {}` blocks for environment variables (`env[0].name = "..."`) do not actually propagate into the controller deployment. This is a known issue with how the ESO chart handles env var injection. The only reliable method is to patch the deployment directly after Helm installs it:

```bash
kubectl set env deployment/external-secrets -n external-secrets \
  AWS_ENDPOINT_URL_SECRETS_MANAGER=http://host.k3d.internal:4566 \
  AWS_ENDPOINT_URL_STS=http://host.k3d.internal:4566
```

Both endpoints are needed: `AWS_ENDPOINT_URL_SECRETS_MANAGER` for secret reads, and `AWS_ENDPOINT_URL_STS` for the `sts:AssumeRole` call that the IAM role assumption flow requires.

### SecretStore role assumption
The `SecretStore` manifest includes `role: arn:aws:iam::000000000000:role/eso-role`. ESO uses the static credentials in `aws-credentials` K8s Secret to call `sts:AssumeRole`, then uses the resulting temporary credentials to call Secrets Manager. This is the same pattern as IRSA on real EKS — the difference is the authentication token source (OIDC vs static key).

---

## `webapp.tf` — Application Workload

### Security controls on the deployment

| Control | Setting | Why |
|---|---|---|
| Image | ECR URI with immutable tag | Private registry, no public pull, tag cannot be overwritten |
| `imagePullPolicy` | `IfNotPresent` | Image preloaded via `k3d image import`; cluster does not pull at runtime |
| `runAsNonRoot` | `true` | Process cannot run as UID 0 even if the image is misconfigured |
| `runAsUser` / `runAsGroup` | `101` | Matches `nginx-unprivileged` expected UID; explicit rather than inherited |
| `privileged` | `false` | Cannot access host devices or kernel capabilities |
| `allowPrivilegeEscalation` | `false` | `setuid`/`setgid` binaries cannot gain privileges |
| `readOnlyRootFilesystem` | `true` | No writes to container filesystem; tmpfs mounts for `/tmp`, `/var/cache/nginx`, `/var/run` |
| `capabilities.drop` | `ALL` | No Linux capabilities; nginx-unprivileged requires none |
| `seccompProfile` | `RuntimeDefault` | System call filtering via the container runtime's default seccomp profile |
| `automountServiceAccountToken` | `false` | No K8s API token injected into the container |
| CPU/memory limits | Set | Required by Gatekeeper; prevents resource exhaustion |

### Why `serviceAccountName: webapp-sa` with an empty Role
nginx serves static content and has no reason to call the Kubernetes API. The `webapp-sa` ServiceAccount is bound to `webapp-role`, which has `rules: []` — zero permissions. The `automountServiceAccountToken: false` on both the SA and the deployment spec ensures no JWT token is injected at `/var/run/secrets/kubernetes.io/serviceaccount/`. A compromised container cannot use the token to enumerate or modify cluster resources.

### Why `kubernetes_role` is not used for the zero-permission Role
The Kubernetes Terraform provider rejects `rules = []` as invalid even though it is valid Kubernetes. The `null_resource` + `kubectl apply -f serviceaccount.yaml` pattern bypasses provider-level validation.

### Secrets injection
The deployment does not contain any credential values. All three env vars (`SECRET_KEY`, `DB_PASSWORD`, `DB_URL`) reference K8s Secrets created and managed by ESO. If a credential is rotated in Secrets Manager, ESO updates the K8s Secret within the `refreshInterval` (1 minute), and a pod restart picks up the new value.

---

## Destroy and Recreate

```bash
# Destroy everything in this root (cluster, Gatekeeper, ESO, webapp)
terraform destroy

# Recreate — re-run the three-pass apply sequence
```

Secrets in `terraform/secrets/` and infrastructure in `terraform/infra/` are unaffected by this destroy.
