#!/usr/bin/env sh
set -eu

# If no token and no explicit interval set, slow down to 1h by default
if [ -z "${GITHUB_TOKEN:-}" ] && [ -z "${MIRROR_INTERVAL_SECONDS:-}" ]; then
  export MIRROR_INTERVAL_SECONDS=3600
fi

# Kick off an initial mirror sync (non-fatal on failure)
echo "[entrypoint] running initial mirror sync"
sh /app/scripts/mirror.sh || echo "[entrypoint] mirror failed (initial)" >&2

# Then run mirror every 15 minutes in background
(
  while true; do
    sleep "${MIRROR_INTERVAL_SECONDS:-900}"
    echo "[entrypoint] running periodic mirror sync"
    sh /app/scripts/mirror.sh || echo "[entrypoint] mirror failed (periodic)" >&2
  done
) &

# Exec nginx in foreground
exec nginx -g 'daemon off;'
