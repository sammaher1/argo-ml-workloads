#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-8081}"

curl -s "http://localhost:${PORT}/predict" \
  -H 'content-type: application/json' \
  -d '{"features":{"age":42,"sessions":8,"support_tickets":1},"text":"trial user asked about export limits"}'
printf '\n'

