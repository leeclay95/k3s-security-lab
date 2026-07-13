# CloudWatch logs: where they are and how to fill them

`terraform/infra` provisions the CloudWatch **log groups** (`/k8s/webapp/app`,
`/k8s/webapp/audit`, plus `/aws/ecr/...` and `/aws/rds/...`) in floci's emulated
CloudWatch at `localhost:4566`. Those groups start **empty** — provisioning a
group doesn't ship anything to it.

`logging/cloudwatch-log-shipper.yaml` closes that gap. One hardened DaemonSet
tails two node log sources and fills two groups:

| Source on node | CloudWatch group | What's in it |
| --- | --- | --- |
| `/var/log/pods/webapp_*/*/*.log` | `/k8s/webapp/app` | nginx access/error lines |
| `/var/log/k3s-audit.log` | `/k8s/webapp/audit` | API-server audit: exec/attach, restarts, deploys, deletes, secret access, RBAC, webapp pod events |

The audit group is fed by k3s API-server audit logging, enabled in
`terraform/cluster/cluster.tf` (the `k3d cluster create` passes
`--kube-apiserver-arg=audit-policy-file=...` + `audit-log-path=...`, mounting
`terraform/cluster/audit-policy.yaml`). Because audit config is read at
API-server startup, **turning it on requires a cluster rebuild** (`make destroy
&& make deploy`) — you can't hot-enable it on a running cluster.

## Deploy the shipper

`make deploy` brings it up automatically (Pass 3, tolerated so it can't fail the
core deploy). To (re)apply it on its own:

```bash
make log-shipper
# equivalent to:
#   kubectl --context k3d-webapp-test apply -f logging/cloudwatch-log-shipper.yaml
#   kubectl --context k3d-webapp-test -n logging rollout status daemonset/cloudwatch-log-shipper
```

`make cluster-up` also re-applies it, so a post-reboot start self-heals the
shipper along with the CoreDNS `host.k3d.internal` fix.

## Make traffic and read it back from CloudWatch

```bash
for i in 1 2 3; do curl -s -o /dev/null "http://localhost:30080/?probe=$i"; done

export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
EP="aws --endpoint-url=http://localhost:4566 --region us-east-1"

$EP logs describe-log-streams --log-group-name /k8s/webapp/app --query 'logStreams[].logStreamName' --output text
$EP logs filter-log-events --log-group-name /k8s/webapp/app --query 'events[-10:].message' --output text
```

You'll see the raw nginx access lines (CRI format: `<ts> stdout F <message>`),
one stream per node (`k3d-webapp-test-server-0`).

## See more than GET requests: exec, restarts, deletes

The audit stream captures the security-relevant events, not just HTTP traffic.
Generate a few, then read them back:

```bash
KC="kubectl --context k3d-webapp-test"
$KC -n webapp exec deploy/webapp -- id          # shell access into a pod
$KC -n webapp rollout restart deploy/webapp     # workload restart
$KC -n webapp delete pod -l app=webapp          # crash/restart simulation

EP="aws --endpoint-url=http://localhost:4566 --region us-east-1"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test

# who exec'd, into which pod, running what:
$EP logs filter-log-events --log-group-name /k8s/webapp/audit --query 'events[].message' --output text | tr '\t' '\n' | grep '"subresource":"exec"'
```

An exec entry shows the actor and the command, e.g.:

```
"user":{"username":"system:admin",...}
"requestURI":"/api/v1/namespaces/webapp/pods/webapp-77.../exec?command=id&container=webapp&..."
```

The shipper is throughput-limited (one `PutLogEvents` per line), so give it a
few seconds after generating events before the last ones appear in the stream.

## How it works

```
webapp pod (nginx stdout)
   -> containerd writes /var/log/pods/webapp_*/*/*.log on the node ---.
                                                                       |-> DaemonSet tails (hostPath /var/log, read-only)
kube-apiserver (audit policy) -> /var/log/k3s-audit.log on the node --'      -> aws logs put-log-events -> floci CloudWatch
                                                                                 pods -> /k8s/webapp/app
                                                                                 audit -> /k8s/webapp/audit
```

### What the audit policy captures

`terraform/cluster/audit-policy.yaml` is deliberately low-volume — it logs
security-relevant events and drops routine read noise:

- **exec / attach / port-forward** at `Request` level (so the command is kept)
- **workload lifecycle** — create/delete/patch/update on pods, deployments,
  daemonsets, statefulsets, replicasets (rollout restarts, deletes, scaling)
- **webapp pod events** — OOMKilled/BackOff/Killing/Started/Unhealthy in the
  `webapp` namespace (how crash-restarts surface)
- **secret reads in the `webapp` namespace** at `Metadata` level (the
  credential-access signal; never the values)
- **secret / configmap writes** and **RBAC changes** at `Metadata` level
- **dropped:** all other `get`/`list`/`watch` reads — the high-volume noise from
  ESO/Argo/Gatekeeper/k3s controllers that otherwise floods the shipper
- everything else: `level: None`

## Design notes

- **Separate `logging` namespace.** The Gatekeeper constraints are scoped to the
  `webapp` namespace, so a log collector (which needs node access) lives outside
  them. It's also outside the Argo-managed webapp chart.
- **Runs as root (uid 0) — on purpose, and still hardened.** The kube-apiserver
  writes the audit log `0600 root:root`, so *only* root can read it. Root reads
  its own `0600` file by ownership, so we still `drop: [ALL]` capabilities (no
  `CAP_DAC_OVERRIDE` needed), keep `readOnlyRootFilesystem`,
  `allowPrivilegeEscalation: false`, and seccomp `RuntimeDefault`. (The earlier
  app-only shipper ran non-root as `uid 65534`/`GID 0` to read the group-readable
  pod logs; adding the `0600` audit source is what forced root.)
- **Not covered by the security gate.** `scripts/security-gates.sh` scans
  `charts/webapp` + `terraform/`, not `logging/`. A node log collector inherently
  needs a `hostPath` mount (kubesec penalizes that), which is why it's a
  documented platform component rather than part of the gated chart.
- **Lab-grade, but batched.** It buffers up to 100 lines / 5s and sends each
  batch in a single `aws logs put-log-events`, so it launches ~one `aws` process
  per batch instead of one per line. The original per-line version spawned a cold
  Python `aws` CLI (~0.2–0.4s CPU) *per log line* and pinned its 200m CPU limit
  once the audit stream was added (~4 procs/sec, throttled); batching dropped it
  to well under the limit. Still not a high-throughput agent — a production setup
  would use Fluent Bit or Vector (Vector's `aws_cloudwatch_logs` sink takes a full
  `endpoint = "http://host.k3d.internal:4566"`, which the C-based Fluent Bit
  plugin can't, since it assumes TLS/443).

## Without the shipper, where are the logs?

Straight from the pods:

```bash
kubectl --context k3d-webapp-test -n webapp logs deploy/webapp --tail=50
kubectl --context k3d-webapp-test -n external-secrets logs deploy/external-secrets --tail=50
```

Raw audit, straight from the node (root-owned `0600`, so needs `docker exec`):

```bash
docker exec k3d-webapp-test-server-0 tail -n 5 /var/log/k3s-audit.log
```
