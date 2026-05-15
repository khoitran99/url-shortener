# Base-62 Encoding

This document explains why the URL shortener uses base-62 encoding, how the algorithm works, and why we do not go higher than base 62.

---

## The problem it solves

The database assigns each shortened URL a sequential integer ID: `1`, `2`, `3`, `4`…

After 10 years the system will have stored ~365 billion URLs. ID number `365,000,000,000` represented in decimal (base 10) is **12 characters long**:

```
https://api.go.khoitv.com/api/v1/365000000000   ← 12 characters, defeats the purpose
https://api.go.khoitv.com/api/v1/2qgcEKQ        ← 7 characters, same number in base 62
```

Base-62 encoding converts that large integer into a short string using a bigger alphabet.

---

## The core idea — more symbols = fewer characters

A **number** is just a value. A **base** is how you choose to represent that value using a fixed set of symbols (digits).

You already know base 10: you have 10 symbols (`0–9`), and when you run out you combine them (`9 → 10`).

The same rollover logic applies to any base:

```
Base 2  (binary):  symbols  0, 1
Base 10 (decimal): symbols  0, 1, 2, 3, 4, 5, 6, 7, 8, 9
Base 62:           symbols  0–9, a–z, A–Z
```

Counting in each base side by side:

```
Decimal   Base 62
      0         0
      1         1
      9         9   ← base 10 rolls over next; base 62 keeps going
     10         a   ← 'a' is symbol #10 in base 62
     35         z   ← 'z' is symbol #35
     36         A   ← 'A' is symbol #36
     61         Z   ← last single-character value in base 62
     62        10   ← base 62 rolls over here, just like base 10 rolls at 10
    125        21
```

**Key insight:** the more symbols you allow per position, the more information each character carries, so you need fewer characters to represent the same number.

| Base | Symbols | Representation of 1,000,000 | Characters |
|------|---------|----------------------------|-----------|
| 2 | 0–1 | `11110100001001000000` | 20 |
| 10 | 0–9 | `1000000` | 7 |
| 16 | 0–9, a–f | `f4240` | 5 |
| 62 | 0–9, a–z, A–Z | `4c92` | 4 |

---

## Why base 62 specifically

### The URL character constraint

A URL can only contain certain characters without breaking. Anything outside the safe set must be **percent-encoded** — which makes the URL *longer*, not shorter.

```
Safe characters in a URL (RFC 3986 unreserved, no encoding needed):
  0–9          10 characters
  a–z          26 characters
  A–Z          26 characters
  - _ . ~       4 characters
  ─────────────────────────
  Maximum:     66 characters
```

Base 62 uses only `0–9`, `a–z`, and `A–Z` — all safe. Going beyond base 66 forces you into characters like `+`, `/`, or `@` that need encoding:

```
Base 62: api.go.khoitv.com/4c92      ← clean
Base 70: api.go.khoitv.com/4%2B2     ← percent-encoded, now longer
```

**Base 62 is the practical standard. Base 66 is the theoretical ceiling.**

### Diminishing returns

Even ignoring URL constraints, the savings from increasing the base shrink rapidly.

Characters needed to represent 365 billion URLs at different bases:

```
Characters needed = ⌈ log(365,000,000,000) / log(base) ⌉

Base  10: 11.56 / 1.00 = 11.56 → 12 characters
Base  16: 11.56 / 1.20 =  9.63 → 10 characters
Base  36: 11.56 / 1.56 =  7.41 →  8 characters
Base  62: 11.56 / 1.79 =  6.45 →  7 characters  ← we are here
Base 100: 11.56 / 2.00 =  5.78 →  6 characters
Base 200: 11.56 / 2.30 =  5.02 →  6 characters  ← same as base 100, zero gain
Base 999: 11.56 / 3.00 =  3.85 →  4 characters
```

| Jump | Characters saved | New symbols required |
|------|-----------------|---------------------|
| Base 62 → Base 100 | **−1** | 38 fictional symbols |
| Base 100 → Base 200 | **0** | 100 more fictional symbols |
| Base 200 → Base 999 | **−2** | 799 more fictional symbols |

Doubling the base only subtracts a fraction from the length because savings are governed by logarithms, which grow slowly. You would need **1,000 distinct symbols** just to reduce the URL by 3 characters compared to base 62.

**Verdict:** base 62 hits the sweet spot — maximum compression using only real, URL-safe, typeable characters.

