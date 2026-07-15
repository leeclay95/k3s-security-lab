#!/usr/bin/env bash
# Local security gates — run the SAME checks CI will enforce, so you can verify
# before pushing. Three gates, all run (no short-circuit) so you see every
# failure at once. Evidence for each run is written under security/reports/<ts>/.
#
#   Gate 1  kubesec  — render the Helm chart (each value set), scan every
#                      workload, fail on a negative score or any scan error.
#   Gate 2  tfsec    — scan all terraform/ roots at --minimum-severity HIGH.
#   Gate 3  conftest — OPA policies (security/policy) mirroring the Gatekeeper
#                      constraints, run against each rendered chart.
#   Gate 4  trivy    — CVE scan of the container image, fail on fixable
#                      HIGH/CRITICAL vulnerabilities (RA-5 / SI-2).
#
# Both install paths are covered: values.yaml (Helm-hook path, renders the
# crd-wait Job) and values-argocd.yaml (Argo GitOps path).
#
# Overrides via env: CHART, CHART_VALUES (space-separated), POLICY_DIR, TF_DIR,
# TF_MIN_SEVERITY, KUBESEC_MIN_SCORE, SCAN_IMAGE, TRIVY_SEVERITY,
# TRIVY_IGNORE_UNFIXED, OUT_DIR.
set -uo pipefail

cd "$(dirname "$0")/.."

CHART="${CHART:-charts/webapp}"
CHART_VALUES="${CHART_VALUES:-values.yaml values-argocd.yaml}"
POLICY_DIR="${POLICY_DIR:-security/policy}"
TF_DIR="${TF_DIR:-terraform}"
TF_MIN_SEVERITY="${TF_MIN_SEVERITY:-HIGH}"
KUBESEC_MIN_SCORE="${KUBESEC_MIN_SCORE:-0}"
# The deployed image is a floci/LocalStack ECR ref that is unreachable outside
# the lab (and CI), so scan the identical upstream image it is retagged from
# (see scripts/ensure-webapp-image.sh + terraform/infra/ecr.tf — pull+tag+push,
# no build, so the content matches byte-for-byte).
SCAN_IMAGE="${SCAN_IMAGE:-docker.io/nginxinc/nginx-unprivileged:1.27}"
TRIVY_SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
# Only gate on vulnerabilities that have a fix available (an upgrade you can
# actually ship); set to 0 to also fail on un-fixable CVEs.
TRIVY_IGNORE_UNFIXED="${TRIVY_IGNORE_UNFIXED:-1}"
# Documented risk-acceptance register: known/accepted CVE IDs (with expiry) that
# should not fail the gate. NEW CVEs still fail. See the file's header comment.
TRIVY_IGNOREFILE="${TRIVY_IGNOREFILE:-security/trivy/.trivyignore.yaml}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT_DIR:-security/reports}/${TS}"
mkdir -p "$OUT"
ln -sfn "$TS" "${OUT_DIR:-security/reports}/latest"

SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"
log() { echo "$@" | tee -a "$SUMMARY"; }

fail_kubesec=0
fail_tfsec=0
fail_conftest=0
fail_trivy=0
RENDERS=()

log "=================================================================="
log " SECURITY GATES  ($TS)   evidence: $OUT"
log "=================================================================="

# ---- Render every value set once (shared by kubesec + conftest) ----------
for vf in $CHART_VALUES; do
	base="$(basename "$vf" .yaml)"
	r="$OUT/rendered-${base}.yaml"
	if helm template webapp "$CHART" -f "$CHART/$vf" > "$r" 2> "$OUT/helm-template-${base}.stderr"; then
		RENDERS+=("$r")
	else
		log "  helm template FAILED for $vf — see helm-template-${base}.stderr"
		fail_kubesec=1
		fail_conftest=1
	fi
done

