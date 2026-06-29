output "kms_key_arn" {
  description = "ARN of the KMS CMK — pass to terraform/secrets/ as kms_key_arn variable"
  value       = aws_kms_key.secrets.arn
}

output "kms_key_alias" {
  value = aws_kms_alias.secrets.name
}

output "eso_role_arn" {
  description = "IAM role ARN for ESO SecretStore roleArn field"
  value       = aws_iam_role.eso.arn
}

output "eso_access_key_id" {
  description = "ESO IAM user access key — update aws-credentials K8s Secret"
  value       = aws_iam_access_key.eso.id
  sensitive   = true
}

output "eso_secret_access_key" {
  description = "ESO IAM user secret key — update aws-credentials K8s Secret"
  value       = aws_iam_access_key.eso.secret
  sensitive   = true
}

output "ecr_repository_url" {
  description = "LocalStack ECR URL — use as image in webapp deployment"
  value       = aws_ecr_repository.webapp.repository_url
}

output "rds_endpoint" {
  description = "RDS instance endpoint (host:port)"
  value       = "${aws_db_instance.webapp.address}:${aws_db_instance.webapp.port}"
}

output "sns_topic_arn" {
  value = aws_sns_topic.security_alerts.arn
}
