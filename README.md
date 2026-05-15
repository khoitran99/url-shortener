# URL Shortener

A production-grade URL shortening service built as a monorepo with NestJS, React, and AWS.

---

## Capacity Estimation

| Metric | Value |
|--------|-------|
| Write operations/day | 100 million |
| Write operations/second | ~1,160 |
| Read operations/second | ~11,600 (10:1 read/write ratio) |
| Data retention | 10 years |
| Total records | ~365 billion |
| Hash length | 7 characters (base-62: `[0-9a-zA-Z]`) |
| Avg URL length | 100 bytes |
| Total storage | ~365 billion × 100 bytes ≈ 36.5 TB |

**Why 7 characters?** With 62 possible characters per position, `62^7 ≈ 3.5 trillion`, which comfortably covers 365 billion URLs.

---

## Monorepo Structure

```
url-shortener/
├── apps/
│   ├── api/                  # NestJS backend (port 3001)
│   │   ├── src/
│   │   │   ├── url/          # Shorten + redirect endpoints
│   │   │   ├── health/       # Health check endpoint
│   │   │   └── prisma/       # DB client service
│   │   ├── prisma/
│   │   │   ├── schema.prisma
│   │   │   └── migrations/
│   │   └── test/             # e2e tests
│   └── web/                  # React + Vite frontend (port 5173)
│       └── src/
│           └── components/   # ShortenForm
├── packages/
│   └── types/                # Shared TypeScript types (ShortenResponse)
└── infra/
    ├── bootstrap/            # S3 + DynamoDB for Terraform remote state (run once)
    ├── modules/
    │   ├── networking/       # VPC, subnets, NAT gateway, security groups
    │   ├── ecr/              # Container registry
    │   ├── alb/              # Load balancer, TLS cert, Route 53 A record
    │   ├── rds/              # PostgreSQL + Secrets Manager password
    │   ├── elasticache/      # Redis cluster
    │   ├── ecs/              # ECS cluster, task definition, service, IAM
    │   └── cdn/              # S3 bucket, CloudFront, ACM cert (us-east-1)
    └── environments/
        └── prod/             # Root module — wires all modules together
```

---

## High-Level Architecture

```
                        ┌─────────────────────────────────────────────────────────────┐
                        │                        AWS Cloud                            │
                        │                                                             │
  User (browser)        │  go.khoitv.com            api.go.khoitv.com                │
      │                 │       │                          │                          │
      │ HTTPS           │       ▼                          ▼                          │
      ├────────────────►│  Route 53 (A alias)       Route 53 (A alias)               │
      │                 │       │                          │                          │
      │                 │       ▼                          ▼                          │
      │   React SPA     │  CloudFront              ALB (ap-southeast-1)              │
      │◄────────────────│  (PriceClass_100)         TLS 1.2/1.3                      │
      │                 │       │                    HTTP→HTTPS redirect              │
      │                 │       ▼                          │                          │
      │                 │  S3 Bucket (private)             ▼                          │
      │                 │  index.html + assets    ECS Fargate (NestJS API)            │
      │                 │                                  │                          │
      │                 │                         ┌────────┴────────┐                 │
      │                 │                         ▼                 ▼                 │
      │                 │                   RDS PostgreSQL   ElastiCache Redis        │
      │                 │                   (db.t4g.micro)   (cache.t4g.micro)        │
      │                 │                                                             │
      │                 │  ┌──────────────────────────────────────────────────────┐  │
      │                 │  │  Supporting Services                                 │  │
      │                 │  │  ECR (Docker images)   Secrets Manager (DB password) │  │
      │                 │  │  CloudWatch Logs        IAM Roles                    │  │
      │                 │  └──────────────────────────────────────────────────────┘  │
      │                 └─────────────────────────────────────────────────────────────┘
```

---

## Network Topology (VPC)

