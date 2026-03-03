#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  exchange_roundtrip.sh <base_url> <agent_a_id> <agent_a_token> <agent_b_id> <agent_b_token> <msg_a_to_b> <msg_b_to_a> [pull_timeout_ms]

Arguments:
  base_url        Example: http://localhost:8080
  agent_a_id      Sender/receiver A
  agent_a_token   Bearer token for agent A
  agent_b_id      Sender/receiver B
  agent_b_token   Bearer token for agent B
  msg_a_to_b      Payload expected by B
  msg_b_to_a      Payload expected by A
  pull_timeout_ms Optional pull timeout (default: 5000)
USAGE
}

if [[ $# -lt 7 || $# -gt 8 ]]; then
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
agent_a_id="$2"
agent_a_token="$3"
agent_b_id="$4"
agent_b_token="$5"
msg_a_to_b="$6"
msg_b_to_a="$7"
pull_timeout_ms="${8:-5000}"

if ! [[ "$pull_timeout_ms" =~ ^[0-9]+$ ]]; then
  echo "ERROR: pull_timeout_ms must be an integer" >&2
  exit 1
fi

start_ns="$(python3 - <<'PY'
import time
print(time.time_ns())
PY
)"

publish_tmp="$(mktemp)"
pull_tmp="$(mktemp)"
trap 'rm -f "$publish_tmp" "$pull_tmp"' EXIT

publish_message() {
  local sender_token="$1"
  local to_agent_id="$2"
  local payload="$3"

  local payload_json
  payload_json="$(python3 - "$to_agent_id" "$payload" <<'PY'
import json
import sys
print(json.dumps({
    "to_agent_id": sys.argv[1],
    "content_type": "text/plain",
    "payload": sys.argv[2],
}))
PY
)"

  local status
  status="$(curl -sS -o "$publish_tmp" -w "%{http_code}" \
    -X POST "$base_url/v1/messages/publish" \
    -H "Authorization: Bearer $sender_token" \
    -H "Content-Type: application/json" \
    --data "$payload_json")"

  if [[ "$status" != "202" ]]; then
    local excerpt
    excerpt="$(python3 - "$publish_tmp" <<'PY'
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).read_text(errors="replace")[:300])
PY
)"
    echo "ERROR: publish failed (HTTP $status): $excerpt" >&2
    exit 1
  fi

  python3 - "$publish_tmp" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
message_id = payload.get("message_id")
if not message_id:
    raise SystemExit("missing message_id in publish response")
print(message_id)
PY
}

pull_and_verify() {
  local receiver_token="$1"
  local expected_from="$2"
  local expected_payload="$3"

  local status
  status="$(curl -sS -o "$pull_tmp" -w "%{http_code}" \
    -X GET "$base_url/v1/messages/pull?timeout_ms=$pull_timeout_ms" \
    -H "Authorization: Bearer $receiver_token")"

  if [[ "$status" != "200" ]]; then
    local excerpt
    excerpt="$(python3 - "$pull_tmp" <<'PY'
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).read_text(errors="replace")[:300])
PY
)"
    echo "ERROR: pull failed (HTTP $status): $excerpt" >&2
    exit 1
  fi

  python3 - "$pull_tmp" "$expected_from" "$expected_payload" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
message = payload.get("message", {})
actual_from = message.get("from_agent_id")
actual_payload = message.get("payload")
if actual_from != sys.argv[2]:
    raise SystemExit(f"pull verification failed: expected from_agent_id={sys.argv[2]!r}, got {actual_from!r}")
if actual_payload != sys.argv[3]:
    raise SystemExit(f"pull verification failed: expected payload={sys.argv[3]!r}, got {actual_payload!r}")
print(message.get("message_id", ""))
PY
}

msg_id_a_to_b="$(publish_message "$agent_a_token" "$agent_b_id" "$msg_a_to_b")"
pulled_a_to_b="$(pull_and_verify "$agent_b_token" "$agent_a_id" "$msg_a_to_b")"
msg_id_b_to_a="$(publish_message "$agent_b_token" "$agent_a_id" "$msg_b_to_a")"
pulled_b_to_a="$(pull_and_verify "$agent_a_token" "$agent_b_id" "$msg_b_to_a")"

end_ns="$(python3 - <<'PY'
import time
print(time.time_ns())
PY
)"

python3 - "$msg_id_a_to_b" "$pulled_a_to_b" "$msg_id_b_to_a" "$pulled_b_to_a" "$start_ns" "$end_ns" <<'PY'
import json
import sys
msg_id_a_to_b, pulled_a_to_b, msg_id_b_to_a, pulled_b_to_a, start_ns, end_ns = sys.argv[1:]
result = {
    "status": "ok",
    "a_to_b_publish_message_id": msg_id_a_to_b,
    "a_to_b_pulled_message_id": pulled_a_to_b,
    "b_to_a_publish_message_id": msg_id_b_to_a,
    "b_to_a_pulled_message_id": pulled_b_to_a,
    "elapsed_ms": int((int(end_ns) - int(start_ns)) / 1_000_000),
}
print(json.dumps(result))
PY
