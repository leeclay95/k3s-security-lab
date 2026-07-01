# terraform/cluster — Kubernetes Cluster and Workloads

This root manages everything inside the k3d cluster: the cluster itself and three Helm releases (Gatekeeper, ESO, webapp). It is **disposable** — destroy and recreate freely without touching secrets or shared infrastructure.

---

## Two-Pass Apply

The Helm provider validates connectivity to a live cluster at **plan time**, not just apply time. On a fresh spinup the cluster does not exist yet, so the provider fails to connect and refuses to plan.

```bash
terraform init

# Pass 1 — create the cluster, give API server time to start
terraform apply -target=null_resource.k3d_cluster -target=time_sleep.cluster_ready

# Pass 2 — everything else (3 Helm releases + ECR image import)
terraform apply
```

This is not a Terraform bug — it is a fundamental constraint of providers that validate against external systems at plan time.

> **Improvement over previous setup:** The original 3-pass requirement is reduced to 2 passes. Gatekeeper policies and ESO configuration are now deployed by the webapp Helm chart with hook-based ordering, eliminating separate `kubectl apply` steps and `time_sleep` hacks between them.

---

## `cluster.tf` — k3d Cluster

### Registry config
The cluster is created with `--registry-config registries.yaml`, which configures containerd inside k3d nodes to mirror `localhost:4566` to `http://host.k3d.internal:4566`. This allows pods to reach LocalStack services via `host.k3d.internal`.

### Why `time_sleep.cluster_ready`
The k3d cluster create command returns when the cluster is created but before the API server is fully ready. A 15-second sleep prevents provider connection errors on pass 2.

---

## `gatekeeper.tf` — OPA Gatekeeper

Installs the Gatekeeper Helm chart into `gatekeeper-system` namespace. The admission webhook, ConstraintTemplates, and Constraints are deployed by the **webapp Helm chart** using hook annotations:

- ConstraintTemplates: `helm.sh/hook-weight: "0"` (installed first)
- Constraints: `helm.sh/hook-weight: "5"` (installed after templates register CRDs)

### Five active policies (all scoped to the webapp namespace)

| Constraint | Blocks |
|---|---|
| `block-privileged-containers` | `securityContext.privileged: true` |
| `require-non-root` | Missing `runAsNonRoot: true` or `runAsUser: 0` |
| `require-resource-limits` | Missing CPU or memory limits |
| `block-host-namespaces` | `hostPID`, `hostIPC`, `hostNetwork: true` |
| `block-dangerous-caps` | `SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`, `SYS_MODULE`, `DAC_OVERRIDE` |

---

## `eso.tf` — External Secrets Operator

Installs the ESO Helm chart with LocalStack endpoint configuration passed via `extraEnv` values. This replaces the previous post-install `kubectl set env` hack that was fragile across Helm upgrades.

Both endpoints are configured:
- `AWS_ENDPOINT_URL_SECRETS_MANAGER` — for secret reads
- `AWS_ENDPOINT_URL_STS` — for the `sts:AssumeRole` call

SecretStore, ExternalSecrets, and AWS credentials are deployed by the **webapp Helm chart**.

---

## `webapp.tf` — Application Workload

A single `helm_release` that deploys the local chart at `charts/webapp/`. This replaces the previous mix of:
- `kubernetes_deployment` + `kubernetes_service` + `kubernetes_namespace` (native TF resources)
- 6 `null_resource` blocks calling `kubectl apply -f` with hardcoded paths
- Multiple `time_sleep` resources for ordering

The chart includes all webapp resources: Deployment, Service, ServiceAccount, RBAC, ESO config, and Gatekeeper policies.

---

## Destroy and Recreate

```bash
# Destroy everything in this root (cluster, Gatekeeper, ESO, webapp)
terraform destroy

# Recreate — re-run the two-pass apply sequence
```

Secrets in `terraform/secrets/` and infrastructure in `terraform/infra/` are unaffected by this destroy.
