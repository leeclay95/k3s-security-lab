# Runtime image scanning (Trivy Operator)

Continuously scan what is **actually running** in the cluster with
[Trivy Operator](https://github.com/aquasecurity/trivy-operator), installed as a
Helm release by [`terraform/cluster/trivy-operator.tf`](../terraform/cluster/trivy-operator.tf).

This is **observe-only** — the operator writes report CRDs and changes nothing.
No workload is ever blocked. It is the **runtime twin** of the CI-time trivy gate
(`scripts/security-gates.sh` Gate 4):

| Layer | Tool | When | Effect |
| --- | --- | --- | --- |
| Block at PR | trivy (Gate 4) | pull request | fails the merge on fixable HIGH/CRITICAL |
| Block at admission | OPA Gatekeeper | `kubectl apply` | denies insecure pods |
| **Observe at runtime** | **Trivy Operator** | **continuously, in-cluster** | **reports only — never blocks** |

So the same trivy engine that gates a bad image at PR time also tells you, live,
what CVEs are on the images already deployed — without changing their behaviour.

## How it works

The operator watches workloads in its target namespaces and, for each, launches a
short-lived **scan Job**. The Job's findings are written back as Kubernetes
custom resources you can query with plain `kubectl`:

| CRD | What it reports |
| --- | --- |
| `vulnerabilityreports` | image CVEs (OS + language packages) |
| `configauditreports` | workload misconfig (Trivy's built-in checks) |
| `exposedsecretreports` | secrets baked into image layers |
| `rbacassessmentreports` | over-permissive RBAC on the workload's SA |

Reports refresh automatically as the operator re-scans, so they track the live
state rather than a point-in-time snapshot.

### Configuration (why these values)

Set in `trivy-operator.tf`; the ones that matter for this lab:

| Value | Setting | Why |
| --- | --- | --- |
| `targetNamespaces` | `webapp` | scope to the app namespace (`""` = whole cluster) |
| `trivyOperator.scanJobsInSameNamespace` | `false` | **critical** — run scan Jobs in `trivy-system`, not `webapp`, so the deny-mode Gatekeeper constraints (scoped to `webapp`) don't reject them. Flip to `true` and scans of `webapp` get **denied** for missing `runAsNonRoot`/limits |
| `trivy.ignoreUnfixed` + `trivy.severity` | `true`, `HIGH,CRITICAL` | line the reports up with what Gate 4 enforces |
| `operator.scanJobsConcurrentLimit` | `1` | the default (10) can peg CPU on a laptop k3d node |
| `trivy.resources` | small limits | keep the scan container light |

> **DB download:** the first scan pulls the trivy vuln DB from `ghcr.io`. Fine
> here — the k3d node has internet (the same path `make reboot` relies on). For
> an air-gapped cluster, point `trivy.dbRepository` at a mirror.

## Deploy

It is a plain `helm_release` (its CRDs ship with the chart, so there is no
`kubernetes_manifest` plan-time dependency), so it installs in the same pass as
Gatekeeper/ESO:

```bash
cd terraform/cluster
terraform apply -target=helm_release.trivy_operator
```

The regular `terraform apply` picks it up on every run thereafter.

Confirm the controller is up:

```bash
KC="kubectl --context k3d-webapp-test"
$KC get pods -n trivy-system
$KC get crd | grep aquasecurity
```

## Verifying commands (the "show")

```bash
KC="kubectl --context k3d-webapp-test"

# Per-workload vuln counts — CRITICAL/HIGH/MEDIUM/LOW columns
$KC get vulnerabilityreports -n webapp -o wide

# Everything the operator has scanned, cluster-wide
$KC get vulnerabilityreports -A -o wide

# Summary numbers for the webapp image
$KC get vulnerabilityreports -n webapp -o json | jq '.items[].report.summary'

# The actual CVE list from the LIVE cluster (severity, id, package, fix)
$KC get vulnerabilityreports -n webapp -o json | jq -r '.items[].report.vulnerabilities[] | [.severity, .vulnerabilityID, .resource, .installedVersion, .fixedVersion] | @tsv' | sort -u | column -t

# Config-audit, exposed-secret, and RBAC findings (also observe-only)
$KC get configauditreports -n webapp -o wide
$KC get exposedsecretreports -A
$KC get rbacassessmentreports -n webapp
```

Report names encode the workload they cover, e.g.
`replicaset-webapp-<hash>` for the webapp Deployment's ReplicaSet.

### Watch a scan happen

```bash
KC="kubectl --context k3d-webapp-test"

# Force a re-scan by deleting the report — the operator regenerates it
$KC delete vulnerabilityreports -n webapp --all
$KC get jobs -n trivy-system -w        # a scan-<hash> Job appears, runs, completes (Ctrl-C)
$KC get vulnerabilityreports -n webapp -o wide   # the fresh report is back
```

## How this maps to the CI gate

The runtime reports and Gate 4 use the **same trivy engine and the same
threshold** (`ignoreUnfixed: true`, `severity: HIGH,CRITICAL`), so a clean Gate 4
and a clean `vulnerabilityreport` tell the same story from two angles:

- **Gate 4** proves no bad image can be *merged*.
- **Trivy Operator** proves what is *running* right now, including images that
  predate the gate or drifted in out-of-band.

Because it is observe-only, it complements — never duplicates — Gatekeeper's
blocking admission control. See [`security/COMPLIANCE.md`](../security/COMPLIANCE.md)
for the RA-5 / SI-2 control mapping the two share.
