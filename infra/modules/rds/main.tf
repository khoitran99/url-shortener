resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project}/${var.env}/db-password"
  recovery_window_in_days = 7
  tags                    = { Name = "${var.project}-${var.env}-db-password" }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db.result
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-${var.env}-db-subnet-group"
  subnet_ids = var.private_subnets
  tags       = { Name = "${var.project}-${var.env}-db-subnet-group" }
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.project}-${var.env}-pg16"
  family = "postgres16"
  tags   = { Name = "${var.project}-${var.env}-pg16" }
}

resource "aws_db_instance" "this" {
  identifier             = "${var.project}-${var.env}"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.instance_class
  allocated_storage      = 20
  max_allocated_storage  = 100
  storage_encrypted      = true
  db_name                = var.db_name
  username               = var.db_username
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_sg_id]
  parameter_group_name   = aws_db_parameter_group.this.name
  skip_final_snapshot    = false
  final_snapshot_identifier = "${var.project}-${var.env}-final"
  backup_retention_period = 7
  deletion_protection    = true
  publicly_accessible    = false

  tags = { Name = "${var.project}-${var.env}-postgres" }
}
