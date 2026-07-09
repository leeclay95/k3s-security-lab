# Migrate webapp ownership from Terraform to Argo CD (GitOps)

**Date:** 2026-07-08
**Status:** Implemented

## Problem

The webapp is reconciled by Terraform: the Deployment/Service are native
`kubernetes_*` resources and the rest of `charts/webapp` is a `helm_release`.
Terraform only detects and reverts drift at `terraform plan` time. The goal is
"approved changes flow through Git/Helm; any out-of-band `kubectl` edit is
reverted automatically" — which Terraform cannot do continuously, but a GitOps
reconciler (Argo CD) can.

## Decision summary

| Decision | Choice |
|---|---|
| End goal | Argo CD **fully owns** the webapp (real migration, not side-by-side) |
| Scope | Argo owns the **whole `charts/webapp` chart** (app + ESO config + Gatekeeper policies) |
| Argo + App bootstrap | **Terraform** installs Argo CD (`helm_release.argocd`) and applies the `Application` directly |
| Image delivery | **Keep** `null_resource.ecr_image_import` (Argo can't `k3d image import`) |
| Cutover | **Fresh `make deploy` only** — no in-place state surgery |
| Values source | **Committed** `charts/webapp/values-argocd.yaml` |
| Plant the Application | `null_resource` + `kubectl apply` (A1 — matches repo convention; `kubernetes_manifest` fails at plan time before the CRD exists) |
| Gatekeeper CRD ordering under Argo | **Argo sync-waves** (B1 — templates wave 0, constraints wave 1) |

## Architecture

**Ownership line:** Terraform provisions day-0 platform; Argo owns the day-1 workload.

- **Terraform (cluster root):** k3d cluster; Gatekeeper, ESO, and **Argo CD**
  controllers (`helm_release`); the webapp **image import**; and it applies the
  Argo `Application`. `infra`/`secrets` roots + floci compose unchanged.
- **Argo CD:** `Application webapp` → `charts/webapp` at `main`, values
  `values-argocd.yaml`, destination namespace `webapp`, `syncPolicy.automated`
  with `selfHeal: true` + `prune: true`. Owns Deployment, Service,
  ServiceAccount/RBAC, ConfigMap, aws-credentials Secret, ESO
  SecretStore + ExternalSecrets, and the Gatekeeper ConstraintTemplates +
  Constraints.

Every object in the `webapp` namespace has exactly one reconciler (Argo). This
is what makes drift-revert continuous instead of plan-time.

## Components changed

- **`terraform/cluster/argocd.tf`** (new): `helm_release.argocd` +
  `time_sleep.argocd_ready` + `null_resource.webapp_application` (kubectl apply
  of the Application, with a destroy provisioner and a `filesha256` trigger).
- **`terraform/cluster/webapp.tf`** (gutted): only `null_resource.ecr_image_import`
  remains. `helm_release.webapp`, the native Deployment/Service/SA/Role/
  RoleBinding, and the aws-credentials Secret are removed.
- **`terraform/cluster/outputs.tf`**: `helm_release` output replaced with
  `webapp_owner` (points at the Argo Application).
- **`argocd/webapp-application.yaml`** (new): the migration Application.
- **`charts/webapp/values-argocd.yaml`** (new): pins floci values and sets
  `gatekeeper.helmHooks: false`.
- **`charts/webapp` templates**: Gatekeeper Helm hook annotations gated behind
  `gatekeeper.helmHooks` (default `true`, so standalone `helm install` is
  unchanged); `argocd.argoproj.io/sync-wave` annotations always emitted (Helm
  ignores them). The CRD-wait Job is gated off under Argo.
- **`Makefile`**: Argo CD added to the controllers pass; `argo-app` and
  `argo-ui` targets; `status` shows the Application; `redeploy-webapp` removed.

## CRD-ordering under Argo (sync-waves)

Helm ordered ConstraintTemplates before Constraints with hooks + a wait Job.
Argo doesn't honor Helm hooks the same way, so:

- ConstraintTemplates carry `sync-wave: "0"`, Constraints `sync-wave: "1"`.
- Argo applies wave 0, gates on ConstraintTemplate health (Gatekeeper reports
  `status.created` once the generated CRD is registered), then applies wave 1.
- The `gatekeeper-crd-wait` Job is not rendered under Argo (`helmHooks: false`).

## ESO + Argo diff quirk

The ESO admission webhook defaults ExternalSecret fields absent from Git
(`target.*`, `refreshPolicy`, `remoteRef.conversionStrategy/decodingStrategy/
metadataPolicy`), which keeps the Application `OutOfSync`. Resolved with
`ignoreDifferences` using `jqPathExpressions` for those exact paths on
`ExternalSecret`. (A `managedFieldsManagers: [external-secrets]` variant was
tried first and did not clear the diff reliably.)

## Apply / sync flow (`make deploy`)

1. floci + `secrets` → `infra` → `secrets` (KMS) — unchanged bootstrap.
2. Pass 1: create the k3d cluster.
3. Pass 2: install Gatekeeper, ESO, **Argo CD** controllers.
4. Pass 3: import the webapp image, then apply the Argo `Application`.
5. Argo clones the repo and syncs `charts/webapp` into the `webapp` namespace.

## Error handling / known behaviours

- **First-sync image pull:** the Application depends on the image import, so the
  node has the image before Argo's first sync; a transient `ImagePullBackOff`
  self-heals otherwise.
- **ESO `SecretSyncedError`:** until `infra`/`secrets` exist in floci; the
  bootstrap runs first, and ESO retries.
- **Self-heal latency:** a single drift reverts within seconds; Argo applies an
  exponential self-heal backoff under repeated rapid drift (verified: 162s
  during heavy testing), always converging.
- **Repo access:** `leeclay95/k3s-security-lab` is public, so Argo clones it
  without credentials. A private repo would need an Argo repo-credential Secret.

## Verification (performed)

- `helm template` with `values-argocd.yaml`: 0 Helm hooks, 10 sync-waves;
  default values: Helm hooks preserved.
- `terraform validate`: passes.
- Live drift test via `examples/argocd-webapp-demo.yaml` (isolated `webapp-argo`
  namespace, Gatekeeper off, nodePort 30081): Application reached Synced+Healthy;
  `kubectl scale` reverted by self-heal; `kubectl delete svc` recreated by prune;
  observable in both CLI (`make argo-app`) and the Argo GUI.

## Out of scope

- In-place migration of an already-running TF-managed cluster (chose fresh
  deploy only).
- app-of-apps / multi-app Argo layout (single workload).
- Converting the `infra`/`secrets` AWS bootstrap to GitOps (stays Terraform).
