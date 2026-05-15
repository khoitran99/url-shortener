# Infrastructure Deployment Guide

Step-by-step guide to provision and deploy the URL Shortener on AWS using Terraform.

---

## Architecture overview

```
go.khoitv.com  ──► CloudFront ──► S3          (React frontend)
api.go.khoitv.com ──► ALB ──► ECS Fargate     (NestJS API)
                                    │
                         RDS Postgres + ElastiCache Redis
```

Both subdomains are managed inside your existing **khoitv.com** Route 53 hosted zone.

---

## Prerequisites

Install these tools before starting:

| Tool | Version | Install |
|------|---------|---------|
| Terraform | ≥ 1.7 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Docker | any | https://docs.docker.com/get-docker/ |
| Node.js | 22 | `nvm install 22 && nvm use 22` |
| pnpm | ≥ 9 | `corepack enable` |

Verify everything is installed:

```bash
terraform --version   # Terraform v1.7+
aws --version         # aws-cli/2.x
docker --version      # Docker 24+
node --version        # v22.x.x
pnpm --version        # 9.x.x
```

---

## Step 1 — Configure AWS credentials

If you haven't already, configure the AWS CLI with your credentials:

```bash
aws configure
```

You will be prompted for:
- **AWS Access Key ID** — from IAM → Users → Security credentials
- **AWS Secret Access Key** — same place
- **Default region** — enter `ap-southeast-1`
- **Default output format** — enter `json`

Verify it works:

```bash
aws sts get-caller-identity
```

Expected output (your account ID will differ):
```json
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/yourname"
}
```

### Required IAM permissions

Your AWS user/role needs the following policies (or `AdministratorAccess` for simplicity):

- `AmazonVPCFullAccess`
- `AmazonECS_FullAccess`
- `AmazonEC2ContainerRegistryFullAccess`
- `AmazonRDSFullAccess`
- `AmazonElastiCacheFullAccess`
- `ElasticLoadBalancingFullAccess`
- `CloudFrontFullAccess`
- `AmazonS3FullAccess`
- `AmazonRoute53FullAccess`
- `AWSCertificateManagerFullAccess`
- `SecretsManagerReadWrite`
- `AmazonDynamoDBFullAccess` (for Terraform state lock)
- `IAMFullAccess`

---

## Step 2 — Find your Route 53 hosted zone ID

Your domain `khoitv.com` already has a hosted zone in Route 53. You need its ID.

```bash
aws route53 list-hosted-zones-by-name \
  --dns-name khoitv.com \
  --query 'HostedZones[0].Id' \
  --output text
```

Example output:
```
/hostedzone/Z0123456789ABCDEFGHIJ
```

**Use only the last segment** (after `/hostedzone/`): `Z0123456789ABCDEFGHIJ`

---

## Step 3 — Bootstrap remote state (run once)

Terraform needs an S3 bucket to store its state and a DynamoDB table for locking. Run this once:

```bash
./infra/scripts/bootstrap.sh
```

This will:
1. Create an S3 bucket named `url-shortener-tf-state-<your-account-id>`
2. Create a DynamoDB table named `url-shortener-tf-locks`
3. Print a `backend_block` snippet

**Expected output:**
```
==> Initialising Terraform bootstrap...
==> Applying bootstrap...
...
Apply complete! Resources: 4 added, 0 changed, 0 destroyed.

==> Copy the following backend block into infra/environments/prod/main.tf:

  terraform {
    backend "s3" {
      bucket         = "url-shortener-tf-state-123456789012"
      key            = "prod/terraform.tfstate"
      region         = "ap-southeast-1"
      dynamodb_table = "url-shortener-tf-locks"
      encrypt        = true
    }
  }
```

Now open [`infra/environments/prod/main.tf`](infra/environments/prod/main.tf) and replace the placeholder backend block at the top with the printed output:

```hcl
# Before:
backend "s3" {
  bucket         = "REPLACE_WITH_BOOTSTRAP_BUCKET"
  ...
}

# After (use your actual values from the bootstrap output):
backend "s3" {
  bucket         = "url-shortener-tf-state-123456789012"
  key            = "prod/terraform.tfstate"
  region         = "ap-southeast-1"
  dynamodb_table = "url-shortener-tf-locks"
  encrypt        = true
}
```