```
VPC: 10.0.0.0/16   (ap-southeast-1)
│
├── Public Subnets (internet-facing)
│   ├── public-1   10.0.1.0/24   AZ: ap-southeast-1a
│   │   └── ALB node
│   │   └── NAT Gateway (Elastic IP) ──► Internet Gateway ──► Internet
│   │
│   └── public-2   10.0.2.0/24   AZ: ap-southeast-1b
│       └── ALB node
│
├── Private Subnets (no direct internet access)
│   ├── private-1  10.0.10.0/24  AZ: ap-southeast-1a
│   │   └── ECS Fargate tasks
│   │   └── RDS PostgreSQL (primary)
│   │   └── ElastiCache Redis
│   │
│   └── private-2  10.0.11.0/24  AZ: ap-southeast-1b
│       └── ECS Fargate tasks (failover)
│       └── RDS / ElastiCache (standby)
│
└── Routing
    ├── Public route table:  0.0.0.0/0 → Internet Gateway
    └── Private route table: 0.0.0.0/0 → NAT Gateway
                             (ECS pulls images from ECR via NAT)
```

---

## Security Group Chain

Traffic is restricted at every layer — each service only accepts connections from the layer directly above it.

```
  Internet
  │
  │  TCP 443 (HTTPS)
  │  TCP 80  (HTTP — redirected to HTTPS by ALB)
  ▼
┌─────────────────────────────────────┐
│  alb-sg                             │
│  ingress: 0.0.0.0/0 → 80, 443      │
│  egress:  all                       │
└──────────────────┬──────────────────┘
                   │ TCP 3001 only
                   │ (source: alb-sg — not a CIDR range)
                   ▼
┌─────────────────────────────────────┐
│  ecs-sg                             │
│  ingress: alb-sg → 3001             │
│  egress:  all (ECR, Secrets Mgr)    │
└────────┬─────────────────┬──────────┘
         │ TCP 5432        │ TCP 6379
         ▼                 ▼
┌──────────────┐   ┌──────────────────┐
│  rds-sg      │   │  redis-sg        │
│  ingress:    │   │  ingress:        │
│  ecs-sg→5432 │   │  ecs-sg→6379     │
└──────────────┘   └──────────────────┘
```

> **Key security property:** ECS tasks have no public IP (`assign_public_ip = false`).
> Even within the VPC, only the ALB's security group ID is whitelisted — not a subnet CIDR.
> Nothing else can reach ECS directly.

---

## ALB — Request Pipeline

```
Client
  │
  │  TCP 443 — TLS ClientHello
  ▼
ALB Listener (port 443)
  │  TLS terminated here using ACM certificate (api.go.khoitv.com)
  │  Policy: ELBSecurityPolicy-TLS13-1-2-2021-06
  │          (TLS 1.2 minimum, TLS 1.3 supported, weak ciphers disabled)
  │
  │  HTTP/1.1 (plain) forwarded to target group
  ▼
Target Group (port 3001, target_type = "ip")
  │
  │  Health check: GET /health → expect HTTP 200
  │  healthy_threshold   = 2 checks  (task marked healthy after 2 passes)
  │  unhealthy_threshold = 3 checks  (task removed after 3 failures)
  │  interval = 30s, timeout = 5s
  │
  ▼
ECS Fargate Task IP:3001  (inside private subnet)

─────────────────────────────────────────────
HTTP port 80 path (separate listener):

Client → ALB:80 → 301 redirect → https://<same-host>/<same-path>
         (handled entirely by ALB, never reaches ECS)
```

---

## TLS Certificate Lifecycle

```
  Terraform apply
       │
       ▼
  aws_acm_certificate          domain: api.go.khoitv.com
  (ap-southeast-1)             validation: DNS
       │
       │  ACM provides DNS validation record
       ▼
  aws_route53_record           CNAME written into khoitv.com hosted zone
  (cert_validation)            ACM polls this record to prove domain ownership
       │
       │  ACM confirms ownership (~30–60 seconds)
       ▼
  aws_acm_certificate_validation   Terraform waits here until ISSUED status
       │
       ▼
  aws_lb_listener (port 443)   Certificate attached — listener created
```

> CloudFront's certificate follows the same pattern but must be provisioned in
> **us-east-1** regardless of the deployment region. A `provider alias = "us_east_1"`
> is declared in the root module and passed into the CDN module via `providers = {}`.

---

## CloudFront + S3 Architecture (Frontend)

