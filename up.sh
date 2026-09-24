#!/usr/bin/env bash
# One-command bring-up of the containerized go-tangra v4 platform stack.
# Run from anywhere; it works in the directory that holds this script.
# Service images are pulled from ghcr.io/go-tangra/<repo>:${TANGRA_VERSION:-4.0.0}.
# docker-compose.yaml is created from docker-compose.yaml.example when missing.
# A docker-compose.override.yaml (git-ignored) is merged when present, e.g. to
# build one service from a local checkout (see README.md).
# If docker needs a group switch on this host, run:  sg docker -c './up.sh'
set -euo pipefail
cd "$(dirname "$0")"
[ -f docker-compose.yaml ] || cp docker-compose.yaml.example docker-compose.yaml
export OPERATOR_EMAIL="${OPERATOR_EMAIL:-admin@example.org}"
export TANGRA_VERSION="${TANGRA_VERSION:-4.0.0}"
# The dns service restarts the PowerDNS containers through the Docker socket;
# it joins the socket's group (compose group_add).
export DOCKER_GID="${DOCKER_GID:-$(stat -c %g /var/run/docker.sock 2>/dev/null || echo 999)}"
C=(docker compose -p freya-stack -f docker-compose.yaml)
UP=(up -d)
if [ -f docker-compose.override.yaml ]; then
  C+=(-f docker-compose.override.yaml)
  UP+=(--build)
fi

"${C[@]}" pull --ignore-buildable --quiet
"${C[@]}" "${UP[@]}"

echo
echo "Stack up (go-tangra $TANGRA_VERSION, operator: $OPERATOR_EMAIL). Accept link:"
link=$("${C[@]}" logs auth-bootstrap 2>/dev/null | grep -oE 'https://[^" ]*invite/accept[^" ]*' | tail -1 || true)
if [ -n "$link" ]; then
  echo "  $link"
else
  echo "  (operator already provisioned, or see: ${C[*]} logs auth-bootstrap)"
fi
echo "Then set password + TOTP and sign in at https://localhost:8443"
