#!/usr/bin/env bash
# Ensure the webapp image is present in the k3d node's containerd, so the pod
# (imagePullPolicy: IfNotPresent) never tries to pull it. The node CANNOT pull
# the floci ECR ref at runtime — inside the node that hostname resolves to the
# node's own loopback — so the image must be loaded onto the node out-of-band.
#
# Two load paths, tried in order, because `k3d image import` silently no-ops on
# Docker's containerd-snapshotter image store (the default on recent Docker /
# Ubuntu): `docker save` there emits an OCI layout that the importer rejects with
# "content digest ... not found", yet reports success. So we verify after import
# and fall back to pulling the identical upstream image straight into the node's
# containerd (the node has internet even when the pod CNI is down) and retagging.
#
# Idempotent. Usage: ensure-webapp-image.sh [cluster-name]
set -u

CLUSTER="${1:-webapp-test}"
NODE="k3d-${CLUSTER}-server-0"
REF="000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100/webapp/nginx:1.27"
# The ECR image is a straight retag of this upstream image (see terraform/infra/
# ecr.tf — pull + tag + push, no build), so the content is identical.
SRC="docker.io/nginxinc/nginx-unprivileged:1.27"

present() { docker exec "$NODE" crictl images 2>/dev/null | grep -q 'webapp/nginx'; }

if present; then
	echo "ensure-image: $REF already on $NODE"
	exit 0
fi

# Path 1: k3d image import (works on the classic overlay2/docker image store).
echo "ensure-image: image missing — trying 'k3d image import'"
k3d image import "$REF" -c "$CLUSTER" >/dev/null 2>&1 || true
if present; then
	echo "ensure-image: loaded via k3d image import"
	exit 0
fi

# Path 2: containerd-snapshotter store breaks k3d/ctr import — pull upstream into
# the node's containerd and retag as the ECR ref the Deployment references.
echo "ensure-image: k3d import didn't land (containerd-snapshotter store?) — pulling upstream + retag"
docker exec "$NODE" crictl pull "$SRC"
docker exec "$NODE" ctr -n k8s.io images tag "$SRC" "$REF" 2>/dev/null || true
if present; then
	echo "ensure-image: loaded via pull+retag"
	exit 0
fi

echo "ensure-image: FAILED to load $REF onto $NODE" >&2
exit 1
