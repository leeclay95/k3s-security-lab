# The webapp and all its supporting resources (RBAC, ESO config, Gatekeeper policies)
# are now managed by a single Helm chart at charts/webapp/.
# This replaces the previous mix of kubernetes_deployment, kubernetes_service,
# null_resource kubectl calls, and loose YAML files.

resource "null_resource" "ecr_image_import" {
  depends_on = [time_sleep.cluster_ready]

  provisioner "local-exec" {
    command = "k3d image import 000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100/webapp/nginx:1.27 -c webapp-test"
  }
}

resource "helm_release" "webapp" {
  depends_on = [
    helm_release.gatekeeper,
    time_sleep.gatekeeper_ready,
    helm_release.eso,
    time_sleep.eso_ready,
    null_resource.ecr_image_import,
  ]

  name             = "webapp"
  chart            = "${path.module}/../../charts/webapp"
  namespace        = "webapp"
  create_namespace = true
  wait             = true
  timeout          = 120

  set {
    name  = "image.repository"
    value = "000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100/webapp/nginx"
  }

  set {
    name  = "image.tag"
    value = "1.27"
  }
}
