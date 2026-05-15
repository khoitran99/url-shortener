terraform {
  required_version = ">= 1.7"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }

  # Fill in after running infra/bootstrap — copy the output values here.
  backend "s3" {
    bucket         = "url-shortener-tf-state-651410557077"
    key            = "prod/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "url-shortener-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "terraform"
    }
  }
}

# Required for CloudFront ACM certificates (must be in us-east-1)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "terraform"
    }
  }
}

# ── Networking ────────────────────────────────────────────────────────────────

module "networking" {
  source             = "../../modules/networking"
  project            = var.project
  env                = var.env
  vpc_cidr           = "10.0.0.0/16"
  enable_nat_gateway = var.enable_nat_gateway
}

# ── ECR ───────────────────────────────────────────────────────────────────────

module "ecr" {
  source  = "../../modules/ecr"
  project = var.project
  env     = var.env
}

# ── ALB + ACM + Route 53 (api.<domain>) ──────────────────────────────────────

module "alb" {
  source         = "../../modules/alb"
  project        = var.project
  env            = var.env
  vpc_id         = module.networking.vpc_id
  public_subnets = module.networking.public_subnets
  alb_sg_id      = module.networking.alb_sg_id
  api_domain     = var.api_domain
  hosted_zone_id = var.hosted_zone_id
}

# ── RDS PostgreSQL ────────────────────────────────────────────────────────────

module "rds" {
  source          = "../../modules/rds"
  project         = var.project
  env             = var.env
  private_subnets = module.networking.private_subnets
  rds_sg_id       = module.networking.rds_sg_id
  instance_class  = "db.t4g.micro"
  db_name         = var.db_name
  db_username     = var.db_username
}

# ── ElastiCache Redis ─────────────────────────────────────────────────────────

module "elasticache" {
  source          = "../../modules/elasticache"
  project         = var.project
  env             = var.env
  private_subnets = module.networking.private_subnets
  redis_sg_id     = module.networking.redis_sg_id
  node_type       = "cache.t4g.micro"
}

# ── ECS Fargate ───────────────────────────────────────────────────────────────

module "ecs" {
  source             = "../../modules/ecs"
  project            = var.project
  env                = var.env
  region             = var.region
  vpc_id             = module.networking.vpc_id
  private_subnets    = module.networking.private_subnets
  ecs_sg_id          = module.networking.ecs_sg_id
  target_group_arn   = module.alb.target_group_arn
  ecr_repository_url = module.ecr.repository_url
  image_tag          = var.image_tag
  # Pass the resolved DATABASE_URL — ECS module stores it in Secrets Manager
  database_url_secret_arn = module.rds.database_url
  redis_url               = module.elasticache.redis_url
  base_url                = "https://${var.api_domain}"
  task_cpu                = 256
  task_memory             = 512
  desired_count           = 1
}

# ── CloudFront + S3 + ACM (<domain>) ─────────────────────────────────────────

module "cdn" {
  source         = "../../modules/cdn"
  project        = var.project
  env            = var.env
  domain         = var.domain
  hosted_zone_id = var.hosted_zone_id

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
}
