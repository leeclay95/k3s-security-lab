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
  # Generous timeout for slow-network image pulls (see gatekeeper.tf).
  timeout          = 600

  set {
    name  = "image.repository"
    value = "000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100/webapp/nginx"
  }

  set {
    name  = "image.tag"
    value = "1.27"
  }

  # Deployment, Service, ServiceAccount/RBAC, and the aws-credentials Secret
  # are all managed below as native kubernetes_* resources instead, so
  # terraform plan/apply drift-checks them directly. Only CRD-backed
  # resources (SecretStore, ExternalSecrets, Gatekeeper policies) stay
  # chart-managed — kubernetes_manifest would need those CRDs to exist at
  # plan time, which reintroduces the multi-pass fragility this design avoids.
  set {
    name  = "deployment.enabled"
    value = "false"
  }

  set {
    name  = "service.enabled"
    value = "false"
  }

  set {
    name  = "serviceAccount.enabled"
    value = "false"
  }

  set {
    name  = "awsCredentialsSecret.enabled"
    value = "false"
  }
}

resource "kubernetes_service_account" "webapp" {
  depends_on = [helm_release.webapp]

  metadata {
    name      = "webapp-sa"
    namespace = "webapp"
    labels    = { app = "webapp" }
  }

  automount_service_account_token = false
}

# kubernetes_role requires at least one "rule" block — can't express a
# truly empty ruleset directly. kubernetes_manifest could express "rules: []"
# literally, but its provider crashes on all-empty list attributes in nested
# blocks (confirmed: "plugin crashed" on rule{api_groups=[] resources=[]
# verbs=[]}). Narrowest real-world equivalent instead: read-only access to
# Events in this namespace only — nginx never calls the API, so this rule
# never actually gets exercised, but it's the tightest scope this provider
# will apply without crashing.
resource "kubernetes_role" "webapp" {
  depends_on = [helm_release.webapp]

  metadata {
    name      = "webapp-role"
    namespace = "webapp"
    labels    = { app = "webapp" }
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding" "webapp" {
  depends_on = [kubernetes_service_account.webapp, kubernetes_role.webapp]

  metadata {
    name      = "webapp-rolebinding"
    namespace = "webapp"
    labels    = { app = "webapp" }
  }

  subject {
    kind      = "ServiceAccount"
    name      = "webapp-sa"
    namespace = "webapp"
  }

  role_ref {
    kind      = "Role"
    api_group = "rbac.authorization.k8s.io"
    name      = "webapp-role"
  }
}

resource "kubernetes_secret" "aws_credentials" {
  depends_on = [helm_release.webapp]

  metadata {
    name      = "aws-credentials"
    namespace = "webapp"
    labels    = { app = "webapp" }
  }

  data = {
    "access-key"        = "test"
    "secret-access-key" = "test"
  }
}

resource "kubernetes_service" "webapp" {
  depends_on = [helm_release.webapp]

  metadata {
    name      = "webapp"
    namespace = "webapp"
    labels    = { app = "webapp" }
  }

  spec {
    type     = "NodePort"
    selector = { app = "webapp" }

    port {
      protocol    = "TCP"
      port        = 80
      target_port = 8080
      node_port   = 30080
    }
  }
}

resource "kubernetes_deployment" "webapp" {
  depends_on = [helm_release.webapp, kubernetes_service_account.webapp]

  metadata {
    name      = "webapp"
    namespace = "webapp"
    labels    = { app = "webapp" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "webapp" }
    }

    template {
      metadata {
        labels = { app = "webapp" }
      }

      spec {
        automount_service_account_token = false
        service_account_name            = "webapp-sa"

        container {
          name              = "webapp"
          image             = "000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100/webapp/nginx:1.27"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 8080
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "128Mi"
            }
          }

          security_context {
            privileged                 = false
            run_as_non_root            = true
            run_as_user                = 101
            run_as_group               = 101
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
            seccomp_profile {
              type = "RuntimeDefault"
            }
          }

          env {
            name = "SECRET_KEY"
            value_from {
              secret_key_ref {
                name = "webapp-secret"
                key  = "secret_key"
              }
            }
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "webapp-secret"
                key  = "db_password"
              }
            }
          }
          env {
            name = "DB_URL"
            value_from {
              secret_key_ref {
                name = "webapp-db-secret"
                key  = "db_url"
              }
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds         = 10
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 3
            period_seconds         = 5
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          volume_mount {
            name       = "nginx-cache"
            mount_path = "/var/cache/nginx"
          }
          volume_mount {
            name       = "nginx-run"
            mount_path = "/var/run"
          }
        }

        volume {
          name      = "tmp"
          empty_dir {}
        }
        volume {
          name      = "nginx-cache"
          empty_dir {}
        }
        volume {
          name      = "nginx-run"
          empty_dir {}
        }
      }
    }
  }
}
