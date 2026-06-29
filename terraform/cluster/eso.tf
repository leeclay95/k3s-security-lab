resource "helm_release" "eso" {
  depends_on       = [time_sleep.cluster_ready]
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  timeout          = 120
}

# Helm set env syntax does not work for ESO chart — patch the deployment directly after install
resource "null_resource" "eso_endpoint" {
  depends_on = [helm_release.eso]

  provisioner "local-exec" {
    command = "kubectl set env deployment/external-secrets -n external-secrets AWS_ENDPOINT_URL_SECRETS_MANAGER=http://host.k3d.internal:4566 AWS_ENDPOINT_URL_STS=http://host.k3d.internal:4566 && kubectl rollout status deployment/external-secrets -n external-secrets --timeout=60s"
  }
}

resource "time_sleep" "eso_ready" {
  depends_on      = [null_resource.eso_endpoint]
  create_duration = "10s"
}

resource "kubernetes_secret" "aws_credentials" {
  depends_on = [kubernetes_namespace.webapp]
  metadata {
    name      = "aws-credentials"
    namespace = "webapp"
  }
  data = {
    access-key        = "test"
    secret-access-key = "test"
  }
}

# SecretStore and ExternalSecret use ESO CRDs installed by Helm above.
# kubectl avoids plan-time validation failure when CRDs don't exist yet.
resource "null_resource" "eso_secretstore" {
  depends_on = [time_sleep.eso_ready, kubernetes_secret.aws_credentials]

  provisioner "local-exec" {
    command = "kubectl apply -f /home/kali/floci/k3-test/eso-secretstore.yaml"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f /home/kali/floci/k3-test/eso-secretstore.yaml --ignore-not-found"
  }
}

resource "null_resource" "eso_externalsecret" {
  depends_on = [null_resource.eso_secretstore]

  provisioner "local-exec" {
    command = "kubectl apply -f /home/kali/floci/k3-test/eso-externalsecret.yaml"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f /home/kali/floci/k3-test/eso-externalsecret.yaml --ignore-not-found"
  }
}

resource "null_resource" "eso_db_externalsecret" {
  depends_on = [null_resource.eso_secretstore]

  provisioner "local-exec" {
    command = "kubectl apply -f /home/kali/floci/k3-test/eso-db-externalsecret.yaml"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f /home/kali/floci/k3-test/eso-db-externalsecret.yaml --ignore-not-found"
  }
}
