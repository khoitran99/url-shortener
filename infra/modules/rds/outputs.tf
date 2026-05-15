output "endpoint"            { value = aws_db_instance.this.endpoint }
output "db_name"             { value = aws_db_instance.this.db_name }
output "db_username"         { value = aws_db_instance.this.username }
output "db_password_secret_arn" { value = aws_secretsmanager_secret.db_password.arn }
output "database_url" {
  value     = "postgresql://${aws_db_instance.this.username}:${urlencode(random_password.db.result)}@${aws_db_instance.this.endpoint}/${var.db_name}"
  sensitive = true
}
