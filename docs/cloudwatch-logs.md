# CloudWatch logs: where they are and how to fill them

`terraform/infra` provisions the CloudWatch **log groups** (`/k8s/webapp/app`,
`/k8s/webapp/audit`, plus `/aws/ecr/...` and `/aws/rds/...`) in floci's emulated
CloudWatch at `localhost:4566`. Those groups start **empty** — provisioning a
group doesn't ship anything to it.

`logging/cloudwatch-log-shipper.yaml` closes that gap: it ships the webapp pod's
container logs from the node into `/k8s/webapp/app`, so the group actually fills.

## Deploy the shipper

`make deploy` brings it up automatically (Pass 3, tolerated so it can't fail the
core deploy). To (re)apply it on its own:

```bash
make log-shipper
# equivalent to:
#   kubectl --context k3d-webapp-test apply -f logging/cloudwatch-log-shipper.yaml
#   kubectl --context k3d-webapp-test -n logging rollout status daemonset/cloudwatch-log-shipper
```

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

## How it works

```
webapp pod (nginx stdout)
   -> containerd writes /var/log/pods/webapp_*/*/*.log on the node
   -> DaemonSet tails those files (hostPath, read-only)
   -> aws logs put-log-events  ->  floci CloudWatch  /k8s/webapp/app
```

## Design notes

- **Separate `logging` namespace.** The Gatekeeper constraints are scoped to the
  `webapp` namespace, so a log collector (which needs node access) lives outside
  them. It's also outside the Argo-managed webapp chart.
- **Hardened anyway.** Runs non-root (`uid 65534`) with `runAsGroup: 0` — GID 0
  is what lets it read the `root:root`, group-readable node log files without
  being root. Plus `drop: [ALL]`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation:
  false`, seccomp `RuntimeDefault`, and resource limits.
- **Not covered by the security gate.** `scripts/security-gates.sh` scans
  `charts/webapp` + `terraform/`, not `logging/`. A node log collector inherently
  needs a `hostPath` mount (kubesec penalizes that), which is why it's a
  documented platform component rather than part of the gated chart.
- **Lab-grade.** It spawns one `aws` process per log line, so it's fine for demo
  traffic, not high throughput. A production setup would use Fluent Bit or Vector
  with batching (Vector's `aws_cloudwatch_logs` sink takes a full
  `endpoint = "http://host.k3d.internal:4566"`, which the C-based Fluent Bit
  plugin can't, since it assumes TLS/443).

## Without the shipper, where are the logs?

Straight from the pods:

```bash
kubectl --context k3d-webapp-test -n webapp logs deploy/webapp --tail=50
kubectl --context k3d-webapp-test -n external-secrets logs deploy/external-secrets --tail=50
```

The `/k8s/webapp/audit` group (k8s API-server audit) is still unfed — that would
need k3s started with an audit policy writing to a file the shipper also tails.
