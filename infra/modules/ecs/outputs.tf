output "cluster_name"             { value = aws_ecs_cluster.this.name }
output "cluster_arn"              { value = aws_ecs_cluster.this.arn }
output "service_name"             { value = aws_ecs_service.api.name }
output "task_definition_family"   { value = aws_ecs_task_definition.api.family }
output "database_url_secret_arn"  { value = aws_secretsmanager_secret.database_url.arn }
