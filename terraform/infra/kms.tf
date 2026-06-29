resource "aws_kms_key" "secrets" {
  description             = "CMK for webapp Secrets Manager secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = { project = "webapp-lab" }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/webapp-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}
