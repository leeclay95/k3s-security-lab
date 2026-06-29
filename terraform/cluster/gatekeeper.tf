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

# null_resource + kubectl avoids kubernetes_manifest plan-time CRD validation.
# ConstraintTemplates create the Constraint CRDs dynamically at apply time,
# so kubernetes_manifest can never plan them in the same run.
resource "null_resource" "gatekeeper_templates" {
  depends_on = [time_sleep.gatekeeper_ready]

  provisioner "local-exec" {
    command = "kubectl apply -f /home/kali/floci/k3-test/gatekeeper-templates.yaml"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f /home/kali/floci/k3-test/gatekeeper-templates.yaml --ignore-not-found"
  }
}

resource "time_sleep" "crds_ready" {
  depends_on      = [null_resource.gatekeeper_templates]
  create_duration = "10s"
}

resource "null_resource" "gatekeeper_constraints" {
  depends_on = [time_sleep.crds_ready]

  provisioner "local-exec" {
    command = "kubectl apply -f /home/kali/floci/k3-test/gatekeeper-constraints.yaml"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f /home/kali/floci/k3-test/gatekeeper-constraints.yaml --ignore-not-found"
  }
}