---

## Step 4 — Configure prod variables

```bash
cp infra/environments/prod/terraform.tfvars.example \
   infra/environments/prod/terraform.tfvars
```

Open `infra/environments/prod/terraform.tfvars` and fill in your values:

```hcl
project = "url-shortener"
env     = "prod"
region  = "ap-southeast-1"

domain         = "go.khoitv.com"
api_domain     = "api.go.khoitv.com"
hosted_zone_id = "Z0123456789ABCDEFGHIJ"   # ← from Step 2

db_name     = "urlshortener"
db_username = "postgres"

image_tag = "latest"
```

> `terraform.tfvars` is gitignored — it will never be committed.

---

## Step 5 — Initialise Terraform

```bash
cd infra/environments/prod
terraform init
```

Expected output:
```
Initializing the backend...
Successfully configured the backend "s3"!

Initializing modules...
- networking in ../../modules/networking
- ecr in ../../modules/ecr
- alb in ../../modules/alb
- rds in ../../modules/rds
- elasticache in ../../modules/elasticache
- ecs in ../../modules/ecs
- cdn in ../../modules/cdn

Terraform has been successfully initialized!
```

---

## Step 6 — Preview the plan

```bash
terraform plan
```

This is a dry-run — nothing is created yet. Review the output and confirm it looks correct. You should see approximately **50–60 resources** to be added, including:

- VPC, subnets, NAT gateway, security groups
- ECR repository
- ALB, target group, ACM certificate, Route 53 records
- RDS PostgreSQL instance
- ElastiCache Redis cluster
- ECS cluster, task definition, service
- S3 bucket, CloudFront distribution, ACM certificate (us-east-1)

---

## Step 7 — Apply infrastructure

```bash
terraform apply
```

Type `yes` when prompted.

> **This takes 15–25 minutes** — RDS (~10 min), ACM certificate validation (~5 min), and CloudFront distribution (~10 min) are the slow resources.

Expected final output:
```
Apply complete! Resources: 55 added, 0 changed, 0 destroyed.

Outputs:

api_url              = "https://api.go.khoitv.com"
cloudfront_id        = "E1234567890ABC"
ecr_repository_url   = "123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/url-shortener-prod-api"
ecs_cluster_name     = "url-shortener-prod"
ecs_service_name     = "url-shortener-prod-api"
rds_endpoint         = "url-shortener-prod.xxxx.ap-southeast-1.rds.amazonaws.com:5432"
redis_url            = "redis://url-shortener-prod-redis.xxxx.cache.amazonaws.com:6379"
s3_web_bucket        = "url-shortener-prod-web-123456789012"
web_url              = "https://go.khoitv.com"
```

> At this point the ECS service exists but is unhealthy — no Docker image has been pushed yet. That's expected. The next step fixes it.

---

## Step 8 — First deployment

Go back to the repo root and run the deploy script:

```bash
cd ../../..   # back to repo root
./infra/scripts/deploy.sh
```

The script does the following automatically:
1. **Reads** Terraform outputs (ECR URL, cluster/service names, S3 bucket, CloudFront ID)
2. **Authenticates** Docker with ECR
3. **Builds** the API Docker image (multi-stage, ~2–3 min)
4. **Pushes** the image to ECR with the current git SHA as tag
5. **Builds** the React frontend (`pnpm --filter web build`)
6. **Uploads** static files to S3 (assets with long-lived cache, `index.html` with no-cache)
7. **Invalidates** the CloudFront cache
8. **Applies** Terraform again with the new image tag
9. **Runs** `prisma migrate deploy` as a one-off ECS task and waits for it to complete
10. **Updates** the ECS service to deploy the new task definition
11. **Waits** for the service to stabilise (all tasks healthy)

Expected final output:
```
[14:32:01] Deploy complete. Image: a1b2c3d
[14:32:01]   API:  https://api.go.khoitv.com
[14:32:01]   Web:  https://go.khoitv.com
```

