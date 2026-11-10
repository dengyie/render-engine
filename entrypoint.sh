#!/usr/bin/env bash
# ==============================================================================
# Entrypoint for render-engine on Render Container
# Modular Architecture: Minimal Zero-Config Base with On-Demand Extension
# Production-Hardened Edition
# ==============================================================================
set -Eeuo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

err() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

generate_secure_secret() {
    head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 18
}

log "=========================================================="
log "Starting render-engine Container Initialization..."
log "=========================================================="

# ------------------------------------------------------------------------------
# 1. SSH Server Configuration & Credentials Setup
# ------------------------------------------------------------------------------
log "Configuring OpenSSH server..."

# Generate host keys if not present
ssh-keygen -A >/dev/null 2>&1 || true

# Prepare SSH runtime directories
mkdir -p /var/run/sshd /root/.ssh
chmod 700 /root/.ssh

# Configure sshd_config with modern OpenSSH directives
cat > /etc/ssh/sshd_config << 'EOF'
Port 22
Port 2222
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
KbdInteractiveAuthentication no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
ClientAliveInterval 30
ClientAliveCountMax 3
EOF

# Setup SSH password
IS_RANDOM_PASS=0
if [ -n "${SSH_PASS:-}" ]; then
    echo "root:${SSH_PASS}" | chpasswd
    log "SSH root password configured from SSH_PASS."
else
    RANDOM_PASS=$(generate_secure_secret)
    echo "root:${RANDOM_PASS}" | chpasswd
    warn "SSH_PASS not provided. Generated random root password: ${RANDOM_PASS}"
    SSH_PASS="$RANDOM_PASS"
    IS_RANDOM_PASS=1
fi

# Setup SSH Public Key if provided
if [ -n "${SSH_PUBKEY:-}" ]; then
    echo "${SSH_PUBKEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    log "SSH public key installed to /root/.ssh/authorized_keys."
fi

# Ensure root shell is bash
chsh -s /bin/bash root >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 2. On-Demand Feature Flags & Arguments Preparation
# ------------------------------------------------------------------------------

# Feature 1: EasyTier User-Space Mesh Network
# Explicit credentials or flag take precedence
if [ -n "${ET_NAME:-}" ] || [ -n "${ET_PEERS:-}" ] || [ "${ENABLE_EASYTIER:-}" = "true" ]; then
    ENABLE_EASYTIER="true"
else
    ENABLE_EASYTIER="false"
fi

ET_ARGS=()
if [ "$ENABLE_EASYTIER" = "true" ]; then
    log "EasyTier mesh network is ENABLED. Preparing arguments..."
    ET_NAME="${ET_NAME:-render-mesh}"
    ET_SECRET="${ET_SECRET:-render-mesh-secret}"
    ET_ARGS+=(--network-name "$ET_NAME")
    ET_ARGS+=(--network-secret "$ET_SECRET")

    # IP configuration
    if [ -n "${ET_IP:-}" ]; then
        ET_ARGS+=(-i "$ET_IP")
        log "EasyTier static IP: $ET_IP"
    elif [ "${ET_DHCP:-false}" = "true" ]; then
        ET_ARGS+=(-d)
        log "EasyTier DHCP mode enabled."
    else
        DEFAULT_IP="10.144.144.90"
        ET_ARGS+=(-i "$DEFAULT_IP")
        log "EasyTier IP not set; using default: $DEFAULT_IP"
    fi

    # Local WebSocket listener for Caddy reverse proxy
    ET_ARGS+=(-l "ws://127.0.0.1:11010")

    # Render container has no /dev/net/tun or CAP_NET_ADMIN
    ET_ARGS+=(--no-tun)
    ET_ARGS+=(--use-smoltcp)
    ET_ARGS+=(--tcp-whitelist 22 2222 10808)

    # Hostname
    ET_ARGS+=(--hostname "${ET_HOSTNAME:-render-box}")

    # Peer connections
    if [ -n "${ET_PEERS:-}" ]; then
        IFS=', ' read -r -a PEER_ARRAY <<< "$ET_PEERS"
        for peer in "${PEER_ARRAY[@]}"; do
            if [ -n "$peer" ]; then
                ET_ARGS+=(-p "$peer")
                log "Configured EasyTier peer: $peer"
            fi
        done
    else
        log "No external ET_PEERS defined. Container will wait passively on ws://127.0.0.1:11010"
    fi

    ET_ARGS+=(--console-log-level "${ET_LOG_LEVEL:-info}")
