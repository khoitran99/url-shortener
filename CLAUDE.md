# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Monorepo for a high-scale URL shortener: ~1,160 writes/sec, ~11,600 reads/sec, targeting 365 billion records over 10 years. Short URLs use 7-character base-62 strings (`[0-9a-zA-Z]`), derived by encoding the database auto-increment primary key.

## Monorepo Structure

```
apps/api/      # NestJS backend
apps/web/      # React frontend
infra/         # AWS infrastructure (CDK or Terraform)
packages/      # Shared TypeScript types and utilities
```

Package manager: **pnpm workspaces**. Always use `pnpm`, never `npm` or `yarn`.

## Common Commands

```bash
# Install all dependencies
pnpm install

# Start local infrastructure (Postgres + Redis via Docker)
docker compose up -d

# Run API in dev mode
pnpm --filter api dev

# Run Web in dev mode
pnpm --filter web dev

# Build all packages
pnpm build

# Lint all
pnpm lint

# Run all unit tests
pnpm test

# Run a single test file (from within apps/api)
pnpm --filter api test -- --testPathPattern=<filename>

# Run e2e tests
pnpm test:e2e
```

## Domains

| Environment | Web | API |
|-------------|-----|-----|
| Local | http://localhost:5173 | http://localhost:3001 |
| Production | https://go.khoitv.com | https://api.go.khoitv.com |

Both `go.khoitv.com` and `api.go.khoitv.com` are subdomains managed inside the existing `khoitv.com` Route 53 hosted zone — no separate hosted zone exists for the subdomain.

## API Contracts

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | ALB health check — returns `{ status: "ok" }` |
| `POST` | `/api/v1/data/shorten` | Accept `{ longUrl }`, return `{ shortUrl }` |
| `GET` | `/api/v1/:shortUrl` | Redirect (HTTP 302) to the original long URL |

`REDIRECT_PREFIX` constant (`apps/api/src/url/url.constants.ts`) controls the `/api/v1` prefix. The controller constructs the full `shortUrl` from `BASE_URL` + prefix + short code.

## Core Algorithm — URL Shortening

1. Check if `longUrl` already exists in the DB → return existing `shortUrl`.
2. Otherwise, insert a new row; the DB returns an auto-increment `id`.
3. Base-62 encode `id` to produce a 7-character `shortUrl`.
4. Store `(id, shortUrl, longUrl)` and return `shortUrl`.

Base-62 alphabet: `0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ`

## Core Algorithm — URL Redirect

1. Look up `shortUrl` in Redis cache.
2. Cache hit → return `longUrl` with `302`.
3. Cache miss → query Postgres, write result to Redis, return `302`.
4. Not found in DB → `404`.

## Data Model

```sql
CREATE TABLE urls (
  id         BIGSERIAL    PRIMARY KEY,
  short_url  VARCHAR(7)   NOT NULL UNIQUE,
  long_url   TEXT         NOT NULL,
  created_at TIMESTAMPTZ  DEFAULT NOW()
);
CREATE INDEX idx_short_url ON urls (short_url);
CREATE INDEX idx_long_url  ON urls (long_url);
```

## Environment Variables (apps/api/.env)

```
DATABASE_URL=postgresql://user:password@localhost:5432/urlshortener
REDIS_URL=redis://localhost:6379
BASE_URL=http://localhost:3000
PORT=3001
```

## AWS Infrastructure

Region: `ap-southeast-1`. Terraform in `infra/`.

| Service | Config | Role |
|---------|--------|------|
| ECS Fargate | 0.25 vCPU / 512 MB | NestJS API |
| RDS PostgreSQL 16 | db.t4g.micro | Primary DB |
| ElastiCache Redis 7 | cache.t4g.micro | Redirect cache |
| CloudFront + S3 | PriceClass_100 | React SPA at go.khoitv.com |
| ALB | TLS 1.3 | HTTPS entry point for API |
| ACM | ap-southeast-1 + us-east-1 | Certs for ALB and CloudFront |
| Secrets Manager | — | Stores `DATABASE_URL` for ECS |
| ECR | — | Docker image registry |

First deploy: `./infra/scripts/bootstrap.sh` → fill `terraform.tfvars` → `terraform apply` → `./infra/scripts/deploy.sh`.

## Performance Constraints to Keep in Mind

- Reads vastly outnumber writes (10:1). Optimize the redirect path first.
- Redis is the primary read path for redirects — cache every successful DB lookup.
- The `short_url` index on Postgres must remain on a column with high cardinality and low write amplification; avoid full-table scans on the redirect path.
- Base-62 encoding is deterministic from the primary key — no UUID generation or hash collision handling needed.
