resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.project}-${var.env}-redis-subnet"
  subnet_ids = var.private_subnets
  tags       = { Name = "${var.project}-${var.env}-redis-subnet" }
}

resource "aws_elasticache_cluster" "this" {
  cluster_id           = "${var.project}-${var.env}-redis"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.node_type
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [var.redis_sg_id]
  port                 = 6379

  tags = { Name = "${var.project}-${var.env}-redis" }
}
