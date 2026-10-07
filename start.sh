#!/usr/bin/env bash
# Start the Portock + Ledger + Todo stack (minimal target) and verify the daily
# temp_swap cron is installed and able to fire.
#
#   ./start.sh                  # build + start + verify
#   ./start.sh --no-build       # skip the image rebuild
#   ./start.sh --run-cron-now   # also run the temp_swap job once, right now
#                               # (does a real STOCK/DIV sync)
set -euo pipefail

cd "$(dirname "$0")"

COMPOSE_FILE=docker-compose.minimal.yml
SERVICE=stack
CRON_TZ=America/Los_Angeles
CRON_HOUR=14
CRON_MIN=30
TUNNEL_CREDS="$HOME/.cloudflared/9d06b629-5f5b-4497-b781-b5e0164dab41.json"

BUILD=1
RUN_CRON_NOW=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --run-cron-now) RUN_CRON_NOW=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }
in_container() { dc exec -T "$SERVICE" "$@"; }

FAILED=0
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; FAILED=1; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ── 1. Docker daemon ─────────────────────────────────────────────────────────
step "Docker"
if ! docker info >/dev/null 2>&1; then
  if [ "$(uname)" = "Darwin" ]; then
    echo "  daemon not running — launching Docker Desktop"
    open -a Docker
  else
    echo "  Docker daemon is not running; start it and re-run." >&2
    exit 1
  fi
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done
  docker info >/dev/null 2>&1 || { echo "  Docker did not come up within 120s" >&2; exit 1; }
fi
ok "daemon is up"

# ── 2. Prerequisites ─────────────────────────────────────────────────────────
step "Prerequisites"
[ -d ../portock ] && ok "../portock" || fail "../portock is missing (build context)"
[ -d ../Ledger ]  && ok "../Ledger"  || fail "../Ledger is missing (build context)"
[ -f "$TUNNEL_CREDS" ] && ok "tunnel credentials" || fail "missing $TUNNEL_CREDS"
if [ -f ../Ledger/resources/service-account.json ] || [ -n "${GOOGLE_SERVICE_ACCOUNT:-}" ]; then
  ok "Google service account"
else
  warn "no ../Ledger/resources/service-account.json or \$GOOGLE_SERVICE_ACCOUNT — Sheets access (incl. the cron job) will fail"
fi
[ -f ../chrome/web/index.html ] && ok "../chrome/web (Todo web app)" || warn "../chrome/web/index.html missing — todo.rugita.com will not be served"
if [ "$FAILED" -ne 0 ]; then
  echo; echo "Fix the above and re-run." >&2
  exit 1
fi

# ── 3. Start ─────────────────────────────────────────────────────────────────
step "Starting Portock + Ledger + Todo"
if [ "$BUILD" -eq 1 ]; then
  dc up --build -d
else
  dc up -d
fi

# ── 4. Wait for the apps ─────────────────────────────────────────────────────
step "Waiting for services"
wait_for_port() { # name port
  for _ in $(seq 1 30); do
    code=$(in_container curl -s -o /dev/null -w '%{http_code}' "http://localhost:$2/" 2>/dev/null || true)
    if [ -n "$code" ] && [ "$code" != "000" ]; then ok "$1 responding on :$2 (HTTP $code)"; return; fi
    sleep 2
  done
  fail "$1 not responding on :$2 after 60s — see: docker compose -f $COMPOSE_FILE logs"
}
wait_for_port Portock 8000
wait_for_port Ledger 3001
# Todo is the static site bind-mounted from ../chrome/web; absent checkout = not served
if [ -f ../chrome/web/index.html ]; then wait_for_port Todo 8090; else warn "Todo skipped — ../chrome/web is not checked out"; fi

# ── 5. Verify cron ───────────────────────────────────────────────────────────
step "Cron"
CRON_FILE=/etc/cron.d/portock-temp-swap

# The image has no procps, so scan /proc rather than using pgrep.
if in_container bash -c 'for c in /proc/[0-9]*/comm; do [ "$(cat "$c" 2>/dev/null)" = cron ] && exit 0; done; exit 1'; then
  ok "cron daemon running"
else
  fail "cron daemon is not running"
fi

