output "node_ip" {
  value       = "172.24.0.2"
  description = "k3d node IP — access app at http://172.24.0.2:30080"
}

output "app_url" {
  value       = "http://172.24.0.2:30080"
  description = "Direct NodePort URL for the webapp"
}
