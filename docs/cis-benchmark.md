# CIS benchmark scanning (kube-bench)

Assess the cluster against the **CIS Kubernetes Benchmark** with
[kube-bench](https://github.com/aquasecurity/kube-bench), run as an in-cluster
Job. This is **read-only** — it inspects kubelet/k3s config and file permissions
and reports `PASS`/`FAIL`/`WARN`/`INFO`; it changes nothing.

Results are archived under [`security/benchmark-results/`](../security/benchmark-results/).

## Which benchmark to use

kube-bench ships one config per platform+standard. For this lab's k3s cluster:

| Goal | `--benchmark` | Notes |
| --- | --- | --- |
| **Accurate k3s hardening (use this)** | `k3s-cis-1.24` | k3s-native paths (`/etc/rancher/k3s`, `/var/lib/rancher/k3s`), correct remediation |
| Generic Kubernetes CIS | `cis-1.24` | assumes kubeadm layout; noisier on k3s |
| DISA STIG (V-IDs) | `eks-stig-kubernetes-v1r6` | the **only** STIG benchmark, but EKS-flavored — heavy false-FAILs on k3s (looks for kubeadm paths / a standalone kubelet process that k3s doesn't have) |

**CIS ≠ STIG.** `k3s-cis-1.24` gives trustworthy hardening results keyed by CIS
IDs (`4.2.6`), not STIG V-IDs. It does not feed the `M_Kubernetes` STIG checklist
without a CIS→STIG cross-map. See the STIG workflow for that path.

## Run it

A ready-to-apply Job with **standard text output** is committed at
[`security/kube-bench-cis-job.yaml`](../security/kube-bench-cis-job.yaml):

```bash
KC="kubectl --context k3d-webapp-test"
$KC apply -f security/kube-bench-cis-job.yaml
$KC wait --for=condition=complete job/kube-bench-cis -n default --timeout=120s
$KC logs job/kube-bench-cis -n default        # PASS/FAIL/WARN/INFO + remediation + summary
# re-run: delete the Job first (name is fixed), then re-apply
$KC delete job kube-bench-cis -n default --ignore-not-found
```

To capture **JSON** instead (for archiving under `benchmark-results/`), use the
same Job with `--json` added to the command — inline below:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-k3s
  namespace: default
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: { app: kube-bench-k3s }
    spec:
      hostPID: true
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: docker.io/aquasec/kube-bench:latest
          command: ["kube-bench", "run", "--benchmark", "k3s-cis-1.24", "--json"]
          volumeMounts:
            - { name: var-lib, mountPath: /var/lib, readOnly: true }
            - { name: etc,     mountPath: /etc,     readOnly: true }
      volumes:
        - { name: var-lib, hostPath: { path: /var/lib } }
        - { name: etc,     hostPath: { path: /etc } }
```

```bash
KC="kubectl --context k3d-webapp-test"
$KC apply -f kube-bench-k3s.yaml
$KC wait --for=condition=complete job/kube-bench-k3s -n default --timeout=120s
```

> Runs in `default`, not `webapp` — the Gatekeeper constraints are scoped to the
> `webapp` namespace, so this `hostPID` collector isn't blocked by them.

### Targets

Omit `--targets` (as above) to run every section, or scope it:

```
command: ["kube-bench", "run", "--benchmark", "k3s-cis-1.24", "--targets", "node,policies", "--json"]
```

`node` (kubelet/file perms) and `policies` (RBAC, Pod Security, service accounts)
are the most meaningful on a single-node k3d cluster; `policies` is closest to the
webapp's own posture (which is also enforced live by Gatekeeper/OPA).

## Save the results (JSON, full detail via jq)

```bash
KC="kubectl --context k3d-webapp-test"
$KC logs job/kube-bench-k3s -n default | sed -n '/^{/,$p' | jq '.' > security/benchmark-results/k3s-cis-1.24-$(date +%Y%m%d).json
```

`jq '.'` keeps the complete structure — every check's `test_number`, `status`,
`audit` command, `actual`/`expected`, and `remediation`.

Quick reads over a saved result:

```bash
F=security/benchmark-results/k3s-cis-1.24-20260713.json
jq '.Totals' "$F"                                                                    # pass/fail/warn/info
jq -r '.Controls[] | "\(.id) \(.text) [P\(.total_pass)/F\(.total_fail)/W\(.total_warn)]"' "$F"   # per-section
jq -r '.Controls[].tests[].results[] | select(.status=="FAIL") | "\(.test_number)  \(.test_desc)"' "$F"   # just the FAILs
```

## Latest result (`k3s-cis-1.24`, 2026-07-13)

| Section | Pass | Fail | Warn | Info |
| --- | --- | --- | --- | --- |
| 1 Control Plane Security Configuration | 14 | 23 | 12 | 13 |
| 2 Etcd Node Configuration | 0 | 0 | 7 | 0 |
| 3 Control Plane Configuration | 0 | 0 | 3 | 0 |
| 4 Worker Node Security Configuration | 14 | 2 | 2 | 5 |
| 5 Kubernetes Policies | 0 | 0 | 30 | 0 |
| **Total** | **28** | **25** | **54** | **18** |

Notable node findings worth acting on:
- `4.2.6` — `--protect-kernel-defaults=true` not set. Fix by adding
  `--k3s-arg --kubelet-arg=protect-kernel-defaults=true@server:0` to the k3d
  cluster create in `terraform/cluster/cluster.tf`, then rebuild.
- `4.2.10` — kubelet `--tls-cert-file`/`--tls-private-key-file` not explicitly
  set. Benign on k3s: k3s auto-manages the serving cert at
  `/var/lib/rancher/k3s/agent/serving-kubelet.{crt,key}` and rotates it. Accept
  with justification or set the flags explicitly.

Many section-1/5 `WARN`s are "Manual" review items or reflect k3s's single-binary
control plane (files a multi-node kubeadm cluster would have separately). Read
`FAIL`s against the k3s-native remediation text, which the benchmark provides.

## Cleanup

```bash
kubectl --context k3d-webapp-test delete job kube-bench-k3s -n default
```
