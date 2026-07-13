# Benchmark results

Archived output from CIS benchmark scans of the cluster (kube-bench), kept as
compliance evidence. Full-detail JSON — each file preserves every check's
`test_number`, `status`, `audit` command, `actual`/`expected`, and `remediation`.

See [`docs/cis-benchmark.md`](../../docs/cis-benchmark.md) for how to run a scan
and regenerate these.

## Files

| File | Benchmark | Date | Result |
| --- | --- | --- | --- |
| `k3s-cis-1.24-20260713.json` | `k3s-cis-1.24` (all targets) | 2026-07-13 | 28 PASS / 25 FAIL / 54 WARN / 18 INFO |

Naming: `<benchmark>-<YYYYMMDD>.json`.

These are **CIS** results (IDs like `4.2.6`), not DISA STIG V-IDs. CIS is the
accurate framework for k3s hardening; the STIG workflow is separate.