---

## The algorithm

Converting an integer to base 62 uses repeated division — the same method you would use to convert any number to any base by hand.

**Rule:** divide by 62, collect the remainder, repeat until the quotient is 0. Read the remainders in reverse order.

### Manual trace — converting 125 to base 62

```
Step 1:  125 ÷ 62 = 2  remainder 1  →  ALPHABET[1] = '1'
Step 2:    2 ÷ 62 = 0  remainder 2  →  ALPHABET[2] = '2'
           ↑ quotient is 0, stop

Remainders collected (bottom to top): 2, 1
Result: "21"

Verify: (2 × 62) + (1 × 1) = 124 + 1 = 125  ✓
```

### Manual trace — the rollover point (62 itself)

```
Step 1:  62 ÷ 62 = 1  remainder 0  →  ALPHABET[0] = '0'
Step 2:   1 ÷ 62 = 0  remainder 1  →  ALPHABET[1] = '1'

Result: "10"
```

This is exactly the same rollover you know from decimal — after `9` comes `10`. In base 62, after `Z` (index 61) comes `10`.

---

## The code

```typescript
// apps/api/src/url/base62.ts

const ALPHABET = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
//               index 0                                                  index 61

const BASE = BigInt(62);

export function encodeBase62(id: bigint): string {
  if (id === 0n) return ALPHABET[0];

  let result = '';
  let n = id;

  while (n > 0n) {
    result = ALPHABET[Number(n % BASE)] + result;  // prepend remainder as a symbol
    n = n / BASE;                                  // integer divide, move to next position
  }

  return result;
}
```

**Why `prepend` instead of `append`?** Each iteration extracts the least significant digit (rightmost). Prepending builds the string left-to-right without needing a reverse at the end.

**Why `BigInt`?** PostgreSQL `BIGSERIAL` IDs can reach 9,223,372,036,854,775,807 (2⁶³−1), which exceeds JavaScript's safe integer limit of 2⁵³−1. Using a regular `number` would silently corrupt large IDs.

```typescript
// Regular number loses precision for large IDs:
const id: number = 9_007_199_254_740_993;   // 2^53 + 1
console.log(id);   // → 9007199254740992   ← wrong, off by 1

// BigInt handles arbitrary size correctly:
const id: bigint = 9_007_199_254_740_993n;
console.log(id);   // → 9007199254740993n  ← correct
```

---

## Capacity proof — why 7 characters covers the entire system

Each position holds one of 62 values. With `n` positions, the total unique codes is `62ⁿ`.

```
n = 1  →              62  unique codes
n = 2  →           3,844
n = 3  →         238,328
n = 4  →      14,776,336
n = 5  →     916,132,832  (< 1 billion — not enough)
n = 6  →  56,800,235,584  (< 365 billion — not enough)
n = 7  →   3,521,614,606,208  ✓  (3.5 trillion — 9.6× safety margin)
```

The system needs to store **365 billion** records over 10 years. 7 characters provides **3.5 trillion** slots — nearly 10 times more than required.

---

## Why not use a hash function instead

An alternative design would be to hash the long URL (MD5, SHA-256, etc.) and take the first 7 characters.

| Approach | Problem |
|----------|---------|
| Hash of URL | **Collisions** — two different URLs can produce the same hash. Requires collision detection and retry logic, adding complexity and DB round-trips. |
| Random string | Must query the DB on every generation to guarantee uniqueness. Expensive at scale. |
| UUID | 36 characters — defeats the purpose of a short URL. |
| **Auto-increment + base-62** | Uniqueness guaranteed by the DB primary key. No collision possible. Deterministic. No extra DB queries. |

The auto-increment primary key is the uniqueness guarantee. Base-62 encoding is purely a compact, URL-safe representation of that integer. The two concerns are completely separated, which is why the implementation is only 13 lines of code.

---

## Summary

| Question | Answer |
|----------|--------|
| Why not base 10? | Too many characters (12 for large IDs) |
| Why base 62? | Maximum URL-safe alphanumeric characters |
| Why not base 100+? | Requires non-URL-safe characters; diminishing returns |
| Why not a hash? | Collisions require extra complexity |
| Why BigInt? | IDs can exceed JavaScript's safe integer range |
| Why 7 characters? | `62⁷ ≈ 3.5 trillion` covers 365 billion URLs with 9.6× safety margin |
