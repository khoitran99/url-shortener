# URL Shortener

A production-grade URL shortening service built as a monorepo with NestJS, React, and AWS.

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

## Architecture

```
url-shortener/
├── apps/
│   ├── api/          # NestJS backend
│   └── web/          # React frontend
├── infra/            # AWS infrastructure (CDK / Terraform)
└── packages/         # Shared types and utilities
```

### Tech Stack

| Layer | Technology |
|-------|------------|
| Backend | NestJS (Node.js) |
| Frontend | React |
| Database | PostgreSQL (RDS) |
| Cache | Redis (ElastiCache) |
| Infrastructure | AWS (CDK or Terraform) |

## API

### Shorten a URL

```
POST /api/v1/data/shorten
Content-Type: application/json

{ "longUrl": "https://example.com/very/long/path" }
```

**Response**

```json
{ "shortUrl": "https://short.ly/abc1234" }
```

### Redirect to Original URL

```
GET /api/v1/:shortUrl
```

Returns HTTP `302 Found` with the original URL in the `Location` header.

## Data Model

```sql
CREATE TABLE urls (
  id        BIGSERIAL    PRIMARY KEY,
  short_url VARCHAR(7)   NOT NULL UNIQUE,
  long_url  TEXT         NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_short_url ON urls (short_url);
CREATE INDEX idx_long_url  ON urls (long_url);
```

## URL Shortening Flow

```
Client → POST /shorten (longUrl)
           │
           ▼
  longUrl in DB?
  ├── Yes → return existing shortUrl
  └── No  → generate unique ID (auto-increment primary key)
               │
               ▼
          Base-62 encode ID → 7-char hashValue
               │
               ▼
          INSERT (id, shortUrl, longUrl) into DB
               │
               ▼
          return shortUrl
```

### Base-62 Encoding

The primary key (integer) is converted to a base-62 string using characters `0-9`, `a-z`, `A-Z`. This guarantees:
- Uniqueness (1-to-1 mapping from ID)
- Reversibility (hashValue → ID → longURL)
- Compact representation (7 chars covers 3.5 trillion URLs)

## URL Redirect Flow

```
Client → GET /:shortUrl
           │
           ▼
  Check Redis cache
  ├── Hit  → return longUrl (302)
  └── Miss → query DB for longUrl
               │
               ├── Found → cache in Redis → return longUrl (302)
               └── Not found → 404
```

## Implementation Status

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Monorepo foundation (Turborepo + pnpm workspaces) | ✅ Done |
| 2 | Local infrastructure (Docker Compose) | ✅ Done |
| 3 | Shared types package | ✅ Done |
| 4 | NestJS API | ✅ Done |
| 5 | React frontend | ✅ Done |
| 6 | Turborepo pipeline finalization | ✅ Done |
| 7 | Integration smoke test | ✅ Done |

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

# Start infrastructure (Postgres + Redis)
docker compose up -d

# Start all apps (API + Web)
pnpm dev

# Or run individually
pnpm --filter api dev
pnpm --filter web dev
```

### Environment Variables

```env
# apps/api/.env
DATABASE_URL=postgresql://user:password@localhost:5432/urlshortener
REDIS_URL=redis://localhost:6379
BASE_URL=http://localhost:3000
PORT=3001
```

### Running Tests

```bash
# All unit tests
pnpm test

# All e2e tests
pnpm test:e2e

# Single test file (from apps/api)
pnpm --filter api test -- --testPathPattern=<filename>
```

### Code Quality

```bash
# Lint all workspaces
pnpm lint

# Format all files
pnpm format
```

## Infrastructure (AWS)

| Service | Purpose |
|---------|---------|
| ECS Fargate | Container hosting for API |
| RDS (PostgreSQL) | Primary database |
| ElastiCache (Redis) | Read-through cache |
| CloudFront + S3 | React frontend hosting |
| Route 53 | DNS management |
| ALB | Load balancing |

## License

MIT
