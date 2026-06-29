# Resolve the ARN of webapp/secrets created in terraform/secrets/ so the IAM
# policy can reference exact ARNs instead of a wildcard resource path.
# Requires terraform/secrets/ to be applied before terraform/infra/.
data "aws_secretsmanager_secret" "webapp" {
  name = "webapp/secrets"
}

# IAM user ESO authenticates with — only permission is to assume the ESO role.
# Replaces the static test/test root creds currently in aws-credentials K8s Secret.
resource "aws_iam_user" "eso" {
  name = "eso-user"
  tags = { project = "webapp-lab" }
}

resource "aws_iam_access_key" "eso" {
  user = aws_iam_user.eso.name
}

resource "aws_iam_user_policy" "eso_assume" {
  name = "eso-assume-role"
  user = aws_iam_user.eso.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = aws_iam_role.eso.arn
    }]
  })
}

# Trust policy — only the ESO IAM user can assume this role
resource "aws_iam_role" "eso" {
  name = "eso-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_user.eso.arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { project = "webapp-lab" }
}

# Role can only read the two explicit secret ARNs — no wildcard resources
resource "aws_iam_role_policy" "eso_secrets" {
  name = "eso-secrets-policy"
  role = aws_iam_role.eso.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          data.aws_secretsmanager_secret.webapp.arn,
          aws_secretsmanager_secret.db_credentials.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.secrets.arn
      }
    ]
  })
}
