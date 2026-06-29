resource "aws_db_instance" "webapp" {
  identifier          = "webapp-db"
  engine              = "postgres"
  engine_version      = "13.7"
  instance_class      = "db.t3.micro"
  allocated_storage   = 20
  db_name             = "webapp"
  username            = "webapp"
  password            = var.db_password
  skip_final_snapshot        = true
  publicly_accessible        = false
  auto_minor_version_upgrade = false
  storage_encrypted          = true
  kms_key_id                 = aws_kms_key.secrets.arn
  # LocalStack community does not support AddTagsToResource for RDS
}

# Store the connection string in Secrets Manager so ESO can sync it into the pod.
# Pods cannot actually reach this RDS endpoint in the local lab (LocalStack RDS is
# simulated), but this proves the pattern: DB creds never touch the manifest.
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "webapp/db-credentials"
  description             = "RDS connection string for webapp — synced into pods by ESO"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 0

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  secret_string = jsonencode({
    db_url      = "postgresql://webapp:${var.db_password}@${aws_db_instance.webapp.address}:${aws_db_instance.webapp.port}/webapp"
    db_host     = aws_db_instance.webapp.address
    db_port     = tostring(aws_db_instance.webapp.port)
    db_name     = "webapp"
    db_username = "webapp"
    db_password = var.db_password
  })
}