```
  Browser
    │
    │  HTTPS  go.khoitv.com
    ▼
  Route 53 (A alias record)
    │
    ▼
  CloudFront Distribution
  │  aliases: ["go.khoitv.com"]
  │  price_class: PriceClass_100  (US, Europe, Asia edge nodes)
  │  viewer_protocol_policy: redirect-to-https
  │  default_root_object: index.html
  │  TLS: ACM cert (us-east-1), minimum TLSv1.2_2021, SNI only
  │
  │  Cache behaviour:
  │  ├── GET/HEAD allowed + cached
  │  ├── compress: true  (gzip/br)
  │  ├── default_ttl: 3600s, max_ttl: 86400s
  │  └── no cookies, no query strings forwarded
  │
  │  SPA fallback:
  │  ├── 404 → 200 + /index.html  (React Router handles the route)
  │  └── 403 → 200 + /index.html  (S3 key-not-found returns 403)
  │
  │  Origin: S3 bucket  (private — no public access)
  │  Auth:   Origin Access Control (OAC, sigv4 signed)
  │          S3 bucket policy allows s3:GetObject only from this distribution ARN
  ▼
  S3 Bucket  (url-shortener-prod-web-<account-id>)
  │  block_public_acls       = true
  │  block_public_policy     = true
  │  restrict_public_buckets = true
  └── index.html, assets/index-*.js, assets/index-*.css
```

---

## URL Shortening Flow

```
POST /api/v1/data/shorten
{ "longUrl": "https://example.com/very/long/path" }

  │
  ▼
ThrottlerGuard
  │  60 requests/minute per IP (429 Too Many Requests if exceeded)
  ▼
ValidationPipe
  │  longUrl must be a valid URL with protocol
  │  extra fields rejected (whitelist: true, forbidNonWhitelisted: true)
  ▼
UrlController.shorten()
  │
  ▼
UrlService.shortenUrl(longUrl)
  │
  ├─► prisma.url.findFirst({ where: { longUrl } })
  │       │
  │       ├── Found ──────────────────────────────────────────────────┐
  │       │                                                           │
  │       └── Not found                                              │
  │               │                                                  │
  │               ▼                                                  │
  │         prisma.url.create({ longUrl, shortUrl: '' })             │
  │         (DB returns auto-increment BIGSERIAL id)                 │
  │               │                                                  │
  │               ▼                                                  │
  │         encodeBase62(id)                                         │
  │         e.g. id=125 → "21"  (base-62 division algorithm)        │
  │               │                                                  │
  │               ▼                                                  │
  │         prisma.url.update({ shortUrl })                          │
  │               │                                                  │
  │               ▼                                                  │
  │         cache.set("redirect:21", longUrl, 24h TTL)               │
  │               │                                                  │
  │               ▼                                                  │
  │         return shortUrl code ("21")          ◄───────────────────┘
  │
  ▼
UrlController builds full URL:
  "https://api.go.khoitv.com/api/v1/21"

Response HTTP 201:
{ "shortUrl": "https://api.go.khoitv.com/api/v1/21" }
```

---

## URL Redirect Flow

```
GET /api/v1/21

  │
  ▼
ThrottlerGuard  (rate limit applies to redirect too)
  │
  ▼
UrlController.redirect("21")
  │
  ▼
UrlService.getLongUrl("21")
  │
  ├─► cache.get("redirect:21")
  │       │
  │       ├── HIT ──► return longUrl immediately (no DB query)
  │       │                │
  │       │                ▼
  │       │           HTTP 302  Location: https://example.com/...
  │       │
  │       └── MISS
  │               │
  │               ▼
  │         prisma.url.findUnique({ where: { shortUrl: "21" } })
  │               │
  │               ├── Found
  │               │       │
  │               │       ▼
  │               │   cache.set("redirect:21", longUrl, 24h TTL)
  │               │       │
  │               │       ▼
  │               │   HTTP 302  Location: https://example.com/...
  │               │
  │               └── Not found
  │                       │
  │                       ▼
  │                   HTTP 404  { message: "Short URL not found" }
```

---

## Base-62 Encoding

The primary key (BIGSERIAL integer) is converted to a base-62 string — the same mechanic as binary (base-2) or hex (base-16), but with 62 symbols.

