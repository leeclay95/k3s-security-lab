variable "db_password" {
  description = "RDS Postgres password — also written to webapp/db-credentials in Secrets Manager"
  type        = string
  sensitive   = true
  default     = "password123"
}
