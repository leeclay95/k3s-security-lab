variable "kms_key_arn" {
  description = "KMS CMK ARN from terraform/infra — output of: terraform output kms_key_arn"
  type        = string
  default     = ""
}

variable "db_password" {
  description = "Database password"
  type        = string
  sensitive   = true
  default     = "password123"
}

variable "api_key" {
  description = "API key"
  type        = string
  sensitive   = true
  default     = "supersecretkey"
}

variable "secret_key" {
  description = "App secret key"
  type        = string
  sensitive   = true
  default     = "s3cr3t-hardcoded-value"
}