else
    log "EasyTier mesh network is DISABLED (activate by defining ET_NAME or setting ENABLE_EASYTIER=true)."
fi

# Feature 2: sing-box Proxy
if [ -n "${SINGBOX_UUID:-}" ] || [ "${ENABLE_SINGBOX:-}" = "true" ]; then
    ENABLE_SINGBOX="true"
else
    ENABLE_SINGBOX="false"
fi

if [ "$ENABLE_SINGBOX" = "true" ]; then
    log "sing-box proxy is ENABLED. Preparing configuration..."
    SINGBOX_UUID="${SINGBOX_UUID:-1da2cc31-2c34-4b0b-b83c-ce3f7b8e6c2c}"
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/config.json << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "0.0.0.0",
      "listen_port": 10808
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": 20808,
      "users": [
        {
          "uuid": "${SINGBOX_UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vless-ws",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true
  }
}
EOF
else
    log "sing-box proxy is DISABLED (activate by defining SINGBOX_UUID or setting ENABLE_SINGBOX=true)."
fi

# Feature 3: Komari Monitoring Telemetry Agent
# Requires both token and an explicit endpoint to prevent accidental telemetry leakage
ENABLE_KOMARI="false"
if [ -n "${KOMARI_TOKEN:-}" ] || [ -n "${AGENT_TOKEN:-}" ] || [ "${ENABLE_KOMARI:-}" = "true" ]; then
    RESOLVED_TOKEN="${KOMARI_TOKEN:-${AGENT_TOKEN:-}}"
    if [ -z "$RESOLVED_TOKEN" ]; then
        warn "ENABLE_KOMARI requested but neither KOMARI_TOKEN nor AGENT_TOKEN is provided; skipping."
    elif [ -z "${KOMARI_ENDPOINT:-}" ]; then
        warn "KOMARI_TOKEN provided but KOMARI_ENDPOINT is missing; skipping to prevent unauthorized telemetry routing."
    else
        ENABLE_KOMARI="true"
        log "Komari monitoring agent is ENABLED (Endpoint: ${KOMARI_ENDPOINT})."
        DEFAULT_KOMARI_FORCE_DISK_TOTAL="5368709120"
        FORCE_DISK_TOTAL="${KOMARI_FORCE_DISK_TOTAL:-${AGENT_FORCE_DISK_TOTAL:-$DEFAULT_KOMARI_FORCE_DISK_TOTAL}}"
        cat > /etc/komari-agent.env << EOF
export AGENT_ENDPOINT="${KOMARI_ENDPOINT}"
export AGENT_TOKEN="${RESOLVED_TOKEN}"
export AGENT_INCLUDE_MOUNTPOINTS="/"
export AGENT_FORCE_DISK_TOTAL="${FORCE_DISK_TOTAL}"
export AGENT_INCLUDE_NICS="eth0"
export AGENT_DISABLE_WEB_SSH="true"
export AGENT_DISABLE_AUTO_UPDATE="true"
export AGENT_MONTH_ROTATE="1"
export AGENT_INTERVAL="3"
export AGENT_PREFER_IP_VERSION="4"
EOF
        chmod 600 /etc/komari-agent.env
    fi
fi

