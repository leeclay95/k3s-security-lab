# Security-gate demo: a failing PR, reverted to green

A reproducible walkthrough of the `security-gates` check (kubesec + tfsec +
conftest) blocking a merge, then passing once the offending change is reverted.

The regression is a single throwaway file — a `privileged` Pod added to the
chart — which trips **both** kubesec (negative score) and conftest (privileged
+ no limits + not non-root + no drop-ALL). Nothing touches the real chart.

> Prereq: `main` is protected with the required `security-gates` check
> (`enforce_admins: true`, `strict: true`). Direct pushes to `main` are blocked;
> everything lands via PR.

## Phase 0 — start clean

```bash
cd /home/kali/floci/k3-test
git checkout main && git pull
```

## Phase 1 — branch + introduce the violation

```bash
git checkout -b demo/gate-fail

cat > charts/webapp/templates/insecure-demo.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: insecure-demo
  namespace: {{ .Release.Namespace }}
spec:
  containers:
    - name: bad
      image: busybox:1.36
      securityContext:
        privileged: true
EOF
```

## Phase 2 — catch it locally *before* pushing

```bash
./scripts/security-gates.sh ; echo "exit=$?"
```

**Expect:** `kubesec: FAIL`, `conftest: FAIL`, `OVERALL: FAIL`, `exit=1`.

## Phase 3 — commit, push, open the PR

```bash
git add charts/webapp/templates/insecure-demo.yaml
git commit -m "demo: add insecure privileged pod (should fail gates)"
git push -u origin demo/gate-fail
gh pr create --fill --base main
```

## Phase 4 — watch the required check fail; confirm merge is blocked

```bash
gh pr checks --watch
gh pr view --json mergeStateStatus,mergeable -q '.mergeStateStatus + " / mergeable=" + (.mergeable|tostring)'
gh pr merge --merge
```

**Expect:** check `security-gates … fail`; `mergeStateStatus` = `BLOCKED`; and
`gh pr merge` refuses with a "required status check" / "not mergeable" error.

## Phase 5 — revert so the gates pass, repush

```bash
git revert --no-edit HEAD          # removes the bad file
./scripts/security-gates.sh ; echo "exit=$?"   # Expect: OVERALL PASS, exit=0
git push                           # updates the PR → check re-runs
```

(Equivalent by hand: `git rm charts/webapp/templates/insecure-demo.yaml && git commit -m "remove insecure pod"`.)

## Phase 6 — check goes green, merge

```bash
gh pr checks --watch               # Expect: security-gates … pass
gh pr merge --merge --delete-branch
```

## Phase 7 — back to a clean main

```bash
git checkout main && git pull
```

## Per-gate failure recipes

Trip each gate in isolation — run locally with `./scripts/security-gates.sh`, or
push a PR and watch the required check go red. Revert to go green.

### Make kubesec fail

```bash
# (a) No file change — raise the bar above the chart's real score (12):
KUBESEC_MIN_SCORE=20 ./scripts/security-gates.sh ; echo "exit=$?"   # kubesec FAIL

# (b) Real regression — a privileged/root container scores negative, e.g. the
#     Phase 1 insecure-demo Pod, or drop the Deployment's securityContext
#     hardening (runAsNonRoot / readOnlyRootFilesystem / capabilities.drop:[ALL]).
```

### Make conftest (OPA) fail

Drop a violating manifest into a template file
(`charts/webapp/templates/conftest-demo.yaml`), run the gate, then delete it.

```yaml
# hostNetwork  ->  block-host-namespaces
apiVersion: v1
kind: Pod
metadata: { name: bad-hostnet, namespace: default }
spec:
  hostNetwork: true
  containers:
    - name: c
      image: busybox:1.36
```

Other one-line triggers on a container's `securityContext` / spec:
- omit `resources.limits` → **require-resource-limits**
- `capabilities.add: ["NET_RAW"]` → **block-dangerous-caps**
- `runAsNonRoot: false` → **require-non-root**
- `privileged: true` → **block-privileged** (also fails kubesec)

### Make tfsec fail (>= HIGH)

```bash
cat > terraform/infra/tfsec-demo-bad.tf <<'EOF'
resource "aws_security_group" "tfsec_demo_bad" {
  name = "tfsec-demo-bad"
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # SSH open to the world -> CRITICAL
  }
}
EOF
./scripts/security-gates.sh ; echo "exit=$?"   # tfsec FAIL
rm terraform/infra/tfsec-demo-bad.tf           # revert
```

## Pushing a webapp update (ConfigMap) through the gate to Argo

The landing page is the `webapp-index-html` ConfigMap
(`charts/webapp/templates/configmap-index.yaml`). Ship a content change via
GitOps — gated on the way in, then auto-synced by Argo:

```bash
git checkout main && git pull
git checkout -b feature/webapp-copy

# edit the index.html block inside charts/webapp/templates/configmap-index.yaml

./scripts/security-gates.sh ; echo "exit=$?"     # a ConfigMap isn't a workload -> PASS
git add charts/webapp/templates/configmap-index.yaml
git commit -m "webapp: update landing-page copy"
git push -u origin feature/webapp-copy
gh pr create --fill --base main
gh pr checks --watch                             # (see the "no checks reported" note)
gh pr merge --merge --delete-branch

# let Argo apply it to the live site
git checkout main && git pull
NEW=$(git rev-parse HEAD)
kubectl --context k3d-webapp-test -n argocd annotate application webapp argocd.argoproj.io/refresh=hard --overwrite
until [ "$(kubectl --context k3d-webapp-test -n argocd get application webapp -o jsonpath='{.status.sync.revision}')" = "$NEW" ]; do sleep 5; done
# directory-mounted ConfigMap -> the pod picks it up in ~60s, no restart
until curl -s http://localhost:30080 | grep -q 'YOUR NEW TEXT'; do sleep 5; done
echo "live"
```

The full themed version of this exact flow (Matrix landing page, change +
revert) lives in `/tmp/matrix-gitops-demo.md`.

## Notes

- If `gh pr checks --watch` prints **"no checks reported on the branch"**, the
  workflow just hasn't registered its check yet (a few-second race right after
  `gh pr create`). Wait ~10s and re-run `gh pr checks --watch` — the merge stays
  `BLOCKED` until the check runs and passes.
- `strict: true` means the PR must be up to date with `main`; if `main` moved,
  run `git pull --rebase origin main` on the branch before merging.
- `enforce_admins: true` is why even a repo admin can't force this through — by
  design. If a green check still won't merge, run `gh pr checks` and confirm the
  context name is exactly `security-gates`.
- Want to exercise the **tfsec** gate instead? Introduce a HIGH finding in
  `terraform/infra` (e.g. an unencrypted resource) rather than the Pod.
- Evidence for each CI run is uploaded as the `security-evidence-<run_id>`
  artifact on the workflow run page; local runs write to `security/reports/`.
