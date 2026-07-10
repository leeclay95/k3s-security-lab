#!/usr/bin/env bash
# Generic retry wrapper:  retry.sh <max_attempts> <sleep_seconds> <command...>
#
# Runs <command...> and, if it fails, retries up to <max_attempts> times with
# <sleep_seconds> between tries. Exists to ride out TRANSIENT Terraform failures
# on this resource-constrained box — most notably the AWS provider's
#   "timeout while waiting for plugin to start"
# which fires when the machine is briefly thrashing (high load starves the
# provider subprocess's gRPC handshake). All the terraform apply steps this
# wraps are idempotent, so a retry is always safe.
#
# No root required.
set -uo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: retry.sh <max_attempts> <sleep_seconds> <command...>" >&2
  exit 2
fi

max="$1"; delay="$2"; shift 2
n=1
while true; do
  "$@" && exit 0
  status=$?
  if [ "$n" -ge "$max" ]; then
    echo "retry.sh: command failed after ${n} attempt(s) (exit ${status}): $*" >&2
    exit "$status"
  fi
  echo "retry.sh: attempt ${n}/${max} failed (exit ${status}); retrying in ${delay}s..." >&2
  n=$((n + 1))
  sleep "$delay"
done
