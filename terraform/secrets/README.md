# terraform/secrets — Persistent Secrets

This root manages Secrets Manager secrets. It is intentionally **separate from the cluster root** so that secrets survive `terraform destroy` on the cluster. Cluster infrastructure is disposable; secrets are not.

```bash
# First apply — no KMS yet (infra/ hasn't run)
terraform init
terraform apply -var="db_password=hunter2" -var="api_key=abc123" -var="secret_key=s3cr3t"

# After terraform/infra/ has been applied — add KMS encryption
terraform apply \
  -var="kms_key_arn=$(cd ../infra && terraform output -raw kms_key_arn)" \
  -var="db_password=hunter2" \
  -var="api_key=abc123" \
  -var="secret_key=s3cr3t"
```

---

## Why a Separate Root

Terraform state is scoped to the root where it is declared. If secrets lived in `terraform/cluster/`, then `terraform destroy` on the cluster would destroy the secrets. On a fresh cluster spinup you would need to rotate all credentials.

By keeping secrets in their own root with `prevent_destroy = true`, you can destroy and recreate the cluster as many times as needed — the secrets remain and ESO picks them up immediately on the new cluster.

This mirrors the separation in real environments between:
- **Control plane infrastructure** (clusters, compute) — ephemeral, frequently recycled
- **Data plane resources** (secrets, databases, S3 buckets) — persistent, never accidentally destroyed

---

## `webapp/secrets` — `main.tf`

Contains: `db_password`, `api_key`, `secret_key`

These are the application runtime secrets. They are stored as a single JSON blob in Secrets Manager and ESO's `ExternalSecret` extracts individual keys into a K8s Secret (`webapp-secret`).

### Why `recovery_window_in_days = 0`
AWS Secrets Manager normally enforces a 7–30 day deletion window before a secret can be recreated with the same name. In a lab environment where you may destroy and recreate frequently, this would block `terraform apply` with a `ResourceExistsException`. Setting it to 0 allows immediate deletion and recreation.

In production, use the default (30 days) or at minimum 7 days — the deletion window is a recovery mechanism against accidental or malicious deletion.

### Why `prevent_destroy = true`
Terraform's `lifecycle.prevent_destroy` causes `terraform destroy` to error rather than delete this resource. This is an explicit safeguard. If you actually need to delete the secret, you must remove this lifecycle block first — forcing a deliberate, conscious action.

### KMS encryption
When `kms_key_arn` is provided (after `terraform/infra/` is applied), the secret is encrypted with the CMK. Without a CMK, Secrets Manager uses AWS-managed encryption. The CMK adds:
- Explicit key policy control
- The ability to immediately revoke access by disabling the key
- Audit logs for every decrypt operation

---

## Variables

| Variable | Required | Description |
|---|---|---|
| `kms_key_arn` | No (defaults to `""`) | CMK ARN from `terraform/infra` output. Empty means AWS-managed key. |
| `db_password` | Yes | Stored in `webapp/secrets` and passed to the webapp pod via ESO |
| `api_key` | Yes | Application API key |
| `secret_key` | Yes | Application session/signing key |

No defaults are provided for credential variables — they must be passed explicitly on every apply. This prevents accidentally applying with placeholder values.
