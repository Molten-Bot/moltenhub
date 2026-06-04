#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <image-ref> [host-port]" >&2
  exit 1
fi

IMAGE_REF="$1"
HOST_PORT="${2:-18081}"
BASE_URL="http://127.0.0.1:${HOST_PORT}"
NETWORK_NAME="moltenhub-s3-smoke-${HOST_PORT}"
MINIO_CONTAINER="moltenhub-s3-smoke-minio-${HOST_PORT}"
HUB_CONTAINER="moltenhub-s3-smoke-hub-${HOST_PORT}"
MINIO_IMAGE="${MINIO_IMAGE:-quay.io/minio/minio:latest}"
MC_IMAGE="${MC_IMAGE:-quay.io/minio/mc:latest}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
if [[ -z "${MINIO_ROOT_PASSWORD}" ]]; then
  MINIO_ROOT_PASSWORD="$(python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(32)))
PY
)"
fi
STATE_BUCKET="${MOLTENHUB_STATE_S3_BUCKET:-moltenhub-state-smoke}"
QUEUE_BUCKET="${MOLTENHUB_QUEUE_S3_BUCKET:-moltenhub-queue-smoke}"
HISTORICAL_MESSAGE_COUNT="${MOLTENHUB_S3_SMOKE_HISTORICAL_MESSAGES:-0}"
READY_DEADLINE_SECONDS="${MOLTENHUB_S3_SMOKE_READY_DEADLINE_SECONDS:-0}"
SEED_DIR=""
HUB_STARTED_AT=""

validate_non_negative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${name} must be a non-negative integer, got ${value}" >&2
    exit 1
  fi
}

cleanup() {
  docker rm -f "${HUB_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${MINIO_CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
  if [[ -n "${SEED_DIR}" ]]; then
    rm -rf "${SEED_DIR}" >/dev/null 2>&1 || true
  fi
}

wait_for_minio() {
  local attempts=0
  while true; do
    if docker run --rm --network "${NETWORK_NAME}" \
      -e "MC_HOST_smoke=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@${MINIO_CONTAINER}:9000" \
      "${MC_IMAGE}" ls smoke >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    if [[ "${attempts}" -ge 60 ]]; then
      echo "ERROR: MinIO did not become ready" >&2
      docker logs "${MINIO_CONTAINER}" >&2 || true
      exit 1
    fi
    sleep 1
  done
}

create_buckets() {
  docker run --rm --network "${NETWORK_NAME}" \
    -e "MC_HOST_smoke=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@${MINIO_CONTAINER}:9000" \
    "${MC_IMAGE}" mb --ignore-existing "smoke/${STATE_BUCKET}" "smoke/${QUEUE_BUCKET}" >/dev/null
}

seed_historical_message_records() {
  if (( HISTORICAL_MESSAGE_COUNT <= 0 )); then
    return 0
  fi

  echo "Seeding ${HISTORICAL_MESSAGE_COUNT} historical S3 message records"
  SEED_DIR="$(mktemp -d)"
  mkdir -p "${SEED_DIR}/messages"
  python3 - "${SEED_DIR}/messages" "${HISTORICAL_MESSAGE_COUNT}" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timedelta, timezone

out_dir = pathlib.Path(sys.argv[1])
count = int(sys.argv[2])
base = datetime(2026, 3, 1, 0, 0, 0, tzinfo=timezone.utc)

for i in range(count):
    message_id = f"historical-smoke-{i:06d}"
    created = base + timedelta(seconds=i)
    updated = created + timedelta(seconds=1)
    body = {
        "message": {
            "message_id": message_id,
            "from_agent_uuid": "historical-smoke-agent-a",
            "to_agent_uuid": "historical-smoke-agent-b",
            "sender_org_id": "historical-smoke-org-a",
            "receiver_org_id": "historical-smoke-org-b",
            "content_type": "text/plain",
            "payload": "historical smoke payload",
            "created_at": created.isoformat().replace("+00:00", "Z"),
        },
        "status": "acked",
        "accepted_at": created.isoformat().replace("+00:00", "Z"),
        "updated_at": updated.isoformat().replace("+00:00", "Z"),
        "acked_at": updated.isoformat().replace("+00:00", "Z"),
        "delivery_attempts": 1,
        "requeue_count": 0,
        "idempotent_replays": 0,
    }
    (out_dir / f"{message_id}.json").write_text(json.dumps(body, separators=(",", ":")), encoding="utf-8")
PY

  docker run --rm --network "${NETWORK_NAME}" \
    -e "MC_HOST_smoke=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@${MINIO_CONTAINER}:9000" \
    -v "${SEED_DIR}:/seed:ro" \
    "${MC_IMAGE}" cp --recursive "/seed/messages/" "smoke/${STATE_BUCKET}/moltenhub-state/state/messages/" >/dev/null
}

