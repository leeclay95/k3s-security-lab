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

## Notes

- `strict: true` means the PR must be up to date with `main`; if `main` moved,
  run `git pull --rebase origin main` on the branch before merging.
- `enforce_admins: true` is why even a repo admin can't force this through — by
  design. If a green check still won't merge, run `gh pr checks` and confirm the
  context name is exactly `security-gates`.
- Want to exercise the **tfsec** gate instead? Introduce a HIGH finding in
  `terraform/infra` (e.g. an unencrypted resource) rather than the Pod.
- Evidence for each CI run is uploaded as the `security-evidence-<run_id>`
  artifact on the workflow run page; local runs write to `security/reports/`.
