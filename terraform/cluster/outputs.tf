output "app_url" {
  value       = "http://localhost:30080"
  description = "Webapp URL via NodePort — accessible from the Docker host"
}

output "webapp_owner" {
  value       = "argocd/Application:webapp (GitOps) — see: kubectl get application webapp -n argocd"
  description = "The webapp is reconciled by Argo CD, not Terraform"
}
