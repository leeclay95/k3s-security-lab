#!/usr/bin/env bash
# Wait for an Argo CD Application to reach Synced/Healthy, nudging it if it stalls.
#
#   wait-argo-healthy.sh [app-name]   (default: webapp)
#
# Planting the Application is instant, but Argo then has to sync the chart, ESO
# has to fetch the secrets from floci, and the pod has to start — so without this
# gate `make deploy` would report success while the webapp is still Missing.
#
# If the app stalls (health Missing/Degraded) we issue a single hard refresh to
# force Argo to re-read the cluster and retry — this recovers the fresh-install
# race where the application-controller's discovery cache hasn't yet picked up a
# just-registered CRD (ESO's ExternalSecret, or a Gatekeeper-generated
# constraint CRD).
#
# No root required.
set -uo pipefail

APP="${1:-webapp}"
CTX="${KCTX:-k3d-webapp-test}"
K="kubectl --context ${CTX}"
TIMEOUT="${TIMEOUT:-300}"

deadline=$(( $(date +%s) + TIMEOUT ))
nudged=0
sync=""; health=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  sync=$($K get application "$APP" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$($K get application "$APP" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null)
  echo "  waiting for ${APP}: sync=${sync:-?} health=${health:-?}"
  if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
    echo "  ${APP} is Synced/Healthy"
    exit 0
  fi
  # One hard-refresh nudge if it's clearly stuck rather than just progressing.
  if [ "$nudged" -eq 0 ] && { [ "$health" = "Missing" ] || [ "$health" = "Degraded" ] || [ "$sync" = "OutOfSync" ]; }; then
    $K annotate application "$APP" -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
    nudged=1
  fi
  sleep 10
done

echo "  WARNING: ${APP} not Synced/Healthy after ${TIMEOUT}s (sync=${sync} health=${health})" >&2
echo "  Inspect: ${K} get application ${APP} -n argocd -o yaml" >&2
exit 1
