#!/usr/bin/env bash
# make reboot — diagnose and auto-heal the lab after a host reboot.
#
# A reboot restarts the k3d node container, which reliably breaks several things
# that a plain `kubectl get pods` won't explain:
#   1. floci (the AWS emulator) may be down / lost un-flushed data
#   2. the k3d cluster is stopped
#   3. flannel's /run/flannel/subnet.env is on tmpfs -> wiped -> pod sandboxes
#      fail ("failed to setup network ... open /run/flannel/subnet.env")
#   4. host.k3d.internal is stripped from CoreDNS -> ESO can't reach floci
#      ("dial tcp: lookup host.k3d.internal ... i/o timeout")
#   5. the webapp image can drop out of the node's containerd -> ImagePullBackOff
#
# This script checks each, reports what it finds, and fixes it. Idempotent and
# safe to run anytime (not just after a reboot). It does NOT touch Terraform
# state, floci secrets, or the infra/secrets roots.
set -u

CLUSTER="webapp-test"
CTX="k3d-${CLUSTER}"
NODE="k3d-${CLUSTER}-server-0"
KUBECTL="kubectl --context ${CTX}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

step() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  [ok]  %s\n' "$1"; }
fix()  { printf '  [fix] %s\n' "$1"; }
warn() { printf '  [!]   %s\n' "$1"; }

# 1. floci ------------------------------------------------------------------
step "floci AWS emulator (:4566)"
if curl -sf http://localhost:4566/_localstack/health >/dev/null 2>&1; then
	ok "floci reachable"
else
	fix "floci down — starting via docker compose"
	(cd "$ROOT" && docker compose -p floci up -d >/dev/null 2>&1) || true
	for i in $(seq 1 30); do
		curl -sf http://localhost:4566/_localstack/health >/dev/null 2>&1 && break
		sleep 2
	done
	curl -sf http://localhost:4566/_localstack/health >/dev/null 2>&1 && ok "floci back up" || warn "floci still unreachable — check 'docker compose -p floci ps'"
fi

# 2. cluster running --------------------------------------------------------
step "k3d cluster"
if ! k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
	warn "cluster '$CLUSTER' does not exist — run 'make deploy' first"
	exit 1
fi
if docker inspect -f '{{.State.Running}}' "$NODE" 2>/dev/null | grep -q true; then
	ok "node container running"
else
	fix "node stopped — starting cluster"
	k3d cluster start "$CLUSTER" >/dev/null 2>&1 || true
fi

# 3. node Ready + flannel CNI ----------------------------------------------
step "node readiness + flannel CNI"
$KUBECTL wait --for=condition=Ready node --all --timeout=120s >/dev/null 2>&1 || true
if docker exec "$NODE" test -f /run/flannel/subnet.env 2>/dev/null; then
	ok "flannel subnet.env present"
else
	fix "flannel subnet.env missing — bouncing node to reinitialize CNI"
	k3d cluster stop "$CLUSTER" >/dev/null 2>&1 && k3d cluster start "$CLUSTER" >/dev/null 2>&1 || true
	$KUBECTL wait --for=condition=Ready node --all --timeout=120s >/dev/null 2>&1 || true
	if docker exec "$NODE" test -f /run/flannel/subnet.env 2>/dev/null; then
		ok "flannel recovered"
	else
		warn "flannel still missing — inspect 'docker logs $NODE'"
	fi
fi

# 4. host.k3d.internal (ESO -> floci) --------------------------------------
step "host.k3d.internal resolution (ESO -> floci)"
fix "re-asserting host.k3d.internal (durable coredns-custom mapping)"
"$DIR/coredns-hostfix.sh" "$CLUSTER" >/dev/null 2>&1 && ok "coredns host-fix applied" || warn "coredns-hostfix.sh failed"

# 5. webapp image on the node ----------------------------------------------
step "webapp image on node"
"$DIR/ensure-webapp-image.sh" "$CLUSTER" || warn "could not load webapp image — see output above"

# 6. External Secrets re-sync ----------------------------------------------
step "External Secrets (force re-sync from floci)"
$KUBECTL -n external-secrets rollout restart deploy/external-secrets >/dev/null 2>&1 || true
$KUBECTL -n external-secrets rollout status deploy/external-secrets --timeout=90s >/dev/null 2>&1 || true
ok "ESO controller restarted"

# 7. log shipper ------------------------------------------------------------
step "CloudWatch log shipper"
if $KUBECTL apply -f "$ROOT/logging/cloudwatch-log-shipper.yaml" >/dev/null 2>&1; then
	ok "log-shipper applied"
else
	warn "log-shipper apply failed"
fi

# 8. nudge the webapp workload ---------------------------------------------
step "webapp workload"
$KUBECTL -n webapp delete pod -l app=webapp >/dev/null 2>&1 || true
$KUBECTL -n webapp rollout status deploy/webapp --timeout=120s >/dev/null 2>&1 || true

# 9. final status -----------------------------------------------------------
step "status"
$KUBECTL -n webapp get pods 2>/dev/null || true
echo
$KUBECTL -n webapp get externalsecret 2>/dev/null || true
code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:30080 2>/dev/null)"
echo
if [ "$code" = "200" ]; then
	ok "app responding: HTTP $code at http://localhost:30080"
else
	warn "app HTTP $code (expected 200). If ExternalSecret shows SecretSyncedError,"
	warn "floci may have lost its secrets on reboot — reseed with 'make bootstrap'."
fi
