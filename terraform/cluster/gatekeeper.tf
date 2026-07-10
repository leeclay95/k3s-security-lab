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
  # Generous timeout: on slow networks the controller image pull (plus CRD
  # install hooks) can take several minutes. 120s was too short and left the
  # release in a failed state mid-pull.
  timeout          = 600
}

resource "time_sleep" "gatekeeper_ready" {
  depends_on      = [helm_release.gatekeeper]
  create_duration = "15s"
}

# Prime the Gatekeeper constraint CRDs BEFORE Argo plants the webapp app.
# The webapp chart bundles ConstraintTemplates + Constraints; Gatekeeper mints a
# constraint's CRD asynchronously from its template, so on a cold cluster the CRD
# doesn't exist when Argo first plans the sync. Argo then can't map the
# Constraints, marks the whole sync invalid, and applies nothing — including the
# templates that would create the CRDs (a permanent deadlock). Applying the
# templates here first breaks that cycle; Argo later adopts the identical
# templates from Git. argocd.tf's null_resource.webapp_application depends on
# this. Idempotent. Re-runs whenever the templates file changes.
resource "null_resource" "gatekeeper_crds_primed" {
  depends_on = [helm_release.gatekeeper, time_sleep.gatekeeper_ready]

  triggers = {
    templates = filesha256("${path.module}/../../charts/webapp/templates/gatekeeper-templates.yaml")
    values    = filesha256("${path.module}/../../charts/webapp/values-argocd.yaml")
  }

  provisioner "local-exec" {
    command = "${path.module}/../../scripts/prime-gatekeeper-crds.sh"
  }
}