# ---- Gate 1: kubesec on each rendered chart ------------------------------
log ""
log "── Gate 1: kubesec (workloads in each value set) ─────────────────"
for r in "${RENDERS[@]}"; do
	base="$(basename "$r" .yaml | sed 's/^rendered-//')"
	docs="$OUT/kubesec/${base}"
	mkdir -p "$docs"
	awk -v dir="$docs" 'BEGIN{n=0; f=sprintf("%s/doc_%03d.yaml", dir, n)} /^---[[:space:]]*$/{n++; f=sprintf("%s/doc_%03d.yaml", dir, n); next} {print >> f}' "$r"
	for d in "$docs"/*.yaml; do
		[ -s "$d" ] || continue
		kind="$(grep -m1 '^kind:' "$d" | awk '{print $2}')"
		case "$kind" in
			Deployment|StatefulSet|DaemonSet|ReplicaSet|Pod)
				rep="$docs/${kind}_$(basename "$d" .yaml).kubesec.json"
				kubesec scan "$d" > "$rep" 2> "$rep.err"
				score="$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(d[0]["score"] if isinstance(d,list) and d else "ERR")
except Exception:
    print("ERR")' "$rep")"
				if [ "$score" = "ERR" ]; then
					log "  [ERROR] ($base) $kind: kubesec could not scan (see $(basename "$rep").err)"
					fail_kubesec=1
				elif [ "$score" -lt "$KUBESEC_MIN_SCORE" ]; then
					log "  [FAIL]  ($base) $kind: score $score < min $KUBESEC_MIN_SCORE"
					fail_kubesec=1
				else
					log "  [PASS]  ($base) $kind: score $score"
				fi
				;;
		esac
	done
done

# ---- Gate 2: tfsec on all terraform roots (min severity HIGH) ------------
log ""
log "── Gate 2: tfsec (--minimum-severity $TF_MIN_SEVERITY) ───────────"
tfsec "$TF_DIR" --minimum-severity "$TF_MIN_SEVERITY" --format json --out "$OUT/tfsec.json" > /dev/null 2>&1
tfsec "$TF_DIR" --minimum-severity "$TF_MIN_SEVERITY" --no-color > "$OUT/tfsec.txt" 2>&1
tfsec_rc=$?
count="$(python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1])).get("results") or []))
except Exception: print("?")' "$OUT/tfsec.json" 2>/dev/null)"
if [ "$tfsec_rc" -ne 0 ]; then
	log "  [FAIL]  tfsec found $count finding(s) at >= $TF_MIN_SEVERITY (see tfsec.txt / tfsec.json)"
	fail_tfsec=1
else
	log "  [PASS]  no findings at >= $TF_MIN_SEVERITY"
fi

# ---- Gate 3: conftest (OPA) on each rendered chart -----------------------
log ""
log "── Gate 3: conftest / OPA (security/policy) ──────────────────────"
for r in "${RENDERS[@]}"; do
	base="$(basename "$r" .yaml | sed 's/^rendered-//')"
	conftest test "$r" --policy "$POLICY_DIR" --output json > "$OUT/conftest-${base}.json" 2> "$OUT/conftest-${base}.err"
	conftest test "$r" --policy "$POLICY_DIR" --no-color > "$OUT/conftest-${base}.txt" 2>&1
	rc=$?
	fails="$(python3 -c 'import json,sys
try: print(sum(len(x.get("failures") or []) for x in json.load(open(sys.argv[1]))))
except Exception: print("?")' "$OUT/conftest-${base}.json" 2>/dev/null)"
	if [ "$rc" -ne 0 ]; then
		log "  [FAIL]  ($base) $fails policy failure(s) (see conftest-${base}.txt)"
		fail_conftest=1
	else
		log "  [PASS]  ($base) all policies satisfied"
	fi
done
[ "${#RENDERS[@]}" -eq 0 ] && { log "  [SKIP]  no rendered manifests"; fail_conftest=1; }

# ---- Gate 4: trivy image CVE scan ----------------------------------------
log ""
log "── Gate 4: trivy (image CVEs >= $TRIVY_SEVERITY) ─────────────────"
if ! command -v trivy >/dev/null 2>&1; then
	log "  [ERROR] trivy not installed — cannot scan $SCAN_IMAGE"
	fail_trivy=1
else
	tflags=(--severity "$TRIVY_SEVERITY" --scanners vuln --no-progress)
	[ "$TRIVY_IGNORE_UNFIXED" = "1" ] && tflags+=(--ignore-unfixed)
	if [ -f "$TRIVY_IGNOREFILE" ]; then
		tflags+=(--ignorefile "$TRIVY_IGNOREFILE")
		log "  [note]  risk-acceptance register active: $TRIVY_IGNOREFILE"
	fi
	# Capture full JSON evidence first (exit-code 0 so the report always writes).
	trivy image "${tflags[@]}" --format json --output "$OUT/trivy.json" "$SCAN_IMAGE" > "$OUT/trivy.log" 2>&1
	# Human-readable table + the gating run (non-zero exit on any matching vuln).
	trivy image "${tflags[@]}" --exit-code 1 --format table "$SCAN_IMAGE" > "$OUT/trivy.txt" 2>> "$OUT/trivy.log"
	trivy_rc=$?
	vulns="$(python3 -c 'import json,sys
try: print(sum(len(r.get("Vulnerabilities") or []) for r in (json.load(open(sys.argv[1])).get("Results") or [])))
except Exception: print("?")' "$OUT/trivy.json" 2>/dev/null)"
	if [ "$trivy_rc" -ne 0 ]; then
		log "  [FAIL]  $SCAN_IMAGE: $vulns vuln(s) at >= $TRIVY_SEVERITY (see trivy.txt / trivy.json)"
		fail_trivy=1
	else
		log "  [PASS]  $SCAN_IMAGE: no gating vuln(s) at >= $TRIVY_SEVERITY"
	fi
fi

# ---- Verdict --------------------------------------------------------------
log ""
log "=================================================================="
overall=$((fail_kubesec + fail_tfsec + fail_conftest + fail_trivy))
log " kubesec:  $([ $fail_kubesec -eq 0 ] && echo PASS || echo FAIL)"
log " tfsec:    $([ $fail_tfsec  -eq 0 ] && echo PASS || echo FAIL)"
log " conftest: $([ $fail_conftest -eq 0 ] && echo PASS || echo FAIL)"
log " trivy:    $([ $fail_trivy -eq 0 ] && echo PASS || echo FAIL)"
log " OVERALL:  $([ $overall -eq 0 ] && echo PASS || echo FAIL)   evidence: $OUT"
log "=================================================================="
exit $([ $overall -eq 0 ] && echo 0 || echo 1)
