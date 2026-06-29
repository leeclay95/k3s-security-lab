resource "null_resource" "k3d_cluster" {
  provisioner "local-exec" {
    command = "k3d cluster create webapp-test --port 8080:80@loadbalancer --registry-config /home/kali/floci/k3-test/registries.yaml"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete webapp-test"
  }
}

# give the cluster API server time to become ready before providers connect
resource "time_sleep" "cluster_ready" {
  depends_on      = [null_resource.k3d_cluster]
  create_duration = "15s"
}