---

## Step 9 — Verify the deployment

### Health check
```bash
curl https://api.go.khoitv.com/health
```
Expected: `{"status":"ok"}`

### Shorten a URL
```bash
curl -s -X POST https://api.go.khoitv.com/api/v1/data/shorten \
  -H "Content-Type: application/json" \
  -d '{"longUrl": "https://github.com/nestjs/nest"}' | jq
```
Expected:
```json
{ "shortUrl": "https://api.go.khoitv.com/api/v1/4" }
```

### Test the redirect
```bash
curl -I https://api.go.khoitv.com/api/v1/4
```
Expected headers:
```
HTTP/2 302
location: https://github.com/nestjs/nest
```

### Open the web app
Open **https://go.khoitv.com** in a browser — the React URL shortener UI should load over HTTPS.

---

## Subsequent deployments

After the first deploy, every future deployment is a single command from the repo root:

```bash
./infra/scripts/deploy.sh
```

To deploy a specific commit:
```bash
./infra/scripts/deploy.sh <git-sha>
```

---

## Useful commands

```bash
# View live Terraform outputs
cd infra/environments/prod && terraform output

# Tail API logs in real time
aws logs tail /ecs/url-shortener-prod-api --follow --region ap-southeast-1

# SSH-equivalent: exec into a running ECS task (requires ECS Exec enabled)
aws ecs execute-command \
  --cluster url-shortener-prod \
  --task <task-id> \
  --container api \
  --interactive \
  --command "/bin/sh" \
  --region ap-southeast-1

# View ECS service events (health check failures, deployment status)
aws ecs describe-services \
  --cluster url-shortener-prod \
  --services url-shortener-prod-api \
  --region ap-southeast-1 \
  --query 'services[0].events[:5]'

# Force a new deployment without a code change
aws ecs update-service \
  --cluster url-shortener-prod \
  --service url-shortener-prod-api \
  --force-new-deployment \
  --region ap-southeast-1

# Destroy all infrastructure (⚠️ irreversible)
cd infra/environments/prod && terraform destroy
```

---

## Troubleshooting

### ACM certificate stuck in PENDING_VALIDATION
The certificate validates via DNS. Terraform creates the validation records automatically in your Route 53 zone. If it takes more than 10 minutes, check:
```bash
aws acm describe-certificate \
  --certificate-arn <arn> \
  --region ap-southeast-1 \
  --query 'Certificate.DomainValidationOptions'
```
Ensure the CNAME records appear in your Route 53 zone for `khoitv.com`.

### ECS service not stabilising
```bash
# Check recent service events
aws ecs describe-services \
  --cluster url-shortener-prod \
  --services url-shortener-prod-api \
  --region ap-southeast-1 \
  --query 'services[0].events[:10]'

# Check task stopped reason
aws ecs list-tasks --cluster url-shortener-prod --region ap-southeast-1
aws ecs describe-tasks \
  --cluster url-shortener-prod \
  --tasks <task-arn> \
  --region ap-southeast-1 \
  --query 'tasks[0].containers[0].reason'
```

### Migration task failed
```bash
# Get the migration task ARN from deploy.sh output, then:
aws ecs describe-tasks \
  --cluster url-shortener-prod \
  --tasks <task-arn> \
  --region ap-southeast-1 \
  --query 'tasks[0].containers[0].[exitCode,reason]'

# View migration logs
aws logs get-log-events \
  --log-group-name /ecs/url-shortener-prod-api \
  --log-stream-name api/<task-id> \
  --region ap-southeast-1
```

### RDS connection refused
The RDS instance is in private subnets and not publicly accessible. You can only connect from within the VPC (ECS tasks). To connect directly for debugging, run a temporary bastion:
```bash
aws ec2 run-instances --image-id ami-0df7a207adb9748c7 \
  --instance-type t3.micro \
  --subnet-id <public-subnet-id> \
  --security-group-ids <ecs-sg-id> \
  --key-name <your-key-pair> \
  --region ap-southeast-1
```
