#!/usr/bin/env bash
# Preflight: verify Docker will push to the floci ECR registry over HTTP.
#
# The floci/LocalStack ECR endpoint serves plain HTTP. Docker only uses HTTP for
# a registry if it is EITHER explicitly listed in `insecure-registries` OR the
# host resolves into 127.0.0.0/8 (Docker auto-trusts loopback). On a box where
# `localhost.localstack.cloud` resolves to 127.0.0.1 (most distros) the push just
# works. On Ubuntu, systemd-resolved strips loopback answers from upstream DNS
# (DNS-rebinding protection), so the host no longer looks like loopback to Docker
# and the push fails deep inside `terraform apply` with the cryptic:
#     http: server gave HTTP response to HTTPS client
#
# This check fails FAST with the exact fix, before the multi-minute RDS apply.
# Skip with SKIP_DOCKER_PREFLIGHT=1 if you know your setup is fine.
set -u

REG="000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100"
HOST="${REG%:*}" # strip :5100

if [ "${SKIP_DOCKER_PREFLIGHT:-0}" = "1" ]; then
	echo "preflight: docker registry check skipped (SKIP_DOCKER_PREFLIGHT=1)"
	exit 0
fi

# 1) Explicitly configured as insecure in the running daemon? Definitive pass.
if docker info 2>/dev/null | grep -qF "$HOST"; then
	exit 0
fi

# 2) Does the host resolve to loopback (127.0.0.0/8 or ::1)? Docker auto-trusts
#    loopback as HTTP. Check every returned address, not just the first, since
#    getent may order IPv6 ahead of IPv4.
ips="$(getent hosts "$HOST" 2>/dev/null | awk '{print $1}')"
for ip in $ips; do
	case "$ip" in
		127.* | ::1)
			exit 0
			;;
	esac
done
# for the failure message, surface the first address we did see (if any)
ip="$(printf '%s' "$ips" | awk 'NR==1')"

# Otherwise the push will attempt HTTPS and fail. Print the fix and stop.
echo "=================================================================="
echo " PREFLIGHT FAIL: Docker can't push to the floci ECR registry over HTTP"
echo "=================================================================="
echo " Registry: $REG"
echo " Resolves to: ${ip:-<no loopback answer>} (not in 127.0.0.0/8, and not in"
echo " the daemon's insecure-registries), so Docker would try HTTPS and hit:"
echo "     http: server gave HTTP response to HTTPS client"
echo
echo " Fix (needs sudo — edits the Docker daemon config, then restarts it):"
echo
echo "   echo '{\"insecure-registries\":[\"$HOST\"]}' | sudo tee /etc/docker/daemon.json"
echo "   sudo systemctl restart docker"
echo
echo " If /etc/docker/daemon.json already exists, merge the key instead of"
echo " overwriting it, e.g. with jq:"
echo "   sudo jq '.\"insecure-registries\" += [\"$HOST\"]' /etc/docker/daemon.json | sudo tee /etc/docker/daemon.json.new && sudo mv /etc/docker/daemon.json.new /etc/docker/daemon.json && sudo systemctl restart docker"
echo
echo " Then re-run your make target. (Override this check: SKIP_DOCKER_PREFLIGHT=1)"
echo "=================================================================="
exit 1
