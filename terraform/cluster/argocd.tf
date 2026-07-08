# Argo CD — installed by Terraform as day-0 platform (like Gatekeeper and ESO),
# then handed the webapp to own via GitOps.
#
# TF installs the controller and applies the Application manifest; from that
# point Argo CD is the sole reconciler of the webapp namespace, syncing
# charts/webapp from Git and self-healing any out-of-band drift. TF no longer
# manages the webapp app-layer (see webapp.tf).

resource "helm_release" "argocd" {
  depends_on       = [time_sleep.cluster_ready]
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  # Generous timeout: the argo-cd chart pulls several images (server, repo-server,
  # application-controller, redis, dex, applicationset) — slow on a constrained link.
  timeout = 600
}

resource "time_sleep" "argocd_ready" {
  depends_on      = [helm_release.argocd]
  create_duration = "20s"
}

# The Application is a CRD that only exists after the Argo release is installed,
# so — like the ESO SecretStore and Gatekeeper policies — it's applied with
# null_resource + kubectl rather than kubernetes_manifest (which would validate
# the CRD at plan time, before Argo exists). depends_on the image import so the
# node has the webapp image before Argo's first sync (else a transient
# ImagePullBackOff that self-heals).
resource "null_resource" "webapp_application" {
  depends_on = [
    helm_release.argocd,
    time_sleep.argocd_ready,
    null_resource.ecr_image_import,
  ]

  triggers = {
    manifest = filesha256("${path.module}/../../argocd/webapp-application.yaml")
  }

  provisioner "local-exec" {
    command = "kubectl --context k3d-webapp-test apply -f ${path.module}/../../argocd/webapp-application.yaml"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl --context k3d-webapp-test delete -f ${path.module}/../../argocd/webapp-application.yaml --ignore-not-found=true"
  }
}
