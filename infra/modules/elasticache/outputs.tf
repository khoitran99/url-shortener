output "redis_endpoint" {
  value = aws_elasticache_cluster.this.cache_nodes[0].address
}
output "redis_port" {
  value = aws_elasticache_cluster.this.cache_nodes[0].port
}
output "redis_url" {
  value = "redis://${aws_elasticache_cluster.this.cache_nodes[0].address}:${aws_elasticache_cluster.this.cache_nodes[0].port}"
}
