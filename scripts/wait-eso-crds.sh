#!/usr/bin/env bash
# Wait until External Secrets Operator's core CRDs exist AND are Established.
#
# Why this gate exists: the webapp Argo CD Application syncs ExternalSecret /
# SecretStore objects, so those CRDs must be servable BEFORE Argo first tries to
# reconcile the app. If Argo dry-runs an ExternalSecret while the CRD is missing
# it fails with `ExternalSecret.external-secrets.io "" not found`, and a bounded
# retry can give up permanently, leaving the app stuck OutOfSync/Missing.
#
# Looping (instead of a single `kubectl wait`, which errors immediately if the
# CRD doesn't exist yet) also rides out the rare window where a CRD is briefly
# Terminating from a prior uninstall before the fresh one registers.
#
# No root required.
set -uo pipefail

CTX="${KCTX:-k3d-webapp-test}"
K="kubectl --context ${CTX}"
CRDS="externalsecrets.external-secrets.io secretstores.external-secrets.io clustersecretstores.external-secrets.io"
TIMEOUT="${TIMEOUT:-240}"

deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  ok=1
  for crd in $CRDS; do
    est=$($K get crd "$crd" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
    if [ "$est" != "True" ]; then
      ok=0
      echo "  waiting for ESO CRD ${crd} (established=${est:-absent})"
      break
    fi
  done
  if [ "$ok" -eq 1 ]; then
    echo "  ESO CRDs Established"
    exit 0
  fi
  sleep 6
done

echo "  ERROR: ESO CRDs not Established after ${TIMEOUT}s" >&2
echo "  Check: ${K} get crd | grep external-secrets" >&2
exit 1
