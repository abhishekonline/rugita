#!/usr/bin/env bash
# Starts Portock, Ledger, cloudflared, and — if the image was built with the
# `full` target — Todo and Carousel too. A `minimal`-target image simply
# won't have /app/todo or /app/carousel, so those are detected and skipped
# automatically; no env var needed.
# Exits if any process dies so Docker can restart the container via restart: unless-stopped.
set -euo pipefail

git config --global user.email "abhishek4615@gmail.com"
git config --global user.name "abhishekonline"

# Cron jobs (started below) don't inherit this process's environment, so
# snapshot it now for run-portock-temp-swap.sh to source at trigger time.
printenv > /etc/container.env

PIDS=()

echo "[cron] starting cron daemon"
cron -f &
PIDS+=($!)

echo "[portock] starting uvicorn on :8000"
cd /app/portock/backend
uvicorn app.main:app --host 0.0.0.0 --port 8000 &
PIDS+=($!)

echo "[ledger] starting Express server on :3001"
cd /app/ledger/server
node_modules/.bin/tsx src/index.ts &
PIDS+=($!)

if [ -d /app/todo/server ]; then
  echo "[todo] starting FastAPI (uvicorn) on :8090"
  cd /app/todo/server
  uvicorn main:app --host 0.0.0.0 --port 8090 &
  PIDS+=($!)
else
  echo "[todo] not present in this image — skipping"
fi

if [ -d /app/carousel/app ]; then
  echo "[carousel] starting uvicorn on :8091"
  cd /app/carousel
  uvicorn app.main:app --host 0.0.0.0 --port 8091 &
  PIDS+=($!)
else
  echo "[carousel] not present in this image — skipping"
fi

echo "[cloudflared] starting tunnel (config: /app/tunnel-config.yml)"
cloudflared tunnel --config /app/tunnel-config.yml run portock &
PIDS+=($!)

# Wait for any child to exit; propagate its exit code so Docker restarts.
wait -n "${PIDS[@]}"
EXIT_CODE=$?
echo "[entrypoint] a process exited with code $EXIT_CODE — shutting down" >&2
kill "${PIDS[@]}" 2>/dev/null || true
exit $EXIT_CODE
