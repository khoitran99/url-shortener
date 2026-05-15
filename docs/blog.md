# Building a Production-Grade URL Shortener from Scratch

> From system design to AWS deployment — everything I learned building a URL shortener that can handle 11,600 requests per second.

---

## Why a URL shortener?

URL shorteners seem simple on the surface. You paste a long URL, you get a short one back. But underneath that simplicity lies a fascinating set of engineering challenges — scale, uniqueness, caching, encoding, and infrastructure. That is exactly why it is one of the most popular system design interview questions.

This post documents how I designed and built one from scratch: from capacity estimation and algorithm design all the way to deploying on AWS with Terraform and solving real production bugs along the way.

---

## Starting with the numbers

Before writing a single line of code, I worked out the scale the system needs to handle. This is called **back-of-the-envelope estimation** — a key skill in system design.

| Metric | Calculation | Result |
|--------|------------|--------|
| Write operations/day | Given | 100 million |
| Write operations/second | 100M ÷ 86,400 | ~1,160 |
| Read operations/second | 1,160 × 10 (10:1 ratio) | ~11,600 |
| Total records (10 years) | 100M × 365 × 10 | ~365 billion |
| Storage needed | 365B × 100 bytes | ~36.5 TB |

The read-to-write ratio of 10:1 is crucial. It tells you immediately that **the redirect path is the hot path** — optimising it should be the top priority.

---

## The core algorithm — why base 62?

This is the most interesting engineering decision in the whole project and the question I get asked most often.

### The problem

The database assigns each URL a sequential integer ID: 1, 2, 3, 4… After 10 years, ID numbers reach into the hundreds of billions. Represented in plain decimal, that is 12 characters — not very "short".

```
https://go.khoitv.com/365000000000   ← 12 characters, defeats the purpose
https://go.khoitv.com/2qgcEKQ        ← 7 characters, same number
```

### The solution — count in a bigger base

You already know base 10: you have 10 symbols (0–9) and roll over at 10. Base 62 works the same way but with 62 symbols — digits, lowercase letters, and uppercase letters.

```
Decimal  Base 62
      9        9   ← base 10 rolls over next; base 62 keeps going
     10        a   ← 'a' is symbol #10
     35        z
     36        A
     61        Z   ← last single-character value
     62       10   ← rolls over here
```

More symbols per position means each character carries more information, so you need fewer characters to represent the same number.

### Why not go bigger?

This is the follow-up question that separates good answers from great ones. If more symbols mean shorter URLs, why not use base 100? Base 1000?

Two reasons stop you.

**Reason 1 — URL character constraint.** A URL can only safely contain letters, digits, and four special characters (`-`, `_`, `.`, `~`). Everything else gets percent-encoded, which makes URLs *longer*. Count those safe characters: 26 + 26 + 10 + 4 = **66**. Base 66 is the hard ceiling. Base 62 is the practical standard (skipping the four special characters for simplicity).

**Reason 2 — Diminishing returns.** Even with fictional unlimited symbols, the savings shrink rapidly because they follow a logarithm.

```
Base  62 → 7 characters for 365 billion URLs
Base 100 → 6 characters   (save 1, need 38 fictional symbols)
Base 200 → 6 characters   (save 0, need 100 more fictional symbols)
Base 999 → 4 characters   (save 3, need 999 symbols nobody can type)
```

Going from base 62 to base 200 saves zero characters. You would need 1,000 distinct symbols just to save 3 characters versus base 62. The math simply does not justify it.

### The algorithm

The encoding is repeated division — the same method you learned for converting between bases in school.

```
Encode 125 to base 62:

  125 ÷ 62 = 2  remainder 1  →  alphabet[1] = '1'
    2 ÷ 62 = 0  remainder 2  →  alphabet[2] = '2'

  Read remainders bottom-to-top: "21"

  Verify: (2 × 62) + 1 = 125 ✓
```

The implementation is 13 lines:

```typescript
const ALPHABET = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
const BASE = BigInt(62);

export function encodeBase62(id: bigint): string {
  if (id === 0n) return ALPHABET[0];

  let result = '';
  let n = id;
  while (n > 0n) {
    result = ALPHABET[Number(n % BASE)] + result;
    n = n / BASE;
  }
  return result;
}
```

One detail worth noting: `BigInt` instead of `number`. PostgreSQL's `BIGSERIAL` type can store values up to 9.2 × 10¹⁸, which exceeds JavaScript's safe integer limit of 2⁵³. Using a regular `number` would silently corrupt large IDs — a subtle bug that would only surface years into production.