assert_ready_deadline() {
  if (( READY_DEADLINE_SECONDS <= 0 )) || [[ -z "${HUB_STARTED_AT}" ]]; then
    return 0
  fi

  local now
  local elapsed
  now="$(date +%s)"
  elapsed=$((now - HUB_STARTED_AT))
  if (( elapsed > READY_DEADLINE_SECONDS )); then
    echo "ERROR: S3 smoke target became ready after ${elapsed}s; deadline is ${READY_DEADLINE_SECONDS}s" >&2
    docker logs "${HUB_CONTAINER}" >&2 || true
    exit 1
  fi
  echo "S3 smoke target ready in ${elapsed}s"
}

wait_for_ping() {
  local attempts=0
  while true; do
    local code
    code="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/ping" || true)"
    if [[ "${code}" == "200" || "${code}" == "204" ]]; then
      return 0
    fi

    attempts=$((attempts + 1))
    if [[ "${attempts}" -ge 30 ]]; then
      echo "ERROR: S3 smoke target did not become live at ${BASE_URL}/ping" >&2
      docker logs "${HUB_CONTAINER}" >&2 || true
      exit 1
    fi
    sleep 1
  done
}

wait_for_ready_health() {
  local attempts=0
  local body_file
  body_file="$(mktemp)"
  trap 'rm -f "${body_file}"; cleanup' EXIT

  while true; do
    local code
    code="$(curl -sS -o "${body_file}" -w "%{http_code}" "${BASE_URL}/health" || true)"
    if [[ "${code}" == "200" ]]; then
      if python3 - "${body_file}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

if str(payload.get("boot_status", "")).strip().lower() == "starting":
    raise SystemExit(1)
if str(payload.get("status", "")).strip().lower() != "ok":
    raise SystemExit(1)

storage = payload.get("storage", {})
if storage.get("state", {}).get("backend") != "s3":
    raise SystemExit(1)
if storage.get("queue", {}).get("backend") != "s3":
    raise SystemExit(1)
PY
      then
        rm -f "${body_file}"
        trap cleanup EXIT
        assert_ready_deadline
        return 0
      fi
    fi

    attempts=$((attempts + 1))
    if [[ "${attempts}" -ge 30 ]]; then
      echo "ERROR: S3 smoke target did not become ready at ${BASE_URL}/health" >&2
      if [[ -s "${body_file}" ]]; then
        echo "health response body redacted" >&2
      fi
      docker logs "${HUB_CONTAINER}" >&2 || true
      exit 1
    fi
    sleep 1
  done
}

trap cleanup EXIT
validate_non_negative_integer MOLTENHUB_S3_SMOKE_HISTORICAL_MESSAGES "${HISTORICAL_MESSAGE_COUNT}"
validate_non_negative_integer MOLTENHUB_S3_SMOKE_READY_DEADLINE_SECONDS "${READY_DEADLINE_SECONDS}"
cleanup
docker network create "${NETWORK_NAME}" >/dev/null

docker run -d \
  --name "${MINIO_CONTAINER}" \
  --network "${NETWORK_NAME}" \
  -e "MINIO_ROOT_USER=${MINIO_ROOT_USER}" \
  -e "MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}" \
  "${MINIO_IMAGE}" server /data --address ":9000" >/dev/null

wait_for_minio
create_buckets
seed_historical_message_records

docker run -d \
  --name "${HUB_CONTAINER}" \
  --network "${NETWORK_NAME}" \
  -p "127.0.0.1:${HOST_PORT}:8080" \
  -e HUMAN_AUTH_PROVIDER=dev \
  -e MOLTENHUB_CANONICAL_BASE_URL="${BASE_URL}" \
  -e MOLTENHUB_STATE_BACKEND=s3 \
  -e MOLTENHUB_QUEUE_BACKEND=s3 \
  -e MOLTENHUB_STATE_S3_ENDPOINT="http://${MINIO_CONTAINER}:9000" \
  -e MOLTENHUB_STATE_S3_BUCKET="${STATE_BUCKET}" \
  -e MOLTENHUB_STATE_S3_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
  -e MOLTENHUB_STATE_S3_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
  -e MOLTENHUB_QUEUE_S3_ENDPOINT="http://${MINIO_CONTAINER}:9000" \
  -e MOLTENHUB_QUEUE_S3_BUCKET="${QUEUE_BUCKET}" \
  -e MOLTENHUB_QUEUE_S3_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
  -e MOLTENHUB_QUEUE_S3_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
  "${IMAGE_REF}" >/dev/null
HUB_STARTED_AT="$(date +%s)"

wait_for_ping
wait_for_ready_health

go run ./cmd/moltenhub-smoke -base-url "${BASE_URL}"
