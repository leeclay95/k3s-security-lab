resource "aws_secretsmanager_secret" "webapp" {
  name                    = "webapp/secrets"
  description             = "webapp app secrets synced into k3s via ESO"
  kms_key_id              = var.kms_key_arn != "" ? var.kms_key_arn : null
  recovery_window_in_days = 0

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "webapp" {
  secret_id = aws_secretsmanager_secret.webapp.id

  secret_string = jsonencode({
    db_password = var.db_password
    api_key     = var.api_key
    secret_key  = var.secret_key
  })
}
