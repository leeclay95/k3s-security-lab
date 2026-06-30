# ESO Helm chart installs the External Secrets Operator controller.
# SecretStore, ExternalSecrets, and AWS credentials are now deployed
# by the webapp Helm chart — no more null_resource kubectl calls.
#
# The previous kubectl set env hack for LocalStack endpoints is replaced
# by extraEnv Helm values passed directly to the ESO chart.

resource "helm_release" "eso" {
  depends_on       = [time_sleep.cluster_ready]
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  timeout          = 120

  # LocalStack endpoint configuration — replaces the post-install kubectl set env hack.
  # These env vars tell the ESO controller where to find Secrets Manager and STS.
  set {
    name  = "extraEnv[0].name"
    value = "AWS_ENDPOINT_URL_SECRETS_MANAGER"
  }
  set {
    name  = "extraEnv[0].value"
    value = "http://host.k3d.internal:4566"
  }
  set {
    name  = "extraEnv[1].name"
    value = "AWS_ENDPOINT_URL_STS"
  }
  set {
    name  = "extraEnv[1].value"
    value = "http://host.k3d.internal:4566"
  }
}

resource "time_sleep" "eso_ready" {
  depends_on      = [helm_release.eso]
  create_duration = "10s"
}
