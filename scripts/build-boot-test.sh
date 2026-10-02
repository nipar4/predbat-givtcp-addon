#!/usr/bin/env bash
# Build (optionally) and boot-test the predbat-givtcp-addon image.
#
# Verifies:
#   - the container boots and reaches Predbat's "update apps.yaml" prompt (proof
#     the predbat service's entrypoint made it through startup without crashing)
#   - no "warning" lines appear in the boot logs (e.g. s6-overlay deprecations -
#     these don't stop the apps.yaml prompt from appearing, so nothing else here
#     would otherwise catch them). GivTCP's own "no inverters found" first-boot
#     banner logs at ERROR level, not WARNING, so it does not trip this check
#     (confirmed against real boot output) - if a future GivTCP/redis/nginx
#     version starts logging something that legitimately contains "warning"
#     during a normal no-hardware boot, scope this check rather than removing it.
#   - all three s6 services (wait-for-ha, givtcp, predbat) are in an expected
#     state via s6-svstat: predbat and givtcp must be "up"; wait-for-ha must be
#     "up" or a self-triggered "down (signal SIGTERM)" (its documented
#     no-op-when-unconfigured behavior)
#
# This test deliberately runs WITHOUT --network host/--privileged: GivTCP's
# scapy-based real-LAN inverter discovery can't be validated on a CI runner
# (no real LAN, no hardware) and a regression there would show up as "scan
# finds nothing" rather than a crash - too dangerous to try to infer from a
# sandboxed run. This script only confirms the three-service chain starts
# cleanly and stays up in the expected "no inverter, no HA" degraded state.
# Production-equivalent verification (real hardware) is a separate, manual step.
#
# Usage:
#   scripts/build-boot-test.sh [--platform linux/amd64] [--timeout 90] [--tag <existing-image-tag>]

set -euo pipefail

platform=""
timeout=120
tag=""

while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --tag) tag="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

platform_args=()
[ -n "$platform" ] && platform_args=(--platform "$platform")

if [ -z "$tag" ]; then
  # shellcheck disable=SC1091
  source "$repo_root/versions.env"
  tag="predbat-givtcp-boot-test:latest"
  echo "==> Building Dockerfile (PREDBAT_VERSION=$PREDBAT_VERSION GIVTCP_VERSION=$GIVTCP_VERSION S6_VERSION=$S6_VERSION)"
  docker build "${platform_args[@]}" \
    -f "$repo_root/Dockerfile" \
    --build-arg "PREDBAT_VERSION=$PREDBAT_VERSION" \
    --build-arg "GIVTCP_VERSION=$GIVTCP_VERSION" \
    --build-arg "S6_VERSION=$S6_VERSION" \
    --build-arg "ADDON_VERSION=$ADDON_VERSION" \
    -t "$tag" "$repo_root"
fi

container="predbat-givtcp-boot-test-$$"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Starting $tag"
docker run -d --name "$container" "${platform_args[@]}" "$tag" >/dev/null

echo "==> Waiting up to ${timeout}s for the apps.yaml prompt..."
elapsed=0
found=0
logs=""
while [ "$elapsed" -lt "$timeout" ]; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != "true" ]; then
    echo "FAIL: container exited early" >&2
    docker logs "$container" >&2
    exit 1
  fi
  logs="$(docker logs "$container" 2>&1)"
  if grep -qi "update apps.yaml" <<<"$logs"; then
    found=1
    break
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

if [ "$found" -ne 1 ]; then
  echo "FAIL: apps.yaml prompt not seen within ${timeout}s" >&2
  echo "$logs" >&2
  exit 1
fi
echo "==> Boot prompt reached"

if grep -qi "warning" <<<"$logs"; then
  echo "FAIL: warning(s) found in boot logs:" >&2
  grep -i "warning" <<<"$logs" >&2
  exit 1
fi
echo "==> No warnings in boot logs"

for svc in predbat givtcp; do
  status="$(docker exec "$container" /package/admin/s6/command/s6-svstat "/run/service/$svc")"
  echo "==> $svc: $status"
  if ! grep -q "^up" <<<"$status"; then
    echo "FAIL: $svc service is not up: $status" >&2
    exit 1
  fi
done

waitforha_status="$(docker exec "$container" /package/admin/s6/command/s6-svstat /run/service/wait-for-ha)"
echo "==> wait-for-ha: $waitforha_status"
# wait-for-ha is optional (only polls HA if WAIT_FOR_HA_HOST/_PORT are set): "up"
# (actively waiting/polling) or a self-triggered "down (signal SIGTERM)" (its
# documented no-op-when-unconfigured behavior) are both fine; anything else
# suggests a crash loop.
if ! grep -qE "^(up|down \(signal SIGTERM\))" <<<"$waitforha_status"; then
  echo "FAIL: wait-for-ha service in unexpected state: $waitforha_status" >&2
  exit 1
fi

echo "==> PASS: image boots cleanly, no warnings, all three services in expected state"