### Why not MD5 or SHA256?

Hash functions seem like a natural fit but have a fundamental problem: **collisions**. Two different URLs can produce the same hash, which means you need collision detection and retry logic, adding complexity and extra database round-trips at every write.

The auto-increment approach gives you uniqueness for free. The database primary key is already unique by definition. Base-62 encoding is just a compact representation of that integer — the two concerns are completely separated.

---

## Architecture

```
go.khoitv.com  ──► CloudFront ──► S3          (React frontend)
api.go.khoitv.com ──► ALB ──► ECS Fargate     (NestJS API)
                                    │
                         ┌──────────┴──────────┐
                    RDS PostgreSQL       ElastiCache Redis
```

Two flows handle all traffic.

**Shorten flow** (writes, ~1,160/sec):
1. Check if `longUrl` already exists in Postgres — if yes, return the existing short code
2. If not, insert a new row and let the database generate the auto-increment ID
3. Base-62 encode the ID to get the 7-character short code
4. Update the row with the short code and return it

**Redirect flow** (reads, ~11,600/sec):
1. Check Redis cache first (key: `redirect:<shortCode>`)
2. Cache hit → return `302` redirect immediately (no DB touch)
3. Cache miss → query Postgres, write to Redis, return `302`

The redirect flow is designed to handle 10× more traffic than the write flow. In production, cache hit rates should be well above 90% — the vast majority of clicks happen on recently shortened URLs. That means Postgres rarely sees redirect traffic at all.

---

## Tech stack choices

**NestJS** for the API. Its module system makes large codebases easy to navigate, and the ecosystem around Prisma, class-validator, and caching is excellent.

**Prisma** as the ORM. Schema-first, type-safe, and migrations that actually work. The `binaryTargets` feature turned out to be important when deploying to Alpine Linux — more on that later.

**React + Vite** for the frontend. Single-page app, no server-side rendering needed for a tool this simple.

**PostgreSQL** as the primary store. Relational, mature, and the `BIGSERIAL` type maps cleanly to the base-62 approach.

**Redis (ElastiCache)** as the read-through cache. The redirect path is 100% cache-friendly — the same short code will always map to the same long URL.

**AWS + Terraform** for infrastructure. Everything is code, everything is reproducible, and Terraform modules make it easy to reason about what each piece does.

---

## Database design

The schema is intentionally minimal:

```sql
CREATE TABLE urls (
  id        BIGSERIAL    PRIMARY KEY,
  short_url VARCHAR(7)   NOT NULL UNIQUE,
  long_url  TEXT         NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_short_url ON urls (short_url);  -- redirect path
CREATE INDEX idx_long_url  ON urls (long_url);   -- idempotency check
```

Two indexes serve two distinct query patterns:

- `idx_short_url` — the redirect path looks up by `short_url` on every request
- `idx_long_url` — the shorten path checks whether `long_url` already exists, so the same URL always returns the same short code

---

## Infrastructure

The AWS setup is straightforward but production-grade:

**Networking:** A VPC with public subnets for the load balancer and private subnets for everything else. ECS tasks have no public IP. The only way to reach them is through the ALB. A NAT gateway allows outbound traffic (ECR image pulls, CloudWatch logs) without exposing the tasks directly.

**Security group chain:** Each layer only accepts connections from the layer directly above it.

```
Internet → ALB (80, 443) → ECS (3001) → RDS (5432)
                                       → Redis (6379)
```

**TLS:** ACM certificates handle HTTPS termination at the ALB. A separate certificate in `us-east-1` covers the CloudFront distribution — a quirk of AWS: CloudFront only accepts certificates from us-east-1 regardless of where the rest of your infrastructure lives.

**Cost:** The full stack running 24/7 costs approximately **$98/month**. The biggest single line item is the NAT gateway at $43/month — more expensive than the ECS compute itself.

---

## The bugs I hit in production

Deploying this project to AWS was educational. Here is every bug I encountered and what fixed it.

### Bug 1 — exec format error

The first deploy failed with `exec format error`. The Docker image was built on an Apple Silicon Mac (ARM64) and deployed to ECS Fargate which runs x86_64. The two CPU architectures are not compatible.

```bash
# Fix: tell Docker to build for the target architecture explicitly
docker build --platform linux/amd64 ...
```

This is now a line in the deploy script. The cross-platform build uses QEMU emulation on the Mac, making it 2-3× slower, but the resulting image runs correctly on ECS.

### Bug 2 — Prisma engine failed to load on Alpine

After fixing the architecture mismatch, the next error was:

