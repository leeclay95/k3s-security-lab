resource "aws_ecr_repository" "webapp" {
  name                 = "webapp/nginx"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { project = "webapp-lab" }
}

# LocalStack ECR Docker registry runs at port 5100 (not 4566).
# Registry hostname: 000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100
# — localhost.localstack.cloud resolves to 127.0.0.1 via public DNS.
resource "null_resource" "ecr_push" {
  depends_on = [aws_ecr_repository.webapp]

  provisioner "local-exec" {
    command = "docker pull nginxinc/nginx-unprivileged:1.27 && docker tag nginxinc/nginx-unprivileged:1.27 000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100/webapp/nginx:1.27 && AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 aws --endpoint-url=http://localhost:4566 ecr get-login-password | docker login --username AWS --password-stdin 000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100 && docker push 000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:5100/webapp/nginx:1.27"
  }
}
