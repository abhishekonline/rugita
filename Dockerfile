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

# ── 4. Base runtime — Portock + Ledger only ──────────────────────────────────
# `minimal` and `full` both build on top of this. Only the `portock` and
# `ledger` named build contexts are touched here, so this stage (and the
# `minimal` target below) never requires `../todolist` or `../carousel` to
# exist on the host.
FROM python:3.11-slim AS base
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates gnupg tini git openssh-client cron tzdata \
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

# System timezone — baked in so cron's "14:30" trigger matches Abhishek's
# actual local wall-clock time (with correct DST handling) rather than UTC.
ENV TZ=America/Los_Angeles
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

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

# ── Portock temp_swap cron ───────────────────────────────────────────────────
# Daily sync of Portock's temp_swap sheet into STOCK/DIV — see
# ~/workspace/portock/backend/app/scripts/process_temp_swap.py.
COPY rugita/cron/portock-temp-swap /etc/cron.d/portock-temp-swap
RUN chmod 0644 /etc/cron.d/portock-temp-swap
COPY rugita/scripts/run-portock-temp-swap.sh /usr/local/bin/run-portock-temp-swap.sh
RUN chmod +x /usr/local/bin/run-portock-temp-swap.sh

# ── Entrypoint ───────────────────────────────────────────────────────────────
COPY rugita/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /app
ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]

# ── 5a. minimal target: Portock + Ledger only ────────────────────────────────
# `docker build --target minimal` (or docker-compose.minimal.yml) stops here.
FROM base AS minimal

# ── 5b. full target: adds Todo + Carousel ────────────────────────────────────
# Default target (last stage in the file) — matches the historical behavior
# of this Dockerfile. Requires `../todolist` and `../carousel` build contexts.
FROM base AS full

# Todo (FastAPI backend serving static frontend + SQLite sync API)
WORKDIR /app/todo
COPY --from=todo server/requirements.txt ./server/requirements.txt
RUN pip install --no-cache-dir -r server/requirements.txt
COPY --from=todo server ./server
COPY --from=todo web ./web

# Carousel (FastAPI serving static frontend, ingest/tag/browse) — needs
# libraw for rawpy, exiftool for IPTC/XMP write-back. Installed only in the
# `full` target so `minimal` stays lean.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libraw-dev exiftool \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app/carousel
COPY --from=carousel pyproject.toml ./
COPY --from=carousel app ./app
COPY --from=carousel web ./web
RUN pip install --no-cache-dir .

WORKDIR /app
