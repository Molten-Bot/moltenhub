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

for cmd in curl python3; do
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

register_payload="$(python3 - "$agent_id" <<'PY'
import json
import sys
print(json.dumps({"agent_id": sys.argv[1]}))
PY
)"

register_status="$(curl -sS -o "$register_tmp" -w "%{http_code}" \
  -X POST "$base_url/v1/agents/register" \
  -H "Content-Type: application/json" \
  --data "$register_payload")"

if [[ "$register_status" != "201" ]]; then
  excerpt="$(python3 - "$register_tmp" <<'PY'
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).read_text(errors="replace")[:300])
PY
)"
  echo "ERROR: register failed (HTTP $register_status): $excerpt" >&2
  exit 1
fi

token="$(python3 - "$register_tmp" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
token = payload.get("token")
if not token:
    raise SystemExit("missing token in register response")
print(token)
PY
)"

if [[ "$token_output_file" == "-" ]]; then
  printf '%s\n' "$token"
else
  umask 077
  printf '%s\n' "$token" > "$token_output_file"
fi

allow_payload="$(python3 - "$from_agent_id" <<'PY'
import json
import sys
print(json.dumps({"from_agent_id": sys.argv[1]}))
PY
)"

allow_status="$(curl -sS -o "$allow_tmp" -w "%{http_code}" \
  -X POST "$base_url/v1/agents/$agent_id/allow-inbound" \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data "$allow_payload")"

if [[ "$allow_status" != "200" ]]; then
  excerpt="$(python3 - "$allow_tmp" <<'PY'
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).read_text(errors="replace")[:300])
PY
)"
  echo "ERROR: allow-inbound failed (HTTP $allow_status): $excerpt" >&2
  exit 1
fi

if [[ "$token_output_file" == "-" ]]; then
  echo "OK: registered $agent_id and allowed inbound from $from_agent_id" >&2
else
  python3 - "$agent_id" "$from_agent_id" "$token_output_file" <<'PY'
import json
import sys
agent_id, from_agent_id, token_target = sys.argv[1], sys.argv[2], sys.argv[3]
result = {
    "status": "ok",
    "agent_id": agent_id,
    "allowed_from_agent_id": from_agent_id,
    "token_file": token_target,
}
print(json.dumps(result))
PY
fi
