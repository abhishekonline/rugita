#!/usr/bin/env bash
# Starts Portock, Ledger, and cloudflared. Exits if any process dies so Docker
# can restart the container via restart: unless-stopped.
set -euo pipefail

git config --global user.email "abhishek4615@gmail.com"
git config --global user.name "abhishekonline"

echo "[portock] starting uvicorn on :8000"
cd /app/portock/backend
uvicorn app.main:app --host 0.0.0.0 --port 8000 &
PORTOCK_PID=$!

echo "[ledger] starting Express server on :3001"
cd /app/ledger/server
node_modules/.bin/tsx src/index.ts &
LEDGER_PID=$!

echo "[todo] starting FastAPI (uvicorn) on :8090"
cd /app/todo/server
uvicorn main:app --host 0.0.0.0 --port 8090 &
TODO_PID=$!

echo "[carousel] starting uvicorn on :8091"
cd /app/carousel
uvicorn app.main:app --host 0.0.0.0 --port 8091 &
CAROUSEL_PID=$!

echo "[cloudflared] starting tunnel (portock → portock/ledger/todo/carousel.rugita.com)"
cloudflared tunnel --config /app/tunnel-config.yml run portock &
CF_PID=$!

# Wait for any child to exit; propagate its exit code so Docker restarts.
wait -n $PORTOCK_PID $LEDGER_PID $TODO_PID $CAROUSEL_PID $CF_PID
EXIT_CODE=$?
echo "[entrypoint] a process exited with code $EXIT_CODE — shutting down" >&2
kill $PORTOCK_PID $LEDGER_PID $TODO_PID $CAROUSEL_PID $CF_PID 2>/dev/null || true
exit $EXIT_CODE
