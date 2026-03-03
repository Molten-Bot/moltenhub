#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  bind_agent.sh <base_url> <agent_id> <from_agent_id> [token_output_file]

Arguments:
  base_url          Example: http://localhost:8080
  agent_id          Agent to register and authorize for allow-inbound updates
  from_agent_id     Sender agent to allow inbound from
  token_output_file Optional path to write token. Use '-' or omit to print token to stdout.
USAGE
}

if [[ $# -lt 3 || $# -gt 4 ]]; then
  usage >&2
  exit 1
fi

for cmd in curl node; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: missing required command: $cmd" >&2
    exit 1
  fi
done

base_url="${1%/}"
agent_id="$2"
from_agent_id="$3"
token_output_file="${4:--}"

register_tmp="$(mktemp)"
allow_tmp="$(mktemp)"
trap 'rm -f "$register_tmp" "$allow_tmp"' EXIT

register_payload="$(node -e 'console.log(JSON.stringify({agent_id: process.argv[1]}))' "$agent_id")"

register_status="$(curl -sS -o "$register_tmp" -w "%{http_code}" \
  -X POST "$base_url/v1/agents/register" \
  -H "Content-Type: application/json" \
  --data "$register_payload")"

if [[ "$register_status" != "201" ]]; then
  excerpt="$(node -e 'const fs=require("fs"); const t=fs.readFileSync(process.argv[1],"utf8"); console.log(t.slice(0,300));' "$register_tmp")"
  echo "ERROR: register failed (HTTP $register_status): $excerpt" >&2
  exit 1
fi

token="$(node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); if(!p.token){console.error("missing token in register response"); process.exit(1);} console.log(p.token);' "$register_tmp")"

if [[ "$token_output_file" == "-" ]]; then
  printf '%s\n' "$token"
else
  umask 077
  printf '%s\n' "$token" > "$token_output_file"
fi

allow_payload="$(node -e 'console.log(JSON.stringify({from_agent_id: process.argv[1]}))' "$from_agent_id")"

allow_status="$(curl -sS -o "$allow_tmp" -w "%{http_code}" \
  -X POST "$base_url/v1/agents/$agent_id/allow-inbound" \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data "$allow_payload")"

if [[ "$allow_status" != "200" ]]; then
  excerpt="$(node -e 'const fs=require("fs"); const t=fs.readFileSync(process.argv[1],"utf8"); console.log(t.slice(0,300));' "$allow_tmp")"
  echo "ERROR: allow-inbound failed (HTTP $allow_status): $excerpt" >&2
  exit 1
fi

if [[ "$token_output_file" == "-" ]]; then
  echo "OK: registered $agent_id and allowed inbound from $from_agent_id" >&2
else
  node -e '
const result = {
  status: "ok",
  agent_id: process.argv[1],
  allowed_from_agent_id: process.argv[2],
  token_file: process.argv[3],
};
console.log(JSON.stringify(result));
' "$agent_id" "$from_agent_id" "$token_output_file"
fi
