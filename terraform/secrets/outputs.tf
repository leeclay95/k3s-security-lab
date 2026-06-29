output "secret_arn" {
  value = aws_secretsmanager_secret.webapp.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.webapp.name
}
