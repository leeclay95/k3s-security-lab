# terraform/infra — Shared Cloud Infrastructure

This root provisions all AWS infrastructure that is **shared across cluster lifecycles**. It is applied once and survives `terraform destroy` on the cluster root. Resources here have no `prevent_destroy` because they can be recreated without data loss — secrets live in `terraform/secrets/`, not here.

Apply this root **after** `terraform/secrets/` so the IAM policy can resolve exact secret ARNs via data source.

```bash
terraform init
terraform apply -var="db_password=hunter2"
terraform output kms_key_arn   # pass to terraform/secrets/ on next apply
```

---

## KMS — `kms.tf`

### What it creates
- Customer-managed CMK (CMK) with 7-day deletion window and automatic key rotation
- Alias `alias/webapp-secrets`

### Why a CMK over AWS-managed keys
AWS-managed keys (`aws/secretsmanager`) are controlled by AWS. A CMK gives you:
- **Explicit key policy control** — you decide exactly which principals can encrypt/decrypt
- **Audit trail** — every use of the key appears in CloudTrail (and CloudWatch Logs locally)
- **Cross-service reuse** — the same CMK encrypts Secrets Manager, RDS, and SNS in this lab, reducing key sprawl

The CMK is used as the encryption key for the SNS topic, RDS instance, and Secrets Manager secrets. Any caller without `kms:Decrypt` permission is denied the secret value even with valid IAM credentials.

---

## IAM — `iam.tf`

### What it creates
- `eso-user` IAM user — access key with **only** `sts:AssumeRole` permission
- `eso-role` IAM role — `GetSecretValue` and `DescribeSecret` on the two exact secret ARNs, `kms:Decrypt` on the CMK

### Why role assumption instead of static credentials
The original setup used `access_key: test / secret_key: test` root credentials stored in a K8s Secret. Any process that could read the K8s Secret had full LocalStack access.

With role assumption:
1. `eso-user` static creds can only call `sts:AssumeRole` — useless for anything else
2. ESO assumes `eso-role` and gets short-lived temporary credentials
3. Those temp creds are scoped to exactly two secret ARNs — if ESO is compromised, the blast radius is two secrets, nothing else

This mirrors AWS IRSA (IAM Roles for Service Accounts) on EKS, where pods get OIDC-issued tokens rather than static keys. The pattern is identical; the authentication mechanism differs.

### Why exact ARNs instead of `webapp/*`
tfsec flags wildcard resources on sensitive actions as HIGH severity. A `webapp/*` resource would silently grant access to any secret created under that path in the future — a privilege escalation risk. Pinning to exact ARNs means adding a new secret requires a deliberate IAM policy update.

The `webapp/secrets` ARN is resolved via a `data "aws_secretsmanager_secret"` lookup, which is why `terraform/secrets/` must be applied first.

---

## ECR — `ecr.tf`

### What it creates
- ECR repository `webapp/nginx` with immutable tags and scan-on-push enabled
- `null_resource` that pulls the upstream image, retags it with the ECR URI, authenticates, and pushes

### Why immutable tags
`MUTABLE` tags allow overwriting `:1.27` with a different image silently. Any pipeline with push access could replace a known-good image with a backdoored one and every pod restart would pull it. `IMMUTABLE` makes tags write-once — deploying a new image requires a new tag, leaving a visible audit trail.

### Why a private registry over Docker Hub
- **Access control** — IAM policy controls who can push and pull; public registries have no such gate
- **Supply chain** — in production, images are scanned by ECR before pods can pull them (`scan_on_push = true`)
- **Air-gap readiness** — a private registry works in network-restricted environments where Docker Hub is blocked

### LocalStack specifics
LocalStack ECR exposes two endpoints:
- `localhost:4566` — the ECR API (CreateRepository, GetAuthorizationToken)
- `000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100` — the Docker registry for push/pull

`localhost.localstack.cloud` resolves to `127.0.0.1` via public DNS, so no `/etc/hosts` changes are required. Pushing to `:4566` returns 404; the correct push target is port 5100.

Images are imported into k3d nodes via `k3d image import` rather than pulled at runtime, because k3d node containers cannot reach `localhost.localstack.cloud:5100` on the host without additional registry mirror configuration.

---

## RDS — `rds.tf`

### What it creates
- Postgres 13.7 RDS instance `webapp-db`
- `webapp/db-credentials` Secrets Manager secret containing the full connection string, KMS-encrypted

### Why storage encryption
Unencrypted RDS storage means any EBS snapshot or storage-level compromise exposes all data. `storage_encrypted = true` with the CMK means decryption requires both the KMS key policy and IAM access — two independent controls.

### Why the connection string lives in Secrets Manager
The pod needs `DB_URL` but the manifest should never contain credentials. ESO syncs `webapp/db-credentials` into `webapp-db-secret` K8s Secret, and the deployment references `secretKeyRef`. The credential never appears in:
- The Terraform manifest
- Git history
- Pod spec (`kubectl get pod -o yaml`)
- Environment variable files on disk

The only place the plaintext credential exists is in Secrets Manager and in the running container's memory.

### LocalStack limitations
- `AddTagsToResource` is not supported for RDS in LocalStack community — `tags` block is omitted
- The RDS endpoint (`localhost:7001`) is not reachable from inside the k3d cluster because from within pod network, `localhost` is the pod itself. The secret is synced and the pattern is proven; actual DB connectivity would require a real endpoint or a network bridge.

---

## Monitoring — `monitoring.tf`

### What it creates
- CloudWatch log group `/k8s/webapp/audit` (30-day retention) — for Gatekeeper denial events
- CloudWatch log group `/k8s/webapp/app` (14-day retention) — for application logs
- SNS topic `webapp-security-alerts` with KMS encryption
- CloudWatch alarm `gatekeeper-policy-violations` — fires when `GatekeeperDenials` custom metric is >= 1

### Why SNS encryption
Alert messages contain context about what was blocked — pod names, namespace, image names. This is sensitive operational data. KMS-encrypting the SNS topic ensures messages are protected in transit through the SNS pipeline.

### Why the log metric filter is missing
`PutMetricFilter` is not supported in LocalStack community edition. In production this filter would parse Gatekeeper `FailedCreate` events from the audit log group and publish the `GatekeeperDenials` custom metric that feeds the alarm. The alarm resource is present and wired to the SNS topic; the metric source is the gap.

### Production wiring
In a real environment the alerting pipeline is:
```
kubectl events (FailedCreate) → Fluent Bit → CloudWatch Logs
→ Log Metric Filter → GatekeeperDenials metric → CloudWatch Alarm
→ SNS topic → email / PagerDuty / Slack webhook
```

---

## Outputs

| Output | Used by |
|---|---|
| `kms_key_arn` | Pass to `terraform/secrets/` as `kms_key_arn` variable |
| `eso_role_arn` | Referenced in `eso-secretstore.yaml` `role:` field |
| `ecr_repository_url` | Referenced in deployment image field |
| `rds_endpoint` | Embedded in `webapp/db-credentials` secret string |
| `sns_topic_arn` | CloudWatch alarm action |
