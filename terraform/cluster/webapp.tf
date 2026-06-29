resource "kubernetes_namespace" "webapp" {
  depends_on = [time_sleep.cluster_ready]
  metadata {
    name = "webapp"
  }
}

# kubernetes_role with verbs=[] is rejected by the provider even though it is valid K8s.
# kubernetes_service_account must exist before the deployment uses it, so we apply
# the serviceaccount.yaml (SA + zero-permission Role + RoleBinding) via kubectl.
resource "null_resource" "webapp_rbac" {
  depends_on = [kubernetes_namespace.webapp]

  provisioner "local-exec" {
    command = "kubectl apply -f /home/kali/floci/k3-test/serviceaccount.yaml"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f /home/kali/floci/k3-test/serviceaccount.yaml --ignore-not-found"
  }
}

# Import the ECR image directly into k3d node containerd so the cluster
# doesn't need to pull from LocalStack ECR at runtime (no imagePullSecret needed).
resource "null_resource" "ecr_image_import" {
  depends_on = [time_sleep.cluster_ready]

  provisioner "local-exec" {
    command = "k3d image import 000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100/webapp/nginx:1.27 -c webapp-test"
  }
}

resource "kubernetes_deployment" "webapp" {
  depends_on = [
    null_resource.eso_externalsecret,
    null_resource.eso_db_externalsecret,
    null_resource.gatekeeper_constraints,
    null_resource.webapp_rbac,
    null_resource.ecr_image_import,
  ]

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
        service_account_name            = "webapp-sa"
        automount_service_account_token = false

        container {
          name  = "webapp"
          image              = "000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100/webapp/nginx:1.27"
          image_pull_policy  = "IfNotPresent"

          port {
            container_port = 8080
          }

          resources {
            requests = { cpu = "100m", memory = "64Mi" }
            limits   = { cpu = "250m", memory = "128Mi" }
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
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 3
            period_seconds        = 5
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
          name = "tmp"
          empty_dir {}
        }
        volume {
          name = "nginx-cache"
          empty_dir {}
        }
        volume {
          name = "nginx-run"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "webapp" {
  depends_on = [kubernetes_namespace.webapp]
  metadata {
    name      = "webapp"
    namespace = "webapp"
  }
  spec {
    type     = "NodePort"
    selector = { app = "webapp" }
    port {
      port        = 80
      target_port = 8080
      node_port   = 30080
    }
  }
}