```
Prisma failed to detect the libssl/openssl version to use.
Error: Could not parse schema engine response
```

Prisma ships native Rust binaries that require OpenSSL. The `node:22-alpine` base image does not include it. Two fixes were needed:

```dockerfile
# Install OpenSSL in the Docker image
RUN apk add --no-cache openssl
```

```prisma
# Tell Prisma to download the Alpine-specific binary
generator client {
  provider      = "prisma-client-js"
  binaryTargets = ["native", "linux-musl-openssl-3.0.x"]
}
```

The `binaryTargets` field tells Prisma to download two engine binaries at generate time: one for the local Mac (development) and one for Alpine Linux (production). Without this, only the Mac binary ships inside the Docker image.

### Bug 3 — Invalid port number in DATABASE_URL

```
Error: P1013: The provided database string is invalid.
invalid port number in database URL.
```

The randomly generated database password contained special characters like `:`, `?`, and `#`. These characters have meaning inside a URL, so the parser was confused about where the password ended and the host began.

```
postgresql://postgres:abc:xyz@hostname:5432/db
                          ↑
                     parser thinks this is the port separator
```

Fix: URL-encode the password when building the connection string in Terraform.

```hcl
value = "postgresql://${username}:${urlencode(password)}@${endpoint}/${db_name}"
```

### Bug 4 — Frontend calling the wrong API

The React app used a relative URL `/api/v1/data/shorten`. Locally, Vite's dev proxy intercepts this and forwards it to `localhost:3001`. In production, the app is served from S3/CloudFront, so the request went to `go.khoitv.com/api/v1/data/shorten` — hitting the S3 bucket instead of the API.

Fix: a Vite environment variable baked into the production build.

```
# apps/web/.env.production
VITE_API_URL=https://api.go.khoitv.com
```

```typescript
const API_BASE = import.meta.env.VITE_API_URL ?? '';

fetch(`${API_BASE}/api/v1/data/shorten`, ...)
```

In local development, `VITE_API_URL` is undefined, so `API_BASE` is an empty string and the Vite proxy handles routing. In production, the full API domain is embedded at build time.

---

## Cost management

A full-stack AWS environment running 24/7 is expensive. For a project that does not need to be always-on, having scripts to pause and resume the environment makes sense.

**Pause (~$32/month, 8 minute restart):** Scale ECS to zero, stop the RDS instance, destroy the NAT gateway. The ALB and ElastiCache stay alive for faster restart.

**Full shutdown (~$0.10/month, 25 minute restart):** Take an RDS snapshot to preserve all data, then run `terraform destroy`. The only remaining cost is the snapshot storage at ~$0.10/month. Running `recreate.sh <snapshot-id>` restores the entire stack from scratch including the URL data.

---

## What I would do differently

**Use an ID generator service.** The current approach of using a database auto-increment ID works, but it couples ID generation to a single database. At extreme scale, this becomes a bottleneck. A distributed ID generator like Twitter's Snowflake or a simple counter in Redis would decouple the two concerns.

**Add a short code reservation step.** The current write flow creates a row with an empty `short_url`, encodes the ID, then updates the row. This two-step write is slightly awkward. A cleaner approach would be to pre-compute the next ID, encode it, and insert in a single step.

**Dedicated redirect domain.** The short URLs live at `api.go.khoitv.com/api/v1/<code>` — that prefix is longer than ideal. In a real product you would have a separate short domain like `go.kh` where the redirect is at `go.kh/<code>`.

---

## Key takeaways

1. **System design before code.** Working out the numbers (1,160 writes/sec, 11,600 reads/sec, 365 billion records) shaped every architecture decision that followed.

2. **The read path is the hot path.** A 10:1 read-to-write ratio means redirects need to be fast above everything else. Redis cache-first on every redirect is the right call.

3. **Base 62 is a precision choice.** Not base 64 (special characters break URLs), not base 100 (requires non-typeable symbols), not MD5 (collisions). Base 62 is the maximum that works within URL constraints with satisfying mathematical properties.

4. **Infrastructure bugs are real bugs.** Four production bugs in a row — all of them invisible in local development. Architecture mismatch, missing system libraries, character encoding in connection strings, and environment-specific API routing. Each one taught something.

5. **Cost is an architecture concern.** $43/month for a NAT gateway nobody uses at 2am is worth designing around. Building stop/start scripts into the project from the beginning makes the infrastructure manageable.

---

## Project links

- **Web:** https://go.khoitv.com
- **API health:** https://api.go.khoitv.com/health
- **GitHub:** https://github.com/khoitran99/url-shortener
