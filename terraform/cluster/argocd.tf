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
    # Don't plant the Application until ESO's CRDs are servable — otherwise
    # Argo's first sync of the ExternalSecrets can fail and permanently give up.
    null_resource.eso_crds_ready,
    # ...and until Gatekeeper's constraint CRDs exist, or Argo's first sync
    # deadlocks on the Constraints (see gatekeeper.tf).
    null_resource.gatekeeper_crds_primed,
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

# Block the apply until Argo has actually brought the webapp UP. Planting the
# Application above is instant, but Argo then has to sync the chart, ESO has to
# fetch the secrets from floci, and the pod has to start. Without this gate
# `make deploy` returns "done" while the webapp is still Missing. The script
# polls the Application's health and issues one hard-refresh nudge if it stalls
# (e.g. Argo's discovery cache hasn't yet picked up a freshly-registered CRD).
resource "null_resource" "webapp_synced" {
  depends_on = [null_resource.webapp_application]

  triggers = {
    application = null_resource.webapp_application.id
  }

  provisioner "local-exec" {
    command = "${path.module}/../../scripts/wait-argo-healthy.sh webapp"
  }
}