if [ "$ENABLE_KOMARI" = "false" ]; then
    log "Komari monitoring agent is DISABLED (activate by providing both KOMARI_TOKEN and KOMARI_ENDPOINT)."
fi

# Feature 4: Autonomous Inbound Keepalive Watchdog
# Render Free Tier terminates pods after 15 minutes of inbound HTTP inactivity.
# This autonomous watchdog queries the public edge URL every N seconds, generating
# valid inbound HTTP traffic to guarantee 24/7 continuous operation within the 750h/mo quota.
ENABLE_KEEPALIVE="${ENABLE_KEEPALIVE:-true}"
KEEPALIVE_INTERVAL="${KEEPALIVE_INTERVAL:-300}"
if ! [[ "$KEEPALIVE_INTERVAL" =~ ^[0-9]+$ ]] || [ "$KEEPALIVE_INTERVAL" -le 0 ]; then
    warn "Invalid or non-numeric KEEPALIVE_INTERVAL '${KEEPALIVE_INTERVAL}'; resetting to default 300s."
    KEEPALIVE_INTERVAL=300
fi
KEEPALIVE_URL="${KEEPALIVE_URL:-}"

if [ -z "$KEEPALIVE_URL" ]; then
    if [ -n "${RENDER_EXTERNAL_URL:-}" ]; then
        KEEPALIVE_URL="${RENDER_EXTERNAL_URL%/}/health"
    elif [ -n "${RENDER_EXTERNAL_HOSTNAME:-}" ]; then
        KEEPALIVE_URL="https://${RENDER_EXTERNAL_HOSTNAME}/health"
    fi
fi

# ------------------------------------------------------------------------------
# 3. Process Management & Background Services
# ------------------------------------------------------------------------------
PID_SSHD=""
PID_ET=""
PID_TTYD=""
PID_CADDY=""
PID_KOMARI=""
PID_SINGBOX=""
PID_KEEPALIVE=""

cleanup() {
    log "Received shutdown signal. Stopping all background processes gracefully..."

    # 1. Gracefully terminate tmux server and any active web terminal child tasks
    if command -v tmux >/dev/null 2>&1; then
        tmux kill-server 2>/dev/null || true
    fi

    # 2. Terminate all active managed service daemons (including child process groups)
    local active_pids=("${PID_CADDY:-}" "${PID_ET:-}" "${PID_SSHD:-}" "${PID_TTYD:-}" "${PID_KOMARI:-}" "${PID_SINGBOX:-}" "${PID_KEEPALIVE:-}")
    for pid in "${active_pids[@]}"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    wait || true
    log "All processes terminated. Container exit."
    exit 0
}

trap cleanup SIGINT SIGTERM SIGHUP

# Prepare tmux configuration & persistent session wrapper for ttyd
cat > /root/.tmux.conf << 'EOF'
set -g default-terminal "xterm-256color"
set -g mouse on
set -g history-limit 50000
set -g window-size latest
setw -g aggressive-resize on
set -s escape-time 0
set -g status-style "bg=#2d3748,fg=#f7fafc"
set -g status-left "[#S] "
set -g status-right "%H:%M %d-%b"
EOF

cat > /usr/local/bin/ttyd-session << 'EOF'
#!/usr/bin/env bash
# Attach to existing tmux session 'main' or create new one with bash
exec tmux -f /root/.tmux.conf new-session -A -s main /bin/bash
EOF
chmod +x /usr/local/bin/ttyd-session

# Start SSH daemon (Core Service)
log "Starting sshd on ports 22 and 2222..."
/usr/sbin/sshd -D -e &
PID_SSHD=$!

# Start ttyd (Core Service: Web terminal with tmux session persistence & ping keepalive)
TTYD_USER="${TTYD_USER:-admin}"
TTYD_PASS="${TTYD_PASS:-$SSH_PASS}"

