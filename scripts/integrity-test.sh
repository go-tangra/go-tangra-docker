#!/usr/bin/env bash
# Integrity test for the lcm-bootstrapped, short-lived-SVID platform stack.
# Asserts, across an automatic renewal cycle:
#   1. every service runs on an lcm-issued ~5-minute SVID;
#   2. the leaf SVIDs are renewed before expiry (serials change);
#   3. the ROOT CA stays constant (only leaves rotate) — a rotating root would
#      break the mesh (this is the bug this test was written to catch);
#   4. services stay running and keep their gateway registration lease
#      (rotation is non-disruptive: gRPC streams survive leaf renewal).
#
# Start the stack in integrity mode first (short certs + fast renewer), then run
# this script:
#   CERT_TTL=5m RENEW_INTERVAL=210 \
#     docker compose up -d
#   bash scripts/integrity-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PROJECT=freya-stack
COMPOSE="docker compose -p $PROJECT -f docker-compose.yaml"
SERVICES="lcm notification auth"
DOCKER(){ sg docker -c "$*"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/certinfo.go" <<'GO'
package main
import ("crypto/x509";"encoding/pem";"fmt";"io";"os";"time")
func main(){ b,_:=io.ReadAll(os.Stdin); blk,_:=pem.Decode(b); if blk==nil{fmt.Println("NO_PEM 0");return}
 c,err:=x509.ParseCertificate(blk.Bytes); if err!=nil{fmt.Println("PARSE_ERR 0");return}
 fmt.Printf("%s %d\n", c.SerialNumber.String(), int(time.Until(c.NotAfter).Seconds())) }
GO
( cd "$TMP" && go build -o certinfo certinfo.go ) || { echo "FAIL: build certinfo"; exit 1; }
read_cert(){ DOCKER "docker exec ${PROJECT}-renewer-1 cat /certs/$1.pem" 2>/dev/null | "$TMP/certinfo"; }
serial(){ read_cert "$1" | awk '{print $1}'; }
ttl(){ read_cert "$1" | awk '{print $2}'; }
running(){ DOCKER "docker inspect -f '{{.State.Running}}' ${PROJECT}-$1-1" 2>/dev/null | tr -d '[:space:]'; }
registered(){ DOCKER "$COMPOSE logs $1" 2>/dev/null | grep -oE 'registered\":(true|false)' | tail -1; }

echo "== baseline =="
ROOT0=$(serial ca); echo "  root serial=${ROOT0:0:12}"
declare -A BASE
for s in $SERVICES; do BASE[$s]=$(serial "$s"); t=$(ttl "$s")
  echo "  $s leaf=${BASE[$s]:0:12} ttl=${t}s reg=$(registered "$s")"
  [ -z "${BASE[$s]}" ] && { echo "FAIL: no cert for $s"; exit 1; }
  [ "$t" -gt 360 ] && { echo "FAIL: $s not short-lived (${t}s)"; exit 1; }
  [ "$(registered "$s")" = 'registered":true' ] || { echo "FAIL: $s not registered at baseline"; exit 1; }
done

echo "== waiting for a renewal cycle (leaves change; root constant; services stay up+registered) =="
DEADLINE=$(( $(date +%s) + 300 ))
while :; do
  for s in $SERVICES; do
    [ "$(running "$s")" = "true" ] || { echo "FAIL: $s stopped during renewal"; exit 1; }
  done
  # root must never change
  R=$(serial ca)
  [ "$R" = "$ROOT0" ] || { echo "FAIL: ROOT CA changed ${ROOT0:0:12} -> ${R:0:12} (rotating root breaks the mesh)"; exit 1; }
  all=1
  for s in $SERVICES; do [ "$(serial "$s")" = "${BASE[$s]}" ] && all=0; done
  [ "$all" = 1 ] && break
  [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "FAIL: leaves did not all renew in time"; exit 1; }
  sleep 10
done

echo "== post-renewal =="
R=$(serial ca)
[ "$R" = "$ROOT0" ] && echo "  root UNCHANGED: ${ROOT0:0:12} (stable trust root)" || { echo "FAIL: root changed"; exit 1; }
for s in $SERVICES; do
  echo "  $s leaf ${BASE[$s]:0:12} -> $(serial "$s" | cut -c1-12)  ttl=$(ttl "$s")s up=$(running "$s") reg=$(registered "$s")"
  [ "$(running "$s")" = "true" ] || { echo "FAIL: $s not running"; exit 1; }
  [ "$(registered "$s")" = 'registered":true' ] || { echo "FAIL: $s lost registration across renewal"; exit 1; }
done
echo "PASS: leaves renewed under a STABLE root; every service stayed up and registered"
