# Manual Testing Guide

This guide covers how to manually verify every user-facing behaviour of the URL Shortener before shipping a change.

---

## Prerequisites

| Requirement | Check |
|-------------|-------|
| Node 22 active | `node --version` → `v22.x.x` |
| pnpm installed | `pnpm --version` → `9.x.x` |
| Docker running | `docker info` exits 0 |
| Dependencies installed | `pnpm install` from repo root |

---

## 1. Start the environment

```bash
# 1. Bring up Postgres + Redis
docker compose up -d

# 2. Confirm both containers are healthy
docker compose ps
# Expected: both STATUS columns show "(healthy)"

# 3. Run database migration (first time only)
pnpm --filter api db:migrate:dev

# 4. Start API and web in parallel
pnpm dev
```

Expected terminal output:
- `API running on http://localhost:3001`
- Vite prints `Local: http://localhost:5173`

---

## 2. API testing (curl)

Use the commands below exactly as written. Expected responses are shown beneath each command.

### 2.1 Shorten a valid URL

```bash
curl -s -X POST http://localhost:3001/api/v1/data/shorten \
  -H "Content-Type: application/json" \
  -d '{"longUrl": "https://github.com/nestjs/nest"}' | jq
```

**Expected — HTTP 201**
```json
{
  "shortUrl": "http://localhost:3001/<code>"
}
```

where `<code>` is a 1–7 character base-62 string (e.g. `4`, `1a`, `Z9kQm2f`).

---

### 2.2 Idempotency — same long URL returns the same short URL

Run the identical request from 2.1 a second time.

**Expected — HTTP 201, identical `shortUrl`**

---

### 2.3 Redirect to original URL

Replace `<code>` with the value returned in 2.1.

```bash
curl -v "http://localhost:3001/api/v1/<code>" 2>&1 | grep -E "< HTTP|< Location"
```

**Expected**
```
< HTTP/1.1 302 Found
< Location: https://github.com/nestjs/nest
```

---

### 2.4 Unknown short code returns 404

```bash
curl -s -o /dev/null -w "%{http_code}" "http://localhost:3001/api/v1/zzzzzzz"
```

**Expected:** `404`

---

### 2.5 Validation — URL without protocol rejected

```bash
curl -s -X POST http://localhost:3001/api/v1/data/shorten \
  -H "Content-Type: application/json" \
  -d '{"longUrl": "github.com/nestjs/nest"}' | jq
```

**Expected — HTTP 400**
```json
{
  "statusCode": 400,
  "message": ["longUrl must be a valid URL with protocol"],
  "error": "Bad Request"
}
```

---

### 2.6 Validation — plain text rejected

```bash
curl -s -X POST http://localhost:3001/api/v1/data/shorten \
  -H "Content-Type: application/json" \
  -d '{"longUrl": "not-a-url"}' | jq
```

**Expected — HTTP 400** (same shape as 2.5)

---

### 2.7 Validation — extra fields rejected

```bash
curl -s -X POST http://localhost:3001/api/v1/data/shorten \
  -H "Content-Type: application/json" \
  -d '{"longUrl": "https://example.com", "hack": true}' | jq
```

**Expected — HTTP 400** (forbidden non-whitelisted property)

---

### 2.8 Validation — missing body

```bash
curl -s -X POST http://localhost:3001/api/v1/data/shorten \
  -H "Content-Type: application/json" \
  -d '{}' | jq
```

**Expected — HTTP 400**

---

### 2.9 Rate limiting

Send 61 requests in quick succession. The 61st should be throttled.

```bash
for i in $(seq 1 61); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:3001/api/v1/data/shorten \
    -H "Content-Type: application/json" \
    -d "{\"longUrl\": \"https://example.com/$i\"}")
  echo "Request $i: $STATUS"
done
```

**Expected:** Requests 1–60 return `201`. Request 61 (and beyond within the same minute) returns `429`.

---

## 3. Frontend testing

Open **http://localhost:5173** in a browser.

### 3.1 Happy path — shorten a URL

| Step | Action | Expected result |
|------|--------|----------------|
| 1 | Paste `https://www.google.com` into the input field | Input is populated |
| 2 | Click **Shorten** | Button shows `Shortening…` while loading |
| 3 | Request completes | A result card appears below the form showing the short URL as a link |
| 4 | Click the short URL link | Browser navigates to (or opens) `https://www.google.com` |

---

### 3.2 Copy to clipboard

| Step | Action | Expected result |
|------|--------|----------------|
| 1 | Complete step 3.1 | Result card is visible |
| 2 | Click **Copy** | Button text changes to `Copied!` for ~2 seconds, then reverts |
| 3 | Paste into any text field | The full short URL (e.g. `http://localhost:3001/4`) is pasted |

---

### 3.3 Idempotency — same URL shortened twice

| Step | Action | Expected result |
|------|--------|----------------|
| 1 | Shorten `https://example.com` | Short URL `A` is displayed |
| 2 | Clear the input, type `https://example.com` again | — |
| 3 | Click **Shorten** | Exactly the same short URL `A` is returned |

---

### 3.4 Validation — URL without protocol

| Step | Action | Expected result |
|------|--------|----------------|
| 1 | Type `example.com` (no `https://`) | — |
| 2 | Click **Shorten** | Browser-native URL validation fires (HTML `type="url"` constraint) **or** the API returns an error card with the validation message |

> Note: modern browsers block submission before the API is called because the input has `type="url"` and `required`.

---

### 3.5 Validation — empty input

| Step | Action | Expected result |
|------|--------|----------------|
| 1 | Clear the input field | — |
| 2 | Click **Shorten** | Browser shows required-field validation; no network request is made |

---

### 3.6 Error state — API unreachable

| Step | Action | Expected result |
|------|--------|----------------|
| 1 | Stop the API (`Ctrl+C` on the `pnpm dev` terminal, or `kill $(lsof -ti:3001)`) | — |
| 2 | Submit any valid URL | Error card appears: `Network error — is the API running?` |
| 3 | Restart the API (`pnpm --filter api dev`) | — |
| 4 | Submit the same URL | Normal short URL is returned |

---

## 4. Cache verification

This confirms the Redis read-through cache is working.

```bash
# 1. Shorten a URL and capture the short code
SHORT=$(curl -s -X POST http://localhost:3001/api/v1/data/shorten \
  -H "Content-Type: application/json" \
  -d '{"longUrl": "https://cache-test.example.com"}' | jq -r '.shortUrl | split("/") | last')

echo "Short code: $SHORT"

# 2. Verify the key exists in Redis
docker exec url-shortener-redis redis-cli GET "redirect:$SHORT"
```

**Expected:** The original URL string is printed, e.g. `https://cache-test.example.com`

---

## 5. Database verification

```bash
# Connect to Postgres and inspect stored records
docker exec -it url-shortener-postgres psql -U postgres -d urlshortener \
  -c "SELECT id, short_url, long_url, created_at FROM urls ORDER BY id DESC LIMIT 10;"
```

**Expected:** Rows appear for every unique long URL shortened. No duplicate `long_url` values should exist (idempotency is enforced by the service layer).

---

## 6. Automated test suite (regression baseline)

Run these before and after any change to confirm no regressions:

```bash
# Unit tests (fast, no infrastructure needed)
pnpm --filter api test

# e2e tests (requires Docker running)
pnpm --filter api test:e2e

# Full pipeline via Turborepo
pnpm test
```

All suites must report **0 failures**.

---

## 7. Teardown

```bash
# Stop Docker services (data persists in named volumes)
docker compose stop

# Stop Docker services and delete all data (full reset)
docker compose down -v
```
