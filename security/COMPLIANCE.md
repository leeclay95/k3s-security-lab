# Compliance crosswalk — security gates → NIST SP 800-53 Rev. 5

This maps every enforced control in the lab's **three security gates** (plus the
runtime admission and audit layers they pair with) to NIST SP 800-53 Rev. 5
controls. The goal is traceability: a green gate run is automated evidence that a
specific set of controls is enforced, so the output can be pointed at an SSP/ATO.

The gates run in `scripts/security-gates.sh` (locally) and
`.github/workflows/security-gates.yml` (on every PR + push to `main`). Evidence
for each run is written under `security/reports/<UTC-timestamp>/` and uploaded as
a CI artifact.

Rationale for the mappings follows the **NSA/CISA Kubernetes Hardening Guide**
and the **CIS Kubernetes / AWS Foundations Benchmark → 800-53** crosswalks.

> **Scope note.** This is a lab. Mappings show which control *objectives* each
> check enforces at the technical layer — not a full control implementation
> (which also needs policy, process, and org-level evidence). floci emulates AWS
> locally, so the tfsec mappings describe the IaC guardrails, validated against
> the emulator rather than a real AWS account.

---

## Control coverage at a glance

| Control | Title | Enforced by |
| --- | --- | --- |
| AC-2 | Account Management | tfsec (IAM: no user-attached policies) |
| AC-3 | Access Enforcement | kubesec (ServiceAccount), tfsec (IAM, RDS IAM-auth, no public DB) |
| AC-4 | Information Flow Enforcement | conftest/Gatekeeper (hostNetwork), tfsec (no public DB) |
| AC-6 | Least Privilege | kubesec, conftest/Gatekeeper (privileged, non-root, caps), tfsec (IAM wildcards) |
| AC-6(1) | Authorize Access to Security Functions | conftest/Gatekeeper (privileged, dangerous caps), tfsec (IAM wildcards) |
| AC-6(2) | Non-Privileged Access for Nonsecurity Functions | kubesec/conftest/Gatekeeper (runAsNonRoot) |
| AC-6(9) | Log Use of Privileged Functions | k8s audit (exec/attach, RBAC) |
| AU-2 / AU-3 / AU-12 | Event Logging / Content / Generation | k8s audit policy + log shipper |
| AU-4 | Audit Log Storage Capacity | log shipper → CloudWatch (offload), audit-log-maxage |
| AU-6 | Audit Review, Analysis, Reporting | audit events queryable in CloudWatch |
| AU-9 | Protection of Audit Information | tfsec (CloudWatch CMK), audit log 0600 root |
| CM-7 | Least Functionality | kubesec (caps, seccomp), conftest/Gatekeeper (caps) |
| CP-9 | System Backup | tfsec (RDS backup retention) |
| CP-10 | System Recovery | tfsec (RDS deletion protection) |
| IA-2 | Identification and Authentication | tfsec (RDS IAM auth) |
| RA-5 / SI-2 | Vulnerability Scanning / Flaw Remediation | tfsec (ECR image scan on push) |
| SC-5 | Denial-of-Service Protection | kubesec/conftest/Gatekeeper (resource limits) |
| SC-6 | Resource Availability | kubesec (requests/limits) |
| SC-7 | Boundary Protection | conftest/Gatekeeper (host namespaces), tfsec (no public DB) |
| SC-12 | Cryptographic Key Management | tfsec (KMS rotation, CMK for SNS/SSM/ECR) |
| SC-13 | Cryptographic Protection | tfsec (encryption at rest across RDS/SNS/ECR/logs) |
| SC-28 | Protection of Information at Rest | tfsec (RDS storage, SNS, ECR, CloudWatch, SSM encryption) |
| SC-39 | Process Isolation | kubesec (seccomp/apparmor), conftest/Gatekeeper (privileged, host ns, caps) |
| SI-7 | Software / Information Integrity | kubesec (readOnlyRootFilesystem), tfsec (ECR immutable tags) |
| SI-16 | Memory Protection | kubesec/conftest/Gatekeeper (memory limits) |

---

## Gate 1 — kubesec (workload YAML scoring)

`kubesec scan` on each rendered workload; the gate fails on a negative score.
Rule IDs are kubesec's own (`.scoring.passed[].id`).

| kubesec rule | What it checks | NIST 800-53 |
| --- | --- | --- |
| `RunAsNonRoot` | container/pod `runAsNonRoot: true` | AC-6, AC-6(2), CM-7 |
| `RunAsUser` / `RunAsGroup` | high-UID/GID (avoid host UID 0 collision) | AC-6, SC-39 |
| `ServiceAccountName` | explicit SA (scoped API access, not `default`) | AC-3, AC-6 |
| `AutomountServiceAccountToken` | token automount disabled | AC-3, AC-6 |
| `CapDropAll` / `CapDropAny` | drop Linux capabilities | AC-6, CM-7, SC-39 |
| `ReadOnlyRootFilesystem` | immutable container root fs | SI-7, CM-7 |
| `SeccompAny` | seccomp profile set | CM-7, SC-39 |
| `ApparmorAny` | AppArmor profile set | AC-3, SC-39 |
| `LimitsCPU` / `LimitsMemory` | resource limits | SC-5, SC-6, SI-16 |
| `RequestsCPU` / `RequestsMemory` | resource requests (fair scheduling) | SC-6 |