if in_container test -f "$CRON_FILE"; then
  perms=$(in_container stat -c '%a %U' "$CRON_FILE" | tr -d '\r')
  if [ "$perms" = "644 root" ]; then ok "$CRON_FILE installed (mode/owner: $perms)"
  else fail "$CRON_FILE has mode/owner '$perms' — cron ignores it unless 644 root"; fi
  # cron silently skips a last line with no trailing newline
  if [ -z "$(in_container tail -c1 "$CRON_FILE" | tr -d '\r\n')" ]; then ok "trailing newline present"
  else fail "$CRON_FILE has no trailing newline — cron will skip the last entry"; fi
  echo "    $(in_container grep -E '^[0-9*]' "$CRON_FILE" | tr -d '\r')"
else
  fail "$CRON_FILE not found in container"
fi

tz=$(in_container date +%Z | tr -d '\r')
case "$tz" in
  PST|PDT) ok "container timezone $tz ($(in_container date '+%F %T' | tr -d '\r'))" ;;
  *) fail "container timezone is '$tz', expected Pacific — 14:30 will fire at the wrong time" ;;
esac

if in_container grep -qE '^(PORTOCK_SHEET_ID|GOOGLE_SERVICE_ACCOUNT_FILE)=' /etc/container.env; then
  ok "/etc/container.env has PORTOCK_SHEET_ID / GOOGLE_SERVICE_ACCOUNT_FILE"
else
  fail "/etc/container.env is missing PORTOCK_SHEET_ID / GOOGLE_SERVICE_ACCOUNT_FILE — the job won't see its config"
fi

if in_container test -x /usr/local/bin/run-portock-temp-swap.sh; then
  ok "job wrapper is executable"
else
  fail "/usr/local/bin/run-portock-temp-swap.sh missing or not executable"
fi

# Next scheduled run, in Pacific time
now_hm=$(TZ=$CRON_TZ date +%H%M)
if [ "$((10#$now_hm))" -lt "$((CRON_HOUR * 100 + CRON_MIN))" ]; then
  next_day=$(TZ=$CRON_TZ date +%F)
else
  next_day=$(TZ=$CRON_TZ date -v+1d +%F 2>/dev/null || TZ=$CRON_TZ date -d tomorrow +%F)
fi
printf '  next run: %s %02d:%02d %s\n' "$next_day" "$CRON_HOUR" "$CRON_MIN" "$CRON_TZ"
warn "cron only fires while the container is up and the Mac is awake — a missed run is not caught up"

# Ledger's scratchpad cron is node-cron inside the Ledger server (not system
# cron); it announces itself in the logs when the server boots.
step "Ledger scratchpad cron (in-process node-cron)"
# Captured once: piping `dc logs` into `grep -q` fails under pipefail when grep exits early.
LOGS=$(dc logs "$SERVICE" 2>&1 || true)
if grep -q '\[scratchpad-cron\] Scheduled' <<<"$LOGS"; then
  ok "scheduled: $(grep '\[scratchpad-cron\] Scheduled' <<<"$LOGS" | tail -1 | sed 's/.*\[scratchpad-cron\] //')"
  echo "    runs at 00:45, 06:45, 09:45, 12:45, 15:45, 18:45, 21:45 (Pacific)"
  last=$(grep -E '\[scratchpad-cron\] (Processed|Failed)' <<<"$LOGS" | tail -1 || true)
  if [ -n "$last" ]; then echo "    last run: ${last#*| }"; else echo "    no run yet since container start"; fi
else
  fail "no '[scratchpad-cron] Scheduled' line in Ledger logs — the cron did not start"
fi

# ── 6. Optional: run the job now ─────────────────────────────────────────────
if [ "$RUN_CRON_NOW" -eq 1 ]; then
  step "Running temp_swap job now"
  if in_container /usr/local/bin/run-portock-temp-swap.sh; then
    ok "job exited 0"
  else
    fail "job failed (exit $?)"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
step "Status"
dc ps
echo
if [ "$FAILED" -eq 0 ]; then
  echo "All checks passed. Logs: docker compose -f $COMPOSE_FILE logs -f"
else
  echo "Some checks failed — see ✘ above. Logs: docker compose -f $COMPOSE_FILE logs -f" >&2
  exit 1
fi
