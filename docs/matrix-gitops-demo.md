# Matrix landing-page GitOps demo (change -> Argo sync -> revert)

Swaps the webapp landing-page ConfigMap for a Matrix "digital rain" page via a
gated PR, lets Argo CD sync it to the live site, then reverts through another
gated PR. Run from the repo root: /home/kali/floci/k3-test

Because `main` is protected (required `security-gates` check, enforce_admins),
both the change and the revert go through PRs. A ConfigMap isn't a workload, so
the gates pass.

The landing page is the `webapp-index-html` ConfigMap, mounted as a DIRECTORY
(not subPath) at /usr/share/nginx/html — so a content change reaches the running
pod in ~60s with no restart, and nginx serves it fresh.

---

## Prereq — confirm the app is reachable

```bash
cd /home/kali/floci/k3-test
curl -s -o /dev/null -w 'webapp HTTP %{http_code}\n' http://localhost:30080
```

Expect `HTTP 200`. If not: `make cluster-up` (or `make deploy` if the cluster is gone).

## Phase 1 — branch, replace the landing-page ConfigMap with the Matrix page

```bash
git checkout main && git pull
git checkout -b feature/matrix-landing

git rm charts/webapp/templates/configmap-index.yaml

# The HTML below contains '!' (<!DOCTYPE>). Interactive zsh/bash would try
# history expansion on it even inside a quoted heredoc, so disable it first.
setopt no_bang_hist 2>/dev/null || set +H

cat > charts/webapp/templates/matrix-configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "webapp.name" . }}-index-html
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "webapp.labels" . | nindent 4 }}
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Matrix // webapp</title>
      <style>
        html,body{margin:0;height:100%;background:#000;overflow:hidden}
        #msg{position:fixed;top:50%;left:0;right:0;transform:translateY(-50%);
          text-align:center;color:#0f0;font-family:monospace;font-size:2em;
          text-shadow:0 0 8px #0f0;z-index:2}
      </style>
    </head>
    <body>
      <div id="msg">Wake up, Neo... GitOps has you.</div>
      <canvas id="m"></canvas>
      <script>
        const c=document.getElementById('m'),x=c.getContext('2d');
        function sz(){c.width=innerWidth;c.height=innerHeight}
        sz();addEventListener('resize',sz);
        let drops=Array(Math.floor(innerWidth/16)).fill(1);
        const chars='アイウエオカ0123456789ABCDEF'.split('');
        setInterval(function(){
          x.fillStyle='rgba(0,0,0,0.06)';x.fillRect(0,0,c.width,c.height);
          x.fillStyle='#0f0';x.font='16px monospace';
          for(let i=0;i<drops.length;i++){
            x.fillText(chars[Math.floor(Math.random()*chars.length)],i*16,drops[i]*16);
            if(drops[i]*16>c.height&&Math.random()>0.975)drops[i]=0;
            drops[i]++;
          }
        },50);
      </script>
    </body>
    </html>
EOF
```

## Phase 2 — render + gates locally (sanity)

```bash
helm template webapp charts/webapp | grep -c 'Wake up, Neo'   # expect: 1 (single default render)
./scripts/security-gates.sh ; echo "exit=$?"                  # expect OVERALL PASS, exit=0
```

## Phase 3 — PR, gates, merge

```bash
git add -A charts/webapp/templates/
git commit -m "feat: Matrix digital-rain landing page"
git push -u origin feature/matrix-landing
gh pr create --fill --base main
gh pr checks --watch                 # expect security-gates ... pass
gh pr merge --merge --delete-branch
```

## Phase 4 — let Argo sync, watch the live page flip to Matrix

```bash
git checkout main && git pull
NEW=$(git rev-parse HEAD)

# nudge Argo to pick up the new commit immediately (else it polls ~3 min)
kubectl --context k3d-webapp-test -n argocd annotate application webapp argocd.argoproj.io/refresh=hard --overwrite

# wait until Argo is Synced on the new revision
until [ "$(kubectl --context k3d-webapp-test -n argocd get application webapp -o jsonpath='{.status.sync.revision}')" = "$NEW" ]; do sleep 5; done
kubectl --context k3d-webapp-test -n argocd get application webapp -o custom-columns='SYNC:.status.sync.status,HEALTH:.status.health.status'

# the ConfigMap is a directory mount, so the pod picks it up in ~60s (no restart)
echo "waiting ~60s for the mounted ConfigMap to refresh in the pod..."
until curl -s http://localhost:30080 | grep -q 'Wake up, Neo'; do sleep 5; done
echo "MATRIX IS LIVE -> open http://localhost:30080 in a browser"
```

## Phase 5 — revert through a gated PR, watch it go back

```bash
git checkout -b revert/matrix-landing
git revert -m 1 --no-edit "$NEW"     # reverses the merge: restores original, drops matrix file
./scripts/security-gates.sh ; echo "exit=$?"    # expect PASS
git push -u origin revert/matrix-landing
gh pr create --fill --base main
gh pr checks --watch                 # expect pass
gh pr merge --merge --delete-branch

git checkout main && git pull
BACK=$(git rev-parse HEAD)
kubectl --context k3d-webapp-test -n argocd annotate application webapp argocd.argoproj.io/refresh=hard --overwrite
until [ "$(kubectl --context k3d-webapp-test -n argocd get application webapp -o jsonpath='{.status.sync.revision}')" = "$BACK" ]; do sleep 5; done
until curl -s http://localhost:30080 | grep -q 'Welcome to nginx'; do sleep 5; done
echo "REVERTED -> default nginx page is back"
```

## Phase 6 — cleanup (branches already deleted on merge)

```bash
git checkout main && git pull
git branch | grep -E 'matrix' && git branch -D feature/matrix-landing revert/matrix-landing 2>/dev/null || true
```

---

## Why each piece is there

- `git rm` + new file: the ConfigMap keeps the same name (`webapp-index-html`),
  so Argo sees a content change on the existing resource — no prune/recreate,
  and nginx keeps mounting it.
- `refresh=hard` annotation: forces Argo to re-check `main` now instead of
  waiting for its ~3-min poll; with auto-sync on, it then applies automatically.
- ~60s wait: the HTML is a directory mount (not subPath), so kubelet refreshes
  the projected file in place and nginx serves it fresh — no pod restart.
- `git revert -m 1`: cleanly reverses the merge commit (restores
  configmap-index.yaml, removes matrix-configmap.yaml).

Heads-up: while the Matrix page is live, that IS the Git-declared state, so
Argo's selfHeal won't fight it. If you instead `kubectl edit` the ConfigMap by
hand (out-of-band), selfHeal reverts it within seconds — a different demo.
