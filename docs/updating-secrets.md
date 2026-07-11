# Updating secrets the right way (Terraform → ESO → pod)

How to change a value in `webapp/secrets` so it lands in the running app, stays
consistent with Terraform state, and doesn't get reverted by ESO or Argo.

Worked example: change `secret_key` from `s3cr3t` to `s3cr3t123`.

## Why change it in Terraform (not `kubectl edit`)

The value flows through four layers, each owned by something different:

```
terraform/secrets  ──apply──►  floci Secrets Manager  ──ESO (refresh 1m)──►  k8s Secret webapp-secret  ──►  pod env vars
 (source of truth)              (webapp/secrets)                              (ESO-owned, creationPolicy:Owner)   (fixed at start)
```

- **`kubectl edit secret webapp-secret`** does nothing lasting — ESO owns that
  Secret and overwrites it back from floci on the next refresh.
- **Raw `aws secretsmanager put-secret-value`** works immediately but **drifts
  from Terraform** — the next `terraform apply` / `make deploy` reverts it.
- **Terraform** is the source of truth. Applying updates floci *and* keeps state
  in sync, so nothing reverts it later.

Argo is not involved: `webapp-secret`'s data isn't Git-declared (ESO generates
it), and the `ExternalSecret` spec doesn't change — so no drift, no selfHeal.

## ⚠️ The trap: pass ALL THREE values every time

`terraform/secrets` builds one JSON secret from three variables:

```hcl
secret_string = jsonencode({
  db_password = var.db_password
  api_key     = var.api_key
  secret_key  = var.secret_key
})
```

and their **defaults do not match the deployed values**:

| var | default in `variables.tf` | deployed value |
|---|---|---|
| `db_password` | `password123` | `hunter2` |
| `api_key` | `supersecretkey` | `abc123` |
| `secret_key` | `s3cr3t-hardcoded-value` | `s3cr3t` |

If you pass only `secret_key`, the other two fall back to their (wrong)
defaults and get clobbered. **Always pass all three** — only change the one you
mean to.

## Step 1 — apply with Terraform

```bash
cd /home/kali/floci/k3-test

# KMS ARN that secrets/ needs, from the infra root's output
KMS=$(terraform -chdir=terraform/infra output -raw kms_key_arn)

# change only secret_key; keep db_password + api_key at their deployed values
terraform -chdir=terraform/secrets apply -var="kms_key_arn=$KMS" -var="db_password=hunter2" -var="api_key=abc123" -var="secret_key=s3cr3t123"
```

### The plan will show a REPLACE — that's expected and safe

```
-/+ aws_secretsmanager_secret_version.webapp must be replaced
      ~ secret_string = (sensitive value) # forces replacement
Plan: 1 to add, 0 to change, 1 to destroy.
```

Only the **version** is replaced, not the secret. `aws_secretsmanager_secret.webapp`
is absent from the plan, so its `prevent_destroy` never fires and the ARN stays
the same — Terraform just cycles the value into a new `AWSCURRENT` version.
(Newer AWS providers treat `secret_string` as write-only and force replacement
instead of in-place update; same result.) Type `yes`.

## Step 2 — propagate to the cluster and verify

```bash
# nudge ESO to resync now instead of waiting up to its 1m refreshInterval
kubectl --context k3d-webapp-test -n webapp annotate externalsecret webapp-secrets force-sync="$(date +%s)" --overwrite

# the generated k8s Secret now holds the new value
kubectl --context k3d-webapp-test -n webapp get secret webapp-secret -o jsonpath='{.data.secret_key}' | base64 -d; echo
#   expect: s3cr3t123
```

If it still shows the old value, ESO hasn't reconciled yet — give it ~5–10s.

## Step 3 — roll the pod so the app picks it up

The app reads the secret via env vars (`secretKeyRef`), which are set at
container start and are **not** live-updated. Restart to apply:

```bash
kubectl --context k3d-webapp-test -n webapp rollout restart deployment/webapp
kubectl --context k3d-webapp-test -n webapp rollout status deployment/webapp

# prove the running container sees it
kubectl --context k3d-webapp-test -n webapp exec deploy/webapp -- printenv SECRET_KEY
#   expect: s3cr3t123
```

(A mounted secret *volume* would refresh in ~60s without a restart; env vars do
not — hence the rollout.)

## Recap

1. `terraform -chdir=terraform/secrets apply` with **all three** `-var` values (only the target changed).
2. `yes` at the plan — a version REPLACE is normal; the secret itself is untouched.
3. `annotate externalsecret ... force-sync=...` → ESO writes `webapp-secret`.
4. `get secret webapp-secret` → confirm the new value.
5. `rollout restart deployment/webapp` → the app env reflects it.

Durable, consistent with state, and nothing reverts it. To change `db_password`
or `api_key` instead, use the same flow — just move the new value to that
`-var` and keep the others at their deployed values.