start_ttyd() {
    /usr/local/bin/ttyd \
        --port 7681 \
        --interface 127.0.0.1 \
        --base-path "/shell" \
        --writable \
        --ping-interval 15 \
        -t disableLeaveAlert=true \
        -t fontSize=14 \
        --credential "${TTYD_USER}:${TTYD_PASS}" \
        /usr/local/bin/ttyd-session &
}

log "Starting ttyd on 127.0.0.1:7681 (/shell) with Basic Auth and tmux persistence..."
start_ttyd
PID_TTYD=$!

# Start Caddy Reverse Proxy (Core Service)
PORT="${PORT:-10000}"
export PORT
log "Starting Caddy multiplexer on port $PORT..."
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
PID_CADDY=$!

# Start EasyTier (Optional Extension)
if [ "$ENABLE_EASYTIER" = "true" ] && [ -x /usr/local/bin/easytier-core ]; then
    log "Starting easytier-core..."
    /usr/local/bin/easytier-core "${ET_ARGS[@]}" &
    PID_ET=$!
fi

# Start sing-box (Optional Extension, log streaming)
if [ "$ENABLE_SINGBOX" = "true" ] && command -v sing-box >/dev/null 2>&1; then
    log "Starting sing-box..."
    sing-box run -c /etc/sing-box/config.json &
    PID_SINGBOX=$!
fi

# Start Komari Agent (Optional Extension, log streaming)
if [ "$ENABLE_KOMARI" = "true" ] && [ -x /usr/local/bin/komari-agent ] && [ -f /etc/komari-agent.env ]; then
    log "Starting komari-agent..."
    # Singleton guard (2026-11-10): a stale agent can survive a hot reload
    # while the watchdog thinks it died; a second instance with the same token
    # kicks the first off the server ("has connection exist" storm).
    pkill -f "^/usr/local/bin/komari-agent" 2>/dev/null || true
    (
        set -a
        . /etc/komari-agent.env
        set +a
        exec /usr/local/bin/komari-agent --prefer-cgroup-limits
    ) &
    PID_KOMARI=$!
fi

# Start Autonomous Keepalive Watchdog (Core Resilience Feature)
start_keepalive() {
    log "Starting autonomous keepalive watchdog (Target: ${KEEPALIVE_URL}, Interval: ${KEEPALIVE_INTERVAL}s)..."
    (
        # Initial grace period to allow Caddy and OpenSSH to fully initialize
        sleep 10
        while true; do
            curl -s -m 15 -A "render-engine-keepalive/1.0" "$KEEPALIVE_URL" >/dev/null 2>&1 || true
            sleep "$KEEPALIVE_INTERVAL"
        done
    ) &
    PID_KEEPALIVE=$!
}

if [ "$ENABLE_KEEPALIVE" = "true" ] && [ -n "${KEEPALIVE_URL:-}" ]; then
    start_keepalive
fi

log "=========================================================="
log "render-engine is ready!"
log "=========================================================="
if [ "$IS_RANDOM_PASS" -eq 1 ]; then
    log "Web Terminal   : https://<render-host>/shell/ (User: ${TTYD_USER}, Pass: ${RANDOM_PASS})"
else
    log "Web Terminal   : https://<render-host>/shell/ (User: ${TTYD_USER}, Pass: [CONFIGURED])"
fi
log "Health Probe   : https://<render-host>/health"
if [ "$ENABLE_KEEPALIVE" = "true" ] && [ -n "${KEEPALIVE_URL:-}" ]; then
    log "Auto Keepalive : ENABLED (Target: ${KEEPALIVE_URL}, Interval: ${KEEPALIVE_INTERVAL}s)"
else
    log "Auto Keepalive : DISABLED (Set ENABLE_KEEPALIVE=true or configure KEEPALIVE_URL)"
fi
if [ "$ENABLE_EASYTIER" = "true" ]; then
    log "EasyTier Mesh  : ENABLED (Network: ${ET_NAME}, Hostname: ${ET_HOSTNAME:-render-box})"
