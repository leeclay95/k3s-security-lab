# Trivy Operator — continuous, in-cluster vulnerability + config scanning.
#
# OBSERVE-ONLY: it writes VulnerabilityReport / ConfigAuditReport /
# ExposedSecretReport / RbacAssessmentReport CRDs and never touches admission,
# so no workload is blocked. It is the RUNTIME twin of the CI-time trivy gate
# (scripts/security-gates.sh Gate 4): the gate blocks a bad image at PR time,
# the operator shows what is live in the cluster.
#
# Scan jobs download the vuln DB (~1-2GB) before scanning — the kubelet
# eviction floor is lowered in k3s-config.yaml so a small node tolerates that
# spike. See docs/trivy-operator.md for the full flow (incl. generating a report).

resource "helm_release" "trivy_operator" {
  depends_on       = [time_sleep.cluster_ready]
  name             = "trivy-operator"
  repository       = "https://aquasecurity.github.io/helm-charts/"
  chart            = "trivy-operator"
  version          = "0.34.0"
  namespace        = "trivy-system"
  create_namespace = true
  wait             = true
  # Generous timeout: first run pulls the operator image and the trivy vuln DB.
  timeout = 600

  values = [yamlencode({
    # Scope scanning to the app namespace ("" = whole cluster).
    targetNamespaces = "webapp"

    operator = {
      # Default is 10 — a burst of scan jobs can spike CPU/disk on a small node.
      scanJobsConcurrentLimit      = 1
      vulnerabilityScannerEnabled  = true
      configAuditScannerEnabled    = true
      exposedSecretScannerEnabled  = true
      rbacAssessmentScannerEnabled = true
    }

    trivyOperator = {
      # KEEP false. Scan jobs then run in trivy-system, NOT webapp, so the
      # deny-mode Gatekeeper constraints (scoped to webapp) can't reject them.
      scanJobsInSameNamespace = false
    }

    trivy = {
      # Line up with Gate 4: only fixable HIGH/CRITICAL.
      ignoreUnfixed = true
      severity      = "HIGH,CRITICAL"
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    }
  })]
}
