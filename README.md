# portock-ledger-stack

Single Docker container running Portock, Ledger, Todo, and Carousel, tunneled to the public internet via a shared Cloudflare tunnel.

| App      | Internal port | Public URL                   |
|----------|---------------|-------------------------------|
| Portock  | 8000          | https://portock.rugita.com   |
| Ledger   | 3001          | https://ledger.rugita.com    |
| Todo     | 8090          | https://todo.rugita.com      |
| Carousel | 8091          | https://carousel.rugita.com  |

Todo is a static site (`../todolist/web/`) served by `python -m http.server`.

## Prerequisites

- Docker with BuildKit / Docker Compose v2 (comes with Docker Desktop)
- `~/.cloudflared/9d06b629-5f5b-4497-b781-b5e0164dab41.json` — the **portock** tunnel credentials

## One-time DNS setup

`ledger.rugita.com` currently routes via the old **ledger** tunnel. Re-point it to the **portock** tunnel once:

```sh
cloudflared tunnel route dns portock ledger.rugita.com
```

(Or do it in the Cloudflare dashboard: CNAME `ledger.rugita.com` → `<portock-tunnel-id>.cfargotunnel.com`.)

The old `ledger` tunnel can be left alone or removed:
```sh
cloudflared tunnel delete ledger
```

## Run

```sh
cd ~/workspace/rugita
docker compose up --build          # first run; subsequent: docker compose up -d
```

To tail logs: `docker compose logs -f`

### Portock + Ledger only (no Todo / Carousel)

If `../todolist` and/or `../carousel` aren't checked out, use the minimal
compose file instead — it builds the Dockerfile's `minimal` target, which
never touches those two build contexts, and tunnels only
`portock.rugita.com` / `ledger.rugita.com`:

```sh
cd ~/workspace/rugita
docker compose -f docker-compose.minimal.yml up --build
```

`entrypoint.sh` detects at runtime whether `/app/todo` and `/app/carousel`
exist in the image and skips starting those processes when they don't, so
the same entrypoint script works for both images.

## Persistent data

These host directories are bind-mounted into the container — data survives restarts and is edited in-place:

| Host path                              | Container path                |
|----------------------------------------|-------------------------------|
| `~/workspace/portock/backend/data/`     | `/app/portock/backend/data/`  |
| `~/workspace/Ledger/resources/`         | `/app/ledger/resources/`      |
| `~/workspace/carousel/data/`            | `/app/carousel/data/`         |

`~/.cloudflared/` is mounted read-only for tunnel credentials. `tunnel-config.yml` is mounted at `/app/tunnel-config.yml`.

## Google Sheets auth (Ledger)

Ledger falls back to `resources/service-account.json` (covered by the volume mount above). Alternatively, export the env var before running:

```sh
export GOOGLE_SERVICE_ACCOUNT=$(base64 -i path/to/service-account.json)
docker compose up -d
```

## Stopping

```sh
docker compose down
```
