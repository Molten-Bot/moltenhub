FROM moltenbot/openclaw:2026.3.2 AS builder


# Install additional npm packages globally
RUN npm install -g @augmentcode/auggie @openai/codex @polyskill/cli

# Run custom install scripts
RUN curl -fsSL https://claude.ai/install.sh | bash


# Build pairing service for WhatsApp/Signal QR code pairing
WORKDIR /build/pairing-service
COPY pairing-service/package*.json ./
RUN npm install
COPY pairing-service/ ./
RUN npm run build

FROM node:25-trixie-slim

# Install Chromium browser and dependencies for OpenClaw browser automation
# Uses Playwright's install command which handles all system dependencies
# --with-deps installs both the browser and required system libraries
# Browser is installed to a shared location accessible by all users
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
RUN npx -y playwright@1.58.2 install --with-deps chromium && \
    # Create stable symlink: /opt/playwright-browsers/chromium -> chromium-<version>
    # This allows OpenClaw config to use a fixed executablePath regardless of Playwright version
    cd /opt/playwright-browsers && \
    ln -s chromium-*/chrome-linux chromium


RUN apt-get update && apt-get install -y \
    curl \
    wget \
    poppler-utils \
    openssh-client \
    git \
    gh \
    socat \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user and group (UID 1001 to avoid conflict with node user)
RUN groupadd -g 1001 moltenbot && \
    useradd -m -u 1001 -g moltenbot moltenbot

# Copy openclaw and additional npm packages from builder
# Use --link to preserve symlinks
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=builder /usr/local/bin /usr/local/bin

RUN mkdir -p /home/moltenbot/.openclaw/ && \
    mkdir -p /home/moltenbot/.openclaw/agents && \
    mkdir -p /home/moltenbot/.openclaw/canvas && \
    mkdir -p /home/moltenbot/.openclaw/credentials && \
    mkdir -p /home/moltenbot/.openclaw/devices && \
    mkdir -p /home/moltenbot/.openclaw/identity && \
    mkdir -p /home/moltenbot/.openclaw/skills && \
    mkdir -p /home/moltenbot/.openclaw/models/ && \
    mkdir -p /home/moltenbot/.node-llama-cpp/models/ && \
    mkdir -p /home/moltenbot/.openclaw/whatsapp-session && \
    chown -R moltenbot:moltenbot /home/moltenbot/.openclaw

COPY --chown=moltenbot:moltenbot ./skills /home/moltenbot/.openclaw/skills


# Copy pairing service from builder
COPY --from=builder /build/pairing-service/dist /opt/pairing-service/dist
COPY --from=builder /build/pairing-service/node_modules /opt/pairing-service/node_modules
COPY --from=builder /build/pairing-service/package.json /opt/pairing-service/package.json

# Copy entrypoint script (socat proxy + pairing service + OpenClaw gateway startup)
COPY --chmod=755 ./entrypoint.sh /usr/local/bin/entrypoint.sh

# Pre-download embedding model for local vector search (gVisor sandbox blocks runtime downloads)
RUN mkdir -p /home/moltenbot/.openclaw/models && \
    wget -q -O /home/moltenbot/.openclaw/models/embeddinggemma-300m-qat-Q8_0.gguf https://huggingface.co/ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/resolve/main/embeddinggemma-300m-qat-Q8_0.gguf && \
    chown moltenbot:moltenbot /home/moltenbot/.openclaw/models/embeddinggemma-300m-qat-Q8_0.gguf

# Define mount points for persistent storage
VOLUME ["/mnt/workspace", "/mnt/memory", "/mnt/skills"]

# Switch to non-root user
USER moltenbot

# Security hardening: Set config file permissions
# - .openclaw/: 555 (r-xr-xr-x) - directory is traversable but not writable
# This prevents agents from modifying runtime files or persisting data outside mount points
RUN chmod 700 /home/moltenbot/.openclaw/
RUN chmod 700 /home/moltenbot/.openclaw/credentials

# Suppress punycode deprecation warning from openclaw dependencies
# This is a known issue in the dependency tree, not our code
ENV NODE_OPTIONS="--no-deprecation"
# Set environment variables for OpenClaw
ENV NODE_ENV=production
ENV OPENCLAW_VERSION=shrimp
ENV OPENCLAW_TIER=code

# Expose ports:
# 18789 - OpenClaw gateway (socat proxy)
# 18792 - Pairing service (socat proxy)
EXPOSE 18789 18792

# Health check endpoint (hits socat proxy which forwards to OpenClaw)
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:18789/health || exit 1

# Use entrypoint script that starts socat proxy + pairing service + OpenClaw gateway
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
