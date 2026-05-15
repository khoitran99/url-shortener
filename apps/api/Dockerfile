# ── Stage 1: install all dependencies ────────────────────────────────────────
FROM node:22-alpine AS installer
# OpenSSL is required by Prisma's native engine binaries on Alpine
RUN apk add --no-cache openssl && corepack enable
WORKDIR /app

# Copy only the manifests first to maximise layer cache reuse
COPY pnpm-workspace.yaml package.json pnpm-lock.yaml tsconfig.base.json ./
COPY packages/types/package.json ./packages/types/package.json
COPY apps/api/package.json ./apps/api/package.json

RUN pnpm install --frozen-lockfile

# ── Stage 2: build ───────────────────────────────────────────────────────────
FROM installer AS builder

COPY packages/types ./packages/types
COPY apps/api ./apps/api

RUN pnpm --filter @url-shortener/types build
RUN pnpm --filter api build
# Regenerate Prisma client so the correct linux-musl binary is included
RUN cd apps/api && pnpm exec prisma generate

# ── Stage 3: production runtime ──────────────────────────────────────────────
FROM node:22-alpine AS runner

# OpenSSL is required at runtime by Prisma's query engine and schema engine
RUN apk add --no-cache openssl
RUN addgroup -S app && adduser -S app -G app
WORKDIR /app
ENV NODE_ENV=production PORT=3001

# pnpm virtual store + root node_modules (contains all runtime packages)
COPY --from=builder --chown=app:app /app/node_modules ./node_modules

# Workspace package required at runtime (symlinked from node_modules/@url-shortener/types)
COPY --from=builder --chown=app:app /app/packages/types/dist ./packages/types/dist
COPY --from=builder --chown=app:app /app/packages/types/package.json ./packages/types/package.json

# API workspace node_modules (symlinks into root node_modules/.pnpm/)
COPY --from=builder --chown=app:app /app/apps/api/node_modules ./apps/api/node_modules
COPY --from=builder --chown=app:app /app/apps/api/dist ./apps/api/dist
COPY --from=builder --chown=app:app /app/apps/api/prisma ./apps/api/prisma
COPY --from=builder --chown=app:app /app/apps/api/package.json ./apps/api/package.json

USER app
WORKDIR /app/apps/api
EXPOSE 3001
CMD ["node", "dist/main.js"]
