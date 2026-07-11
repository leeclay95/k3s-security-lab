# The webapp is now owned by Argo CD (GitOps), not Terraform. Argo renders the
# whole charts/webapp chart from Git and continuously reconciles it — see
# argocd.tf (helm_release.argocd + null_resource.webapp_application) and
# argocd/webapp-application.yaml.
#
# Terraform's only remaining webapp responsibility is a node-level bootstrap
# Argo can't do: loading the webapp image onto the k3d node. Argo applies
# manifests but never runs `k3d image import`, and the pod pulls with
# imagePullPolicy: IfNotPresent, so the image must be present on the node before
# Argo's first sync.

resource "null_resource" "ecr_image_import" {
  depends_on = [time_sleep.cluster_ready]

  # Load the image onto the node robustly. `k3d image import` silently no-ops on
  # Docker's containerd-snapshotter store (default on recent Docker/Ubuntu), so
  # this helper verifies the image actually landed and falls back to a
  # pull+retag if not. See scripts/ensure-webapp-image.sh.
  provisioner "local-exec" {
    command = "${path.module}/../../scripts/ensure-webapp-image.sh webapp-test"
  }
}
