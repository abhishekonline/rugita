# syntax=docker/dockerfile:1.6

# ── 1. Build Portock frontend ────────────────────────────────────────────────
FROM node:20-alpine AS portock-frontend
WORKDIR /build
COPY --from=portock frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY --from=portock frontend/ ./
RUN npm run build

# ── 2. Build Ledger client ───────────────────────────────────────────────────
FROM node:20-alpine AS ledger-client
WORKDIR /build
COPY --from=ledger client/package.json client/package-lock.json ./
RUN npm ci
COPY --from=ledger client/ ./
RUN npm run build

# ── 3. Ledger server dependencies ────────────────────────────────────────────
FROM node:20-alpine AS ledger-server-deps
WORKDIR /build
COPY --from=ledger server/package.json server/package-lock.json ./
RUN npm ci

# ── 4. Final image ───────────────────────────────────────────────────────────
FROM python:3.11-slim

# Install Node 20, cloudflared, tini (PID-1 signal forwarding), and Carousel's
# runtime deps (libraw for rawpy, exiftool for IPTC/XMP write-back)
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates gnupg tini git openssh-client \
       libraw-dev exiftool \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && mkdir -p /usr/share/keyrings \
    && curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
         | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main" \
         > /etc/apt/sources.list.d/cloudflared.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends cloudflared \
    && rm -rf /var/lib/apt/lists/*

# ── Portock backend ──────────────────────────────────────────────────────────
WORKDIR /app/portock/backend
COPY --from=portock backend/pyproject.toml ./
COPY --from=portock backend/app ./app
RUN pip install --no-cache-dir -e .

# Built Portock frontend
COPY --from=portock-frontend /build/dist /app/portock/frontend/dist

# ── Ledger server ────────────────────────────────────────────────────────────
WORKDIR /app/ledger/server
COPY --from=ledger server/package.json server/package-lock.json server/tsconfig.json ./
COPY --from=ledger server/src ./src
COPY --from=ledger-server-deps /build/node_modules ./node_modules

# Built Ledger client (server resolves ../../client/dist from src/__dirname)
COPY --from=ledger-client /build/dist /app/ledger/client/dist

# ── Todo (FastAPI backend serving static frontend + SQLite sync API) ─────────
WORKDIR /app/todo
COPY --from=todo server/requirements.txt ./server/requirements.txt
RUN pip install --no-cache-dir -r server/requirements.txt
COPY --from=todo server ./server
COPY --from=todo web ./web

# ── Carousel (FastAPI serving static frontend, ingest/tag/browse) ───────────
WORKDIR /app/carousel
COPY --from=carousel pyproject.toml ./
COPY --from=carousel app ./app
COPY --from=carousel web ./web
RUN pip install --no-cache-dir .

# ── Entrypoint ───────────────────────────────────────────────────────────────
COPY portock-ledger-stack/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /app
ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