## Gate 2 — tfsec (Terraform IaC, `--minimum-severity HIGH`)

Scans `terraform/` (infra + secrets + cluster). The gate fails on any finding at
HIGH or above; the table also lists the MEDIUM/LOW guardrails the config already
satisfies, since they carry the encryption/backup control objectives. Check IDs
are tfsec's `long_id`.

| tfsec check | Control objective | NIST 800-53 |
| --- | --- | --- |
| `aws-iam-no-policy-wildcards` | no `*` in IAM policy actions/resources | AC-6, AC-6(1), AC-3 |
| `aws-iam-no-user-attached-policies` | attach policies to roles/groups, not users | AC-2, AC-6 |
| `aws-rds-no-public-db-access` / `aws-rds-enable-public-access` | DB not publicly reachable | SC-7, AC-3, AC-4 |
| `aws-rds-enable-iam-auth` | IAM database authentication | IA-2, AC-3 |
| `aws-rds-encrypt-instance-storage-data` | RDS storage encrypted at rest | SC-28, SC-13 |
| `aws-rds-specify-backup-retention` | backups retained | CP-9 |
| `aws-rds-enable-deletion-protection` | guard against accidental DB loss | CP-10 |
| `aws-sns-enable-topic-encryption` / `...-use-cmk` | SNS encrypted with a CMK | SC-28, SC-13, SC-12 |
| `aws-ecr-enable-image-scans` | scan-on-push for image CVEs | RA-5, SI-2 |
| `aws-ecr-enforce-immutable-repository` | immutable image tags | SI-7 |
| `aws-ecr-repository-customer-key` | ECR encrypted with a CMK | SC-28, SC-13 |
| `aws-cloudwatch-log-group-customer-key` | audit/log data encrypted with a CMK | SC-28, AU-9 |
| `aws-ssm-secret-use-customer-key` | Secrets/SSM encrypted with a CMK | SC-28, SC-12 |
| `aws-kms-auto-rotate-keys` | KMS key rotation enabled | SC-12 |

## Gate 3 — conftest / OPA (rendered chart) + Gatekeeper twin

The conftest policies in `security/policy/deny_insecure_workloads.rego` are the
**shift-left twin** of the runtime Gatekeeper constraints — same rules, enforced
at PR time (conftest) *and* at admission time (Gatekeeper). Each rego `deny` is
annotated inline with the same controls.

| Policy (conftest deny == Gatekeeper constraint) | NIST 800-53 |
| --- | --- |
| `block-privileged` — no privileged containers | AC-6, AC-6(1), CM-7, SC-39 |
| `require-non-root` — `runAsNonRoot: true` | AC-6, AC-6(2), CM-7 |
| `require-resource-limits` — cpu + memory limits | SC-5, SC-6, SI-16 |
| `block-host-namespaces` — no hostNetwork/hostPID/hostIPC | SC-7, SC-39, AC-6 |
| `block-dangerous-caps` — no ALL/NET_RAW/SYS_ADMIN/…; drop ALL | AC-6, AC-6(1), CM-7, SC-39 |

Enforcement points:
- **conftest** (Gate 3, PR time) — blocks the merge.
- **Gatekeeper** (admission time) — blocks `kubectl apply` on a live cluster,
  scoped to the `webapp` namespace.

---

## Beyond the gates: audit logging (AU family)

The lab also ships k8s API-server audit events to CloudWatch
(`/k8s/webapp/audit`, see `docs/cloudwatch-logs.md`), which implements the audit
controls the scanners themselves don't cover:

| Capability | NIST 800-53 |
| --- | --- |
| Audit policy captures exec/attach, workload lifecycle, secret access, RBAC | AU-2, AU-3, AU-12 |
| Logging use of privileged functions (exec into pods, RBAC changes) | AC-6(9) |
| Offloading audit records off-node to CloudWatch; `audit-log-maxage` rotation | AU-4 |
| Audit records queryable via the CloudWatch Logs API | AU-6 |
| Audit log written `0600 root`; log group encrypted with a CMK | AU-9 |

---

## Keeping this current

When you add or change a gate rule, update the matching row here. The three
sources of truth are:

- `security/policy/deny_insecure_workloads.rego` — conftest policies (inline
  control comments)
- `scripts/security-gates.sh` — how each gate is invoked
- `terraform/` — the resources tfsec scans

Regenerate the current rule set anytime with:

```bash
kubesec scan <rendered-workload>.yaml            # .scoring[].id
tfsec terraform --include-passed --format json   # results[].long_id
conftest test <rendered-chart>.yaml --policy security/policy
```
