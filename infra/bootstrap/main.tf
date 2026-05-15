# Run ONCE before any environment:
#   cd infra/bootstrap && terraform init && terraform apply
# Then copy the outputs into environments/prod/main.tf backend block.

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "project" { default = "url-shortener" }
variable "region" { default = "ap-southeast-1" }

provider "aws" { region = var.region }

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project}-tf-state-${data.aws_caller_identity.current.account_id}"
  table_name  = "${var.project}-tf-locks"
}

resource "aws_s3_bucket" "tf_state" {
  bucket = local.bucket_name
  lifecycle { prevent_destroy = true }
  tags = { Name = "Terraform remote state" }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_locks" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  tags = { Name = "Terraform state lock" }
}

output "state_bucket" { value = aws_s3_bucket.tf_state.bucket }
output "lock_table" { value = aws_dynamodb_table.tf_locks.name }
output "backend_block" {
  value = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${local.bucket_name}"
        key            = "prod/terraform.tfstate"
        region         = "${var.region}"
        dynamodb_table = "${local.table_name}"
        encrypt        = true
      }
    }
  EOT
}
