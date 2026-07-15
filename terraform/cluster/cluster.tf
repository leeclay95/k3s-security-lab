resource "null_resource" "k3d_cluster" {
  # Audit logging: mount the policy and point the kube-apiserver at it, writing
  # audit events to /var/log/k3s-audit.log on the node (the log shipper forwards
  # that to floci CloudWatch /k8s/webapp/audit). Captures exec/attach, workload
  # lifecycle, secret access, RBAC, and webapp pod events.
  # Mount audit-policy.yaml + k3s-config.yaml (kubelet eviction tuning for Trivy
  # Operator scan jobs — see k3s-config.yaml) into the node; point the
  # kube-apiserver at the audit policy. k3s auto-reads /etc/rancher/k3s/config.yaml.
  provisioner "local-exec" {
    command = "k3d cluster create webapp-test --port 8080:80@loadbalancer --port 30080:30080@server:0 --registry-config ${path.module}/../../registries.yaml --volume ${abspath(path.module)}/audit-policy.yaml:/etc/rancher/k3s/audit-policy.yaml@server:0 --volume ${abspath(path.module)}/k3s-config.yaml:/etc/rancher/k3s/config.yaml@server:0 --k3s-arg --kube-apiserver-arg=audit-policy-file=/etc/rancher/k3s/audit-policy.yaml@server:0 --k3s-arg --kube-apiserver-arg=audit-log-path=/var/log/k3s-audit.log@server:0 --k3s-arg --kube-apiserver-arg=audit-log-maxage=7@server:0"
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