```
Alphabet: 0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ
          ─────────── ────────────────────────── ──────────────────────────
           0–9 (10)           a–z (26)                   A–Z (26)
                                                       total = 62

Algorithm — repeated division by 62:

  id = 125
  125 ÷ 62 = 2  remainder 1  →  ALPHABET[1] = '1'
    2 ÷ 62 = 0  remainder 2  →  ALPHABET[2] = '2'
  Read remainders bottom-up: "21"

Capacity per code length:
  1 char  →         62 unique codes
  2 chars →      3,844 unique codes
  3 chars →    238,328 unique codes
  7 chars → 3,521,614,606,208 (3.5 trillion) ✓ covers 365 billion target
```

> `BigInt` is used throughout because BIGSERIAL reaches ~9.2 × 10¹⁸,
> which exceeds JavaScript's safe integer limit of 2⁵³ (~9 × 10¹⁵).

---

## Data Model

```sql
CREATE TABLE urls (
  id         BIGSERIAL    PRIMARY KEY,          -- auto-increment, encoded to shortUrl
  short_url  VARCHAR(7)   NOT NULL UNIQUE,       -- base-62 encoded id
  long_url   TEXT         NOT NULL,              -- original URL (deduplication key)
  created_at TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX idx_short_url ON urls (short_url);  -- redirect path (primary read)
CREATE INDEX idx_long_url  ON urls (long_url);   -- idempotency check on write
```

**Write path index:** `idx_long_url` — checked before every insert to avoid duplicates.
**Read path index:** `idx_short_url` — used on every cache-miss redirect lookup.

---

## Local Infrastructure (Docker Compose)

```
┌─────────────────────────────────────────────────────────────────┐
│  Docker virtual network                                         │
│                                                                 │
│  ┌──────────────────────┐    ┌──────────────────────────────┐   │
│  │  url-shortener-      │    │  url-shortener-redis         │   │
│  │  postgres            │    │  image: redis:7-alpine       │   │
│  │  image: postgres:16  │    │  port:  6379:6379            │   │
│  │  port:  5432:5432    │    │  hostname inside Docker:     │   │
│  │  db: urlshortener    │    │  "redis"                     │   │
│  │  user: postgres      │    └──────────────────────────────┘   │
│  └──────────────────────┘                                       │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  url-shortener-redisinsight                              │   │
│  │  image: redis/redisinsight:latest                        │   │
│  │  port:  5540:5540  →  http://localhost:5540              │   │
│  │  connect to Redis via hostname "redis", port 6379        │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘

Your Mac:
  localhost:5432  →  Postgres   (psql, TablePlus, DBeaver)
  localhost:6379  →  Redis      (redis-cli)
  localhost:5540  →  RedisInsight UI
  localhost:3001  →  NestJS API (pnpm --filter api dev)
  localhost:5173  →  React app  (pnpm --filter web dev)
```

---

## ECS Deployment Pipeline

```
Developer workstation
  │
  │  1. docker build + push
  ▼
ECR Repository
  url-shortener-prod-api:<git-sha>
  (lifecycle policy: keep last 10 images)
  │
  │  2. terraform apply  OR  aws ecs update-service
  ▼
ECS Service (desired_count = 1)
  │
  │  Rolling deploy strategy:
  │  deployment_minimum_healthy_percent = 100  ← old task stays up until new one is healthy
  │  deployment_maximum_percent         = 200  ← allows 2 tasks briefly during rollover
  │
  ▼
New ECS Task
  │  pulls image from ECR (via NAT Gateway)
  │  fetches DATABASE_URL from Secrets Manager
  │  starts NestJS on port 3001
  │
  ▼
ALB Health Check  GET /health → 200
  │  healthy_threshold = 2  (~60s)
  │
  ▼
Target Group registers new task IP
Old task deregistered and stopped
```

---

## Secrets & Configuration

```
Secrets Manager
  └── url-shortener/prod/db-password     ← RDS master password (random 32-char)
  └── url-shortener/prod/database-url    ← Full DATABASE_URL injected into ECS task

ECS Task environment variables:
  NODE_ENV    = "production"
  PORT        = "3001"
  BASE_URL    = "https://api.go.khoitv.com"
  REDIS_URL   = "redis://<elasticache-endpoint>:6379"
  DATABASE_URL← from Secrets Manager (valueFrom — never in plaintext env)

IAM — task execution role permissions:
  AmazonECSTaskExecutionRolePolicy  (ECR pull, CloudWatch logs)
  secretsmanager:GetSecretValue     (database-url secret only)
```

