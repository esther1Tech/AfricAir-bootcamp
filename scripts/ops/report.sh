#!/usr/bin/env bash
# report.sh - summarise the nginx JSON access log.
# Usage: report.sh [logfile]   (default: /var/log/nginx/africair.access.json)
set -Eeuo pipefail

LOG="${1:-/var/log/nginx/africair.access.json}"
[[ -r "${LOG}" ]] || { echo "Cannot read ${LOG} (try sudo)" >&2; exit 1; }

# 'fromjson?' skips any line that is not valid JSON (e.g. a half-written line).
fields() { jq -Rr "fromjson? | $1" "${LOG}"; }

echo "== Top 10 client IPs =="
fields '.remote_addr' | sort | uniq -c | sort -rn | head -10

echo
echo "== Requests by status class =="
fields '.status' | awk '{ print int($1 / 100) "xx" }' | sort | uniq -c

echo
echo "== 10 most requested paths =="
fields '.uri' | sort | uniq -c | sort -rn | head -10

echo
echo "== Requests per minute (last hour) =="
cutoff="$(date -d '1 hour ago' +%Y-%m-%dT%H:%M)"
fields '.time[0:16]' | awk -v c="${cutoff}" '$0 >= c' | sort | uniq -c
