#!/usr/bin/env bash
# Make host.k3d.internal resolve durably from inside the cluster.
#
# k3d injects a `host.k3d.internal -> docker-gateway` record into CoreDNS's
# NodeHosts configmap at cluster CREATE time, but k3s reconciles NodeHosts and
# strips it back out after any node-container restart (host reboot / docker
# restart). ESO then can't reach floci (the AWS emulator) at
# host.k3d.internal:4566 and every SecretStore flips to InvalidProviderConfig.
#
# Fix: publish the same mapping through k3s's coredns-custom extension point
# (the stock Corefile imports `/etc/coredns/custom/*.server`), which k3s does
# NOT reconcile away — so it survives reboots and cluster restarts.
set -euo pipefail

CLUSTER="${1:-webapp-test}"
CONTEXT="k3d-${CLUSTER}"
NET="k3d-${CLUSTER}"

# Derive the docker-network gateway the node reaches the host through, rather
# than hardcoding an IP: the subnet can change when the cluster is recreated.
# This is the same address k3d logs as "network gateway".
GW="$(docker network inspect "${NET}" -f '{{ (index .IPAM.Config 0).Gateway }}' 2>/dev/null || true)"
if [ -z "${GW}" ]; then
  echo "coredns-hostfix: could not determine gateway for docker network ${NET}" >&2
  exit 1
fi

echo "coredns-hostfix: mapping host.k3d.internal -> ${GW} via coredns-custom"
kubectl --context "${CONTEXT}" -n kube-system apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  k3d-host.server: |
    host.k3d.internal:53 {
        hosts {
            ${GW} host.k3d.internal
            fallthrough
        }
    }
EOF

# Roll CoreDNS so it imports the new server block immediately (otherwise the
# plugin only reloads on its own ~30s cadence).
kubectl --context "${CONTEXT}" -n kube-system rollout restart deployment/coredns
kubectl --context "${CONTEXT}" -n kube-system rollout status deployment/coredns --timeout=90s