---

## AWS Services Summary

| Service | Config | Role |
|---------|--------|------|
| ECS Fargate | 0.25 vCPU / 512 MB, 1 task | API container runtime |
| RDS PostgreSQL 16 | db.t4g.micro, 20 GB, encrypted | Primary database |
| ElastiCache Redis 7 | cache.t4g.micro, 1 node | Read-through cache (24h TTL) |
| ALB | TLS 1.2/1.3, multi-AZ | HTTPS termination + health checks |
| CloudFront | PriceClass_100, OAC | React SPA CDN |
| S3 | Private, no public access | Static asset storage |
| ACM | ap-southeast-1 (API) + us-east-1 (CF) | TLS certificates |
| ECR | Scan on push, keep last 10 | Docker image registry |
| Secrets Manager | 7-day recovery window | DB credentials |
| Route 53 | Alias records | DNS for API and web |
| CloudWatch Logs | 30-day retention | ECS container logs |
| IAM | Least-privilege roles | ECS task permissions |

---

## Getting Started

### Prerequisites

- Node.js ≥ 22 (use `nvm use` — `.nvmrc` is provided)
- pnpm ≥ 9
- Docker (for local PostgreSQL and Redis)
- AWS CLI (for infrastructure deployment)

### Local Development

```bash
# Use correct Node version
nvm use

# Install dependencies
pnpm install

# Start infrastructure (Postgres + Redis + RedisInsight)
docker compose up -d

# Run database migration (first time only)
pnpm --filter api db:migrate:dev

# Start all apps (API + Web)
pnpm dev
```

### Environment Variables

```env
# apps/api/.env
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/urlshortener
REDIS_URL=redis://localhost:6379
BASE_URL=http://localhost:3001
PORT=3001
```

### Running Tests

```bash
pnpm test          # all unit tests
pnpm test:e2e      # e2e tests (requires Docker)
pnpm lint          # lint all workspaces
pnpm build         # build all packages
```

### Viewing Data Locally

```bash
# PostgreSQL
docker exec -it url-shortener-postgres psql -U postgres -d urlshortener \
  -c "SELECT id, short_url, long_url, created_at FROM urls ORDER BY id DESC LIMIT 10;"

# Redis (CLI)
docker exec -it url-shortener-redis redis-cli
KEYS *                        # list all keys
GET redirect:<shortCode>      # get cached long URL

# Redis (UI)
open http://localhost:5540    # RedisInsight — connect to host "redis", port 6379
```

---

## Infrastructure Deployment (AWS)

### DNS Setup

`go.khoitv.com` and `api.go.khoitv.com` are subdomains of the existing `khoitv.com` Route 53 hosted zone. Terraform creates all DNS records directly in that zone.

```bash
# Look up your hosted zone ID
aws route53 list-hosted-zones-by-name --dns-name khoitv.com \
  --query 'HostedZones[0].Id' --output text
# Returns: /hostedzone/Z0123456789ABCDEFGHIJ
# Use only the last segment: Z0123456789ABCDEFGHIJ
```

### Deploy

```bash
# 1. First time only — provision S3 + DynamoDB for Terraform state
./infra/scripts/bootstrap.sh

# 2. Configure variables
cp infra/environments/prod/terraform.tfvars.example \
   infra/environments/prod/terraform.tfvars
# Edit terraform.tfvars — fill in hosted_zone_id, domain, api_domain

# 3. Initial provisioning
cd infra/environments/prod
terraform init
terraform apply

# 4. Subsequent deploys (build → push to ECR → migrate → update ECS)
./infra/scripts/deploy.sh [optional-git-sha]
```

### Endpoints After Deploy

| Endpoint | URL |
|----------|-----|
| Web (React) | https://go.khoitv.com |
| Shorten API | `POST https://api.go.khoitv.com/api/v1/data/shorten` |
| Redirect | `GET https://api.go.khoitv.com/api/v1/<code>` |
| Health check | `GET https://api.go.khoitv.com/health` |

---

## License

MIT
