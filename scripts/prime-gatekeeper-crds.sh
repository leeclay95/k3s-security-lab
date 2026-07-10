#!/usr/bin/env bash
# Pre-create Gatekeeper's ConstraintTemplates so the constraint CRDs they
# generate (K8sBlockPrivileged, K8sRequireLimits, ...) EXIST before Argo CD
# first syncs the webapp app.
#
# Why this is required (learned the hard way): the webapp chart ships both the
# ConstraintTemplates and the Constraints that use them. Gatekeeper generates a
# constraint's CRD asynchronously *from* its template, so on a cold cluster that
# CRD doesn't exist when Argo plans the sync. Argo can't REST-map the Constraint,
# marks the WHOLE sync "one or more tasks are not valid", and applies NOTHING —
# including the very ConstraintTemplates that would create those CRDs. A
# permanent cold-start deadlock. (SkipDryRunOnMissingResource does NOT break it —
# the failure is at sync-task validation, before the dry-run.)
#
# Applying the templates here first lets Gatekeeper mint the CRDs up front; Argo
# then adopts the identical templates from Git and syncs the Constraints cleanly.
# Idempotent: safe to re-run (kubectl apply + a readiness poll).
#
# No root required.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTX="${KCTX:-k3d-webapp-test}"
K="kubectl --context ${CTX}"
VALUES="${VALUES:-charts/webapp/values-argocd.yaml}"

# Render ONLY the ConstraintTemplates from the exact chart+values Argo will use.
rendered="$(helm template webapp "${ROOT}/charts/webapp" -f "${ROOT}/${VALUES}" \
  -n webapp --show-only templates/gatekeeper-templates.yaml 2>/dev/null)"

if ! printf '%s' "$rendered" | grep -q 'kind: ConstraintTemplate'; then
  echo "  no ConstraintTemplates rendered (gatekeeper disabled?) — nothing to prime"
  exit 0
fi

printf '%s' "$rendered" | $K apply -f -

# Wait for Gatekeeper to generate + Establish each constraint CRD.
CRDS="k8sblockprivileged k8srequirenonroot k8srequirelimits k8sblockhostnamespaces k8sblockcaps"
TIMEOUT="${TIMEOUT:-150}"
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  ok=1
  for c in $CRDS; do
    est=$($K get crd "${c}.constraints.gatekeeper.sh" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
    if [ "$est" != "True" ]; then
      ok=0
      echo "  waiting for constraint CRD ${c}.constraints.gatekeeper.sh (established=${est:-absent})"
      break
    fi
  done
  if [ "$ok" -eq 1 ]; then
    echo "  Gatekeeper constraint CRDs Established"
    exit 0
  fi
  sleep 4
done

echo "  ERROR: Gatekeeper constraint CRDs not Established after ${TIMEOUT}s" >&2
echo "  Check: ${K} get constrainttemplates ; ${K} get crd | grep constraints.gatekeeper.sh" >&2
exit 1
