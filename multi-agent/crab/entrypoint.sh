#!/bin/bash
# =============================================================================
# OpenClaw Gateway Entrypoint with TCP Proxy and Pairing Service
# =============================================================================
#
# This script starts:
# 1. A TCP proxy (socat) in front of the OpenClaw gateway
# 2. A pairing service for WhatsApp/Signal QR code generation
# 3. The OpenClaw gateway itself
#
# Problem:
#   - K8s readiness/startup probes connect to the pod IP (10.244.x.x:18789)
#   - OpenClaw requires device pairing for ALL non-loopback connections
#   - If OpenClaw binds to 0.0.0.0, CLI tools connect via LAN IP → pairing required
#   - If OpenClaw binds to localhost, K8s probes fail → pod never becomes ready
#
# Solution:
#   - OpenClaw binds to localhost:18790 (internal, no pairing issues)
#   - socat binds to 0.0.0.0:18789 and proxies to localhost:18790
#   - Pairing service runs on localhost:18791 (internal only)
#   - Another socat proxy on 0.0.0.0:18792 forwards to pairing service
#   - K8s probes hit socat → forwarded to OpenClaw → everything works
#
# This decouples K8s infrastructure from OpenClaw's security model.
# =============================================================================

set -e

# Bootstrap GitHub SSH key material in the background during container startup.
# This is idempotent and only generates a key if one does not already exist.
bootstrap_github_ssh() {
    if [ "${OPENCLAW_TIER:-unknown}" != "code" ]; then
        echo "[entrypoint] OPENCLAW_TIER=${OPENCLAW_TIER:-unknown}; skipping GitHub SSH bootstrap"
        return
    fi

    if [ "${ENABLE_GITHUB_SSH_BOOTSTRAP:-1}" != "1" ]; then
        echo "[entrypoint] GitHub SSH bootstrap disabled (ENABLE_GITHUB_SSH_BOOTSTRAP!=1)"
        return
    fi

    if ! command -v ssh-keygen >/dev/null 2>&1; then
        echo "[entrypoint] ssh-keygen not available, skipping GitHub SSH bootstrap"
        return
    fi

    local ssh_dir="${HOME}/.ssh"
    local key_path="${GITHUB_SSH_KEY_PATH:-${ssh_dir}/id_ed25519_github}"
    local pub_path="${key_path}.pub"
    local key_type="${GITHUB_SSH_KEY_TYPE:-ed25519}"
    local kdf_rounds="${GITHUB_SSH_KEY_KDF_ROUNDS:-100}"
    local key_comment="${GITHUB_SSH_KEY_COMMENT:-${USER:-moltenbot}@${HOSTNAME:-container}}"
    local key_passphrase="${GITHUB_SSH_KEY_PASSPHRASE:-}"
    local published_pub_path="${GITHUB_SSH_PUBLIC_KEY_PATH:-/tmp/github_ssh_public_key.pub}"

    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"

    if [ ! -f "${key_path}" ]; then
        umask 077
        if ssh-keygen -t "${key_type}" -a "${kdf_rounds}" -f "${key_path}" -N "${key_passphrase}" -C "${key_comment}" >/dev/null 2>&1; then
            echo "[entrypoint] Generated GitHub SSH key: ${pub_path}"
        else
            echo "[entrypoint] WARNING: Failed to generate GitHub SSH key"
            return
        fi
    else
        echo "[entrypoint] Reusing existing GitHub SSH key: ${pub_path}"
    fi

    chmod 600 "${key_path}" 2>/dev/null || true
    chmod 644 "${pub_path}" 2>/dev/null || true
    cp "${pub_path}" "${published_pub_path}" 2>/dev/null || true
    chmod 644 "${published_pub_path}" 2>/dev/null || true

    local ssh_config="${ssh_dir}/config"
    if [ ! -f "${ssh_config}" ] || ! grep -q "Host github.com" "${ssh_config}"; then
        {
            echo ""
            echo "Host github.com"
            echo "    HostName github.com"
            echo "    User git"
            echo "    IdentityFile ${key_path}"
            echo "    IdentitiesOnly yes"
            echo "    AddKeysToAgent yes"
        } >> "${ssh_config}"
        chmod 600 "${ssh_config}"
        echo "[entrypoint] Added GitHub SSH host config to ${ssh_config}"
    fi
}

# Run key bootstrap asynchronously so gateway startup is not delayed.
bootstrap_github_ssh &

# Port configuration
EXTERNAL_PORT=${EXTERNAL_PORT:-18789}          # K8s probes connect here (OpenClaw)
INTERNAL_PORT=${INTERNAL_PORT:-18790}          # OpenClaw gateway listens here
PAIRING_EXTERNAL_PORT=${PAIRING_EXTERNAL_PORT:-18792}  # Core server calls here
PAIRING_INTERNAL_PORT=${PAIRING_INTERNAL_PORT:-18791}  # Pairing service listens here

echo "[entrypoint] Starting TCP proxy: 0.0.0.0:${EXTERNAL_PORT} → localhost:${INTERNAL_PORT}"

# Start socat for OpenClaw gateway
socat TCP-LISTEN:${EXTERNAL_PORT},fork,reuseaddr TCP:127.0.0.1:${INTERNAL_PORT} &
SOCAT_PID=$!

# Give socat a moment to bind
sleep 0.5

# Verify socat is running
if ! kill -0 $SOCAT_PID 2>/dev/null; then
    echo "[entrypoint] ERROR: socat failed to start"
    exit 1
fi

echo "[entrypoint] TCP proxy started (PID: ${SOCAT_PID})"

# Start pairing service if it exists
PAIRING_SERVICE_DIR="/opt/pairing-service"
if [ -f "${PAIRING_SERVICE_DIR}/dist/index.js" ]; then
    echo "[entrypoint] Starting pairing service on localhost:${PAIRING_INTERNAL_PORT}"

    # Start pairing service in background
    PAIRING_SERVICE_PORT=${PAIRING_INTERNAL_PORT} node ${PAIRING_SERVICE_DIR}/dist/index.js &
    PAIRING_PID=$!

    sleep 0.5

    if kill -0 $PAIRING_PID 2>/dev/null; then
        echo "[entrypoint] Pairing service started (PID: ${PAIRING_PID})"

        # Start socat proxy for pairing service
        echo "[entrypoint] Starting pairing proxy: 0.0.0.0:${PAIRING_EXTERNAL_PORT} → localhost:${PAIRING_INTERNAL_PORT}"
        socat TCP-LISTEN:${PAIRING_EXTERNAL_PORT},fork,reuseaddr TCP:127.0.0.1:${PAIRING_INTERNAL_PORT} &
        PAIRING_SOCAT_PID=$!
    else
        echo "[entrypoint] WARNING: Pairing service failed to start"
        PAIRING_PID=""
    fi
else
    echo "[entrypoint] Pairing service not found, skipping"
    PAIRING_PID=""
fi

echo "[entrypoint] Starting OpenClaw gateway on localhost:${INTERNAL_PORT}"

# Trap to clean up background processes when the main process exits
cleanup() {
    echo "[entrypoint] Shutting down..."
    kill $SOCAT_PID 2>/dev/null || true
    [ -n "$PAIRING_PID" ] && kill $PAIRING_PID 2>/dev/null || true
    [ -n "$PAIRING_SOCAT_PID" ] && kill $PAIRING_SOCAT_PID 2>/dev/null || true
}
trap cleanup EXIT

# Start OpenClaw gateway (exec replaces this script, becoming PID 1)
# The --port flag overrides the config file port
exec openclaw gateway --port ${INTERNAL_PORT}
