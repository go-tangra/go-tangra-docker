#!/usr/bin/env bash
#
# lcm-fingerprint.sh — print the SHA-256 fingerprint of the LCM root
# CA, optionally writing it into .env so docker compose can
# interpolate it as LCM_CA_FINGERPRINT.
#
# Usage:
#   ./scripts/lcm-fingerprint.sh           # print only
#   ./scripts/lcm-fingerprint.sh --write   # also (re)write .env
#
# The CA lives in the lcm-data volume at /app/data/ca/ca.crt. We
# read it via a throwaway alpine container so the script doesn't
# require openssl (or any other tooling) on the host. The volume
# must already exist — bring lcm-service up at least once first
# (docker compose up -d lcm-service && wait for healthy).

set -euo pipefail

WRITE_ENV=0
case "${1:-}" in
  --write|-w) WRITE_ENV=1 ;;
  ""|--print|-p) ;;
  -h|--help)
    sed -n '2,16p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  *)
    echo "unknown option: $1" >&2
    exit 2
    ;;
esac

# The volume is named after the compose project + the volume key.
# `docker compose config --volumes` would give the bare key; we
# resolve the prefixed real name via `docker volume ls`.
VOL_KEY="lcm-data"
PROJECT="$(basename "$(pwd)")"
FULL_VOL="${PROJECT}_${VOL_KEY}"

if ! docker volume inspect "$FULL_VOL" >/dev/null 2>&1; then
  echo "ERROR: docker volume '$FULL_VOL' does not exist." >&2
  echo "       Bring lcm-service up at least once: docker compose up -d lcm-service" >&2
  exit 1
fi

# Read the CA via a one-shot container. sha256sum is in busybox so
# alpine is enough; no extra tooling install. The fingerprint format
# matches what the Go cert.FingerprintSHA256 helper produces — the
# DER bytes' SHA-256, lowercase hex, no separators. We pipe through
# `openssl x509 -outform DER` to convert the PEM file to DER first.
FP=$(docker run --rm -v "${FULL_VOL}:/data:ro" alpine:3.20 sh -c '
  apk add --no-cache openssl >/dev/null 2>&1
  openssl x509 -in /data/ca/ca.crt -outform DER 2>/dev/null | sha256sum | awk "{print \$1}"
')

if [[ -z "$FP" || "${#FP}" -ne 64 ]]; then
  echo "ERROR: failed to compute CA fingerprint (got: $FP)" >&2
  exit 1
fi

if [[ "$WRITE_ENV" -eq 1 ]]; then
  ENV_FILE=".env"
  TMP_FILE="${ENV_FILE}.tmp.$$"
  # Always rewrite via tempfile + rename — works on both GNU and BSD
  # awk, sidesteps `sed -i` portability differences, and the precedence
  # gotchas of sed||awk&&mv chains.
  if [[ -f "$ENV_FILE" ]]; then
    awk -v fp="$FP" '
      /^LCM_CA_FINGERPRINT=/ { print "LCM_CA_FINGERPRINT=" fp; seen=1; next }
      { print }
      END { if (!seen) print "LCM_CA_FINGERPRINT=" fp }
    ' "$ENV_FILE" > "$TMP_FILE"
  else
    echo "LCM_CA_FINGERPRINT=${FP}" > "$TMP_FILE"
  fi
  mv "$TMP_FILE" "$ENV_FILE"
  echo "wrote LCM_CA_FINGERPRINT to $ENV_FILE" >&2
fi

echo "$FP"
