output "app_url" {
  value       = "http://localhost:30080"
  description = "Webapp URL via NodePort — accessible from the Docker host"
}

output "helm_release" {
  value       = helm_release.webapp.name
  description = "Helm release name for the webapp chart"
}
