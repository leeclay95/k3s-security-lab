# Gatekeeper Helm chart installs the admission webhook controller.
# Gatekeeper policies (ConstraintTemplates + Constraints) are now deployed
# by the webapp Helm chart using hook annotations for proper CRD ordering,
# eliminating the previous null_resource + kubectl + time_sleep chain.

resource "helm_release" "gatekeeper" {
  depends_on       = [time_sleep.cluster_ready]
  name             = "gatekeeper"
  repository       = "https://open-policy-agent.github.io/gatekeeper/charts"
  chart            = "gatekeeper"
  namespace        = "gatekeeper-system"
  create_namespace = true
  wait             = true
  timeout          = 120
}

resource "time_sleep" "gatekeeper_ready" {
  depends_on      = [helm_release.gatekeeper]
  create_duration = "15s"
}
