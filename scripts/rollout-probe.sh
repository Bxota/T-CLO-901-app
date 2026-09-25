#!/usr/bin/env bash
# Hammer a URL while a rollout happens and count non-200 answers.
# Usage: scripts/rollout-probe.sh https://app-stage.bxota.com/ [duration_seconds] [interval_seconds]
# Stage is internal: run it from a laptop on the tailnet.
# Exit 0 when every request returned 200, 1 otherwise. Prints one line per failure.
set -euo pipefail

url=${1:?url required}
duration=${2:-180}
interval=${3:-0.5}

total=0
failed=0
end=$((SECONDS + duration))
while (( SECONDS < end )); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || echo "000")
  total=$((total + 1))
  if [[ "$code" != "200" ]]; then
    failed=$((failed + 1))
    printf '%s non-200: %s\n' "$(date -u +%H:%M:%S)" "$code"
  fi
  sleep "$interval"
done
printf 'requests=%d failed=%d\n' "$total" "$failed"
(( failed == 0 ))
