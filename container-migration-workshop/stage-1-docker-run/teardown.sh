#!/usr/bin/env bash
set -euo pipefail

echo "▶ Stopping and removing containers..."
docker rm -f shipit-frontend shipit-api shipit-db 2>/dev/null || true

echo "▶ Removing network..."
docker network rm shipit-net 2>/dev/null || true

echo "  (volume shipit-pgdata preserved — run 'docker volume rm shipit-pgdata' to wipe data)"
echo "✅  Torn down."
