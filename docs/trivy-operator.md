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
short-lived **scan Job** (in `trivy-system`). The Job's findings are written back
as Kubernetes custom resources you can query with plain `kubectl`:

| CRD | What it reports | Needs to pull the image? |
| --- | --- | --- |
| `vulnerabilityreports` | image CVEs (OS + language packages) | **yes** |
| `configauditreports` | workload misconfig (Trivy's built-in checks) | no — reads the spec |
| `exposedsecretreports` | secrets baked into image layers | yes |
| `rbacassessmentreports` | over-permissive RBAC on the workload's SA | no — reads the spec |

Reports refresh automatically as the operator re-scans, so they track live state.

## Two lab-specific prerequisites (both handled in Terraform)

### 1. Node disk headroom for the scan job

Each vulnerability scan **downloads the trivy vuln DB (~1–2 GB)** onto the node
before scanning. k3s's default hard-eviction floor is `imagefs.available<15%`,
which on a small/disk-tight k3d node the DB download dips below — the node goes
into **disk-pressure and evicts workloads** (it will GC the side-loaded webapp
image too). So the lab lowers the floor to `5%` via
[`terraform/cluster/k3s-config.yaml`](../terraform/cluster/k3s-config.yaml),
mounted into the node by `cluster.tf`. With that, a scan's transient dip
(observed: 18 GB → 14 GB free) is tolerated with no eviction.

> If you run the operator on a node with **< ~20 GB free** and the default 15%
> floor, expect the scan to trigger disk-pressure. Either keep the 5% floor
> (this repo's default) or give the node more disk.

### 2. Scan jobs must not land in `webapp`

`trivyOperator.scanJobsInSameNamespace = false` keeps scan Jobs in `trivy-system`,
not `webapp`. If they ran in `webapp`, the deny-mode Gatekeeper constraints
(scoped to `webapp`) would **reject** them for missing `runAsNonRoot`/limits.

### Configuration (why these values)

Set in `trivy-operator.tf`:

| Value | Setting | Why |
| --- | --- | --- |
| `targetNamespaces` | `webapp` | scope to the app namespace (`""` = whole cluster) |
| `trivyOperator.scanJobsInSameNamespace` | `false` | keep scan Jobs out of `webapp` (see above) |
| `trivy.ignoreUnfixed` + `trivy.severity` | `true`, `HIGH,CRITICAL` | line the reports up with Gate 4 |
| `operator.scanJobsConcurrentLimit` | `1` | the default (10) can spike CPU/disk on a small node |
| `trivy.resources` | small limits | keep the scan container light |

## Deploy

The operator is a plain `helm_release`, and the eviction floor rides along with
the k3d cluster create — so a normal `make deploy` brings up both. On an existing
cluster you can target just the operator:

```bash
cd terraform/cluster
terraform apply -target=helm_release.trivy_operator
```

Confirm the controller is up:

```bash
KC="kubectl --context k3d-webapp-test"
$KC get pods -n trivy-system
$KC get crd | grep aquasecurity
```

Confirm the eviction floor is the lowered one (should print `imagefs.available: 5%`):

```bash
$KC get --raw "/api/v1/nodes/k3d-webapp-test-server-0/proxy/configz" | jq '.kubeletconfig.evictionHard'
```

## Generate a vulnerability report — end to end

**The catch:** the operator can't scan the running **webapp** pod. Its image is
the floci/LocalStack ECR ref, which isn't pullable from a scan pod (the hostname
resolves to loopback in-cluster) — that scan `Error`s, so no `vulnerabilityreport`
for webapp. Its `configaudit`/`rbac` reports still populate (they read the spec).

To produce a real `vulnerabilityreport`, point the operator at a **pullable**
image. Use the **byte-identical upstream** the webapp image is retagged from
(`docker.io/nginxinc/nginx-unprivileged:1.27`) via a throwaway, Gatekeeper-compliant
workload in `webapp`:

```bash
KC="kubectl --context k3d-webapp-test"

# 1. Deploy the pullable workload (compliant so Gatekeeper admits it)
cat <<'EOF' | $KC apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: scan-demo, namespace: webapp, labels: { app: scan-demo } }
spec:
  replicas: 1
  selector: { matchLabels: { app: scan-demo } }
  template:
    metadata: { labels: { app: scan-demo } }
    spec:
      automountServiceAccountToken: false
      containers:
        - name: nginx
          image: docker.io/nginxinc/nginx-unprivileged:1.27
          resources: { requests: { cpu: "50m", memory: "32Mi" }, limits: { cpu: "100m", memory: "64Mi" } }
          securityContext:
            runAsNonRoot: true
            runAsUser: 101
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
            seccompProfile: { type: RuntimeDefault }
EOF

# 2. Watch the scan Job run (in trivy-system) and the report appear (~30-60s)
$KC get jobs -n trivy-system -w        # a scan-<hash> Job runs and completes (Ctrl-C)
$KC get vulnerabilityreports -n webapp -o wide

# 3. Read the report
$KC get vulnerabilityreports -n webapp -o json | jq '.items[].report.summary'
$KC get vulnerabilityreports -n webapp -o json | jq -r '.items[].report.vulnerabilities[] | [.severity, .vulnerabilityID, .resource, .installedVersion, .fixedVersion] | @tsv' | sort -u | column -t

# 4. Clean up — deleting the workload GC's its report (it's owned by the workload)
$KC delete deploy scan-demo -n webapp
```

Example result (`nginxinc/nginx-unprivileged:1.27`, Trivy 0.72.0):

```
REPOSITORY                    TAG    SCANNER   CRITICAL  HIGH  MEDIUM  LOW
nginxinc/nginx-unprivileged   1.27   Trivy        5       37     0      0
```

These are the **same CVEs Gate 4 reports** (same engine, same image) — e.g.
`CVE-2026-31789` (libssl3), `CVE-2024-56171` (libxml2) — so the runtime report
and the CI gate agree.

## Other report kinds (no pullable image needed)

These populate for the real webapp workload out of the box:

```bash
KC="kubectl --context k3d-webapp-test"
$KC get configauditreports -n webapp -o wide      # workload misconfig
$KC get rbacassessmentreports -n webapp           # SA RBAC findings
$KC get exposedsecretreports -A                   # secrets in image layers
```

## How this maps to the CI gate

The runtime reports and Gate 4 use the **same trivy engine and threshold**
(`ignoreUnfixed: true`, `severity: HIGH,CRITICAL`), so a clean Gate 4 and a clean
`vulnerabilityreport` tell the same story from two angles:

- **Gate 4** proves no bad image can be *merged*.
- **Trivy Operator** proves what is *running* right now.

Because it is observe-only, it complements — never duplicates — Gatekeeper's
blocking admission control. See [`security/COMPLIANCE.md`](../security/COMPLIANCE.md)
for the RA-5 / SI-2 control mapping the two share.