else
    log "EasyTier Mesh  : DISABLED (set ENABLE_EASYTIER=true or ET_NAME to activate)"
fi
if [ "$ENABLE_SINGBOX" = "true" ]; then
    log "sing-box Proxy : ENABLED (vless-ws: /vless-ws, mixed: 10808)"
else
    log "sing-box Proxy : DISABLED (set ENABLE_SINGBOX=true or SINGBOX_UUID to activate)"
fi
if [ "$ENABLE_KOMARI" = "true" ]; then
    log "Komari Agent   : ENABLED (Reporting to ${KOMARI_ENDPOINT})"
else
    log "Komari Agent   : DISABLED (set KOMARI_TOKEN and KOMARI_ENDPOINT to activate)"
fi
log "=========================================================="

# ------------------------------------------------------------------------------
# 4. Supervise Processes Loop with Crash-Loop Circuit Breaker and Success-Reset
# ------------------------------------------------------------------------------
FAIL_COUNT_CADDY=0
FAIL_COUNT_ET=0
FAIL_COUNT_SSHD=0
FAIL_COUNT_TTYD=0
FAIL_COUNT_SINGBOX=0
FAIL_COUNT_KOMARI=0
FAIL_COUNT_KEEPALIVE=0
MAX_FAILURES=5

while true; do
    # Check Caddy (Core)
    if kill -0 "$PID_CADDY" 2>/dev/null; then
        FAIL_COUNT_CADDY=0
    else
        ((FAIL_COUNT_CADDY++)) || true
        err "Caddy process died! (Failure count: $FAIL_COUNT_CADDY/$MAX_FAILURES)"
        if [ "$FAIL_COUNT_CADDY" -ge "$MAX_FAILURES" ]; then
            err "Caddy exceeded maximum consecutive crash limit ($MAX_FAILURES). Aborting container."
            exit 1
        fi
        caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
        PID_CADDY=$!
    fi

    # Check SSHD (Core)
    if kill -0 "$PID_SSHD" 2>/dev/null; then
        FAIL_COUNT_SSHD=0
    else
        ((FAIL_COUNT_SSHD++)) || true
        err "sshd process died! (Failure count: $FAIL_COUNT_SSHD/$MAX_FAILURES)"
        if [ "$FAIL_COUNT_SSHD" -ge "$MAX_FAILURES" ]; then
            err "sshd exceeded maximum consecutive crash limit ($MAX_FAILURES). Aborting container."
            exit 1
        fi
        /usr/sbin/sshd -D -e &
        PID_SSHD=$!
    fi

    # Check ttyd (Core)
    if kill -0 "$PID_TTYD" 2>/dev/null; then
        FAIL_COUNT_TTYD=0
    else
        ((FAIL_COUNT_TTYD++)) || true
        err "ttyd process died! (Failure count: $FAIL_COUNT_TTYD/$MAX_FAILURES)"
        if [ "$FAIL_COUNT_TTYD" -ge "$MAX_FAILURES" ]; then
            err "ttyd exceeded maximum consecutive crash limit ($MAX_FAILURES). Aborting container."
            exit 1
        fi
        start_ttyd
        PID_TTYD=$!
    fi

    # Check EasyTier (Only if enabled)
    if [ "$ENABLE_EASYTIER" = "true" ] && [ -n "$PID_ET" ]; then
        if kill -0 "$PID_ET" 2>/dev/null; then
            FAIL_COUNT_ET=0
        else
            ((FAIL_COUNT_ET++)) || true
            err "EasyTier core process died! (Failure count: $FAIL_COUNT_ET/$MAX_FAILURES)"
            if [ "$FAIL_COUNT_ET" -ge "$MAX_FAILURES" ]; then
                err "EasyTier core exceeded maximum consecutive crash limit ($MAX_FAILURES). Aborting container."
                exit 1
            fi
            /usr/local/bin/easytier-core "${ET_ARGS[@]}" &
            PID_ET=$!
        fi
    fi

    # Check sing-box (Only if enabled, with circuit breaker)
    if [ "$ENABLE_SINGBOX" = "true" ] && [ -n "$PID_SINGBOX" ]; then
        if kill -0 "$PID_SINGBOX" 2>/dev/null; then
            FAIL_COUNT_SINGBOX=0
        else
            ((FAIL_COUNT_SINGBOX++)) || true
            warn "sing-box process died! (Failure count: $FAIL_COUNT_SINGBOX/$MAX_FAILURES)"
            if [ "$FAIL_COUNT_SINGBOX" -ge "$MAX_FAILURES" ]; then
                err "sing-box exceeded maximum consecutive restart limit ($MAX_FAILURES). Stopping auto-restart."
                PID_SINGBOX=""
            else
                sing-box run -c /etc/sing-box/config.json &
                PID_SINGBOX=$!
            fi
        fi
    fi

    # Check Komari Agent (Only if enabled, with circuit breaker)
    # Singleton guard (2026-11-10): liveness is judged by a live process scan,
    # not by the stored PID alone — the stored PID can go stale after a hot
    # reload while the old agent is still alive, and spawning a second one
    # with the same token makes the two kick each other off the server
    # ("has connection exist" storm, 2026-11-09/10: ~900 in 36h).
    if [ "$ENABLE_KOMARI" = "true" ] && [ -n "$PID_KOMARI" ]; then
        _komari_live="$(pgrep -f "^/usr/local/bin/komari-agent" 2>/dev/null || true)"
        if [ -n "$_komari_live" ]; then
            # Adopt the live PID and drop any extra duplicates.
            PID_KOMARI="$(printf '%s\n' "$_komari_live" | head -n 1)"
            if [ "$(printf '%s\n' "$_komari_live" | wc -l)" -gt 1 ]; then
                warn "duplicate komari-agent processes detected, keeping PID $PID_KOMARI"
                printf '%s\n' "$_komari_live" | tail -n +2 | while read -r _dup_pid; do
                    kill -9 "$_dup_pid" 2>/dev/null || true
                done
            fi
            FAIL_COUNT_KOMARI=0
        else
            ((FAIL_COUNT_KOMARI++)) || true
            warn "komari-agent process died! (Failure count: $FAIL_COUNT_KOMARI/$MAX_FAILURES)"
            if [ "$FAIL_COUNT_KOMARI" -ge "$MAX_FAILURES" ]; then
                err "komari-agent exceeded maximum consecutive restart limit ($MAX_FAILURES). Stopping auto-restart."
                PID_KOMARI=""
            else
                (
                    set -a
                    . /etc/komari-agent.env
                    set +a
                    exec /usr/local/bin/komari-agent --prefer-cgroup-limits
                ) &
                PID_KOMARI=$!
            fi
        fi
    fi

    # Check Keepalive Watchdog (Only if enabled, with circuit breaker)
    if [ "$ENABLE_KEEPALIVE" = "true" ] && [ -n "${KEEPALIVE_URL:-}" ]; then
        if [ -z "${PID_KEEPALIVE:-}" ] || ! kill -0 "$PID_KEEPALIVE" 2>/dev/null; then
            ((FAIL_COUNT_KEEPALIVE++)) || true
            warn "Keepalive worker died! (Failure count: $FAIL_COUNT_KEEPALIVE/$MAX_FAILURES)"
            if [ "$FAIL_COUNT_KEEPALIVE" -ge "$MAX_FAILURES" ]; then
                err "Keepalive worker exceeded maximum consecutive crash limit ($MAX_FAILURES). Stopping auto-restart."
                PID_KEEPALIVE=""
                ENABLE_KEEPALIVE="false"
            else
                start_keepalive
            fi
        else
            FAIL_COUNT_KEEPALIVE=0
        fi
    fi

    sleep 5
done
