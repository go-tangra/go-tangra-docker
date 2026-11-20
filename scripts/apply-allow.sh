#!/usr/bin/env bash
# Re-apply the gateway registration allow-list (module SPIFFE id -> route
# prefixes; name) by re-running the idempotent gateway-bootstrap job, which
# holds the single list in docker-compose.yaml. Use it after anything that
# recreated the gateway database.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose -f docker-compose.yaml up --no-deps --force-recreate gateway-bootstrap
echo 'allow-list applied'
