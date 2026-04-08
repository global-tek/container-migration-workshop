#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  ShipIt Workshop — Stage 1: Raw docker run
#  Run this script to start all three services by hand.
#  Open each collapsed section (▶) in the guide to follow along.
# ─────────────────────────────────────────────────────────────
set -euo pipefail

NETWORK="shipit-net"
DB_VOLUME="shipit-pgdata"
DB_PASSWORD="supersecret"

echo "▶ Creating network: $NETWORK"
docker network create "$NETWORK" 2>/dev/null || echo "  (already exists)"

echo "▶ Creating volume: $DB_VOLUME"
docker volume create "$DB_VOLUME" 2>/dev/null || echo "  (already exists)"

echo "▶ Starting postgres..."
docker run -d \
  --name shipit-db \
  --network "$NETWORK" \
  --volume "$DB_VOLUME":/var/lib/postgresql/data \
  --env POSTGRES_DB=todos \
  --env POSTGRES_USER=postgres \
  --env POSTGRES_PASSWORD="$DB_PASSWORD" \
  --restart unless-stopped \
  postgres:16-alpine

echo "  Waiting for postgres to be ready..."
until docker exec shipit-db pg_isready -U postgres -q; do sleep 1; done
echo "  ✓ postgres ready"

echo "▶ Building API image..."
docker build -t shipit-api ../stage-0-dockerfiles/api

echo "▶ Starting API..."
docker run -d \
  --name shipit-api \
  --network "$NETWORK" \
  --publish 5000:5000 \
  --env DB_HOST=shipit-db \
  --env DB_PORT=5432 \
  --env DB_NAME=todos \
  --env DB_USER=postgres \
  --env DB_PASSWORD="$DB_PASSWORD" \
  --restart unless-stopped \
  shipit-api

echo "▶ Building frontend image..."
docker build -t shipit-frontend ../stage-0-dockerfiles/frontend

echo "▶ Starting frontend..."
docker run -d \
  --name shipit-frontend \
  --network "$NETWORK" \
  --publish 8080:80 \
  --env BACKEND_HOST=shipit-api \
  --restart unless-stopped \
  shipit-frontend

echo ""
echo "✅  All services running!"
echo "   Frontend  →  http://localhost:8080"
echo "   API       →  http://localhost:5000/todos"
echo ""
echo "Useful commands:"
echo "  docker logs -f shipit-api        # stream API logs"
echo "  docker logs -f shipit-frontend   # stream Nginx logs"
echo "  docker exec -it shipit-db psql -U postgres todos"
echo ""
echo "To tear down:  ./teardown.sh"
