#!/usr/bin/env bash
# Wrapper invoked by /etc/cron.d/portock-temp-swap. Cron jobs don't inherit
# the container's environment (GOOGLE_SERVICE_ACCOUNT_FILE, PORTOCK_SHEET_ID,
# PATH, ...) — entrypoint.sh dumps it to /etc/container.env at startup, so
# this sources that before running the actual job.
set -euo pipefail

set -a
# shellcheck disable=SC1091
source /etc/container.env
set +a

cd /app/portock/backend
exec python3 -m app.scripts.process_temp_swap
