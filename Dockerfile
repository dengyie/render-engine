# ==========================================
# Build / Base Stage: Alpine Linux (x86_64)
# Minimal footprint, low memory (< 512MB limit)
# ==========================================
FROM golang:alpine AS agent-builder

WORKDIR /src
RUN apk add --no-cache git ca-certificates && \
    git clone --depth 1 https://github.com/dengyie/mangohub.git /src && \
    cd /src/agent && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /usr/local/bin/komari-agent .

FROM alpine:3.20

LABEL maintainer="DevOps Team" \
      description="Modular Web-Box with persistent web terminal, SSH and on-demand extensions on Render Free Tier"

# Explicit upstream release versions for reproducible builds
ARG EASYTIER_VERSION="v2.6.4"
ARG TTYD_VERSION="1.7.7"
ARG SINGBOX_VERSION="1.14.1"

# Set environment
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PORT=10000

# Install runtime dependencies via Alpine apk
RUN apk update && \
    apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      unzip \
      tar \
      gzip \
      openssh \
      iproute2 \
      tmux \
      vim \
      caddy \
      tzdata \
      procps && \
    rm -rf /var/cache/apk/*

# Download and install EasyTier (x86_64) with deterministic version URL
RUN set -eux; \
    echo "Downloading EasyTier ${EASYTIER_VERSION}..."; \
    ET_URL="https://github.com/EasyTier/EasyTier/releases/download/${EASYTIER_VERSION}/easytier-linux-x86_64-${EASYTIER_VERSION}.zip"; \
    curl -sSL "$ET_URL" -o /tmp/easytier.zip; \
    unzip -q /tmp/easytier.zip -d /tmp/easytier; \
    find /tmp/easytier -type f -name "easytier-core" -exec cp {} /usr/local/bin/ \; ; \
    find /tmp/easytier -type f -name "easytier-cli" -exec cp {} /usr/local/bin/ \; 2>/dev/null || true; \
    chmod +x /usr/local/bin/easytier-core; \
    [ -f /usr/local/bin/easytier-cli ] && chmod +x /usr/local/bin/easytier-cli || true; \
    rm -rf /tmp/easytier*

# Download and install ttyd for emergency web terminal
RUN set -eux; \
    echo "Downloading ttyd ${TTYD_VERSION}..."; \
    curl -sSL -o /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64"; \
    chmod +x /usr/local/bin/ttyd

# Download and install sing-box (not shipped in Alpine 3.20 repos:
# `apk add sing-box` fails the build with "no such package" — this broke
# every deploy after 2026-10-17, including the singleton-guard fix).
# Use the -musl tarball: it is statically linked, so it runs on Alpine;
# the plain linux-amd64 build is glibc-linked and fails with "not found"
# inside the container (2026-11-10 c323cbb build).
RUN set -eux; \
    echo "Downloading sing-box ${SINGBOX_VERSION}..."; \
    curl -sSL -o /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64-musl.tar.gz"; \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp; \
    cp "/tmp/sing-box-${SINGBOX_VERSION}-linux-amd64-musl/sing-box" /usr/local/bin/sing-box; \
    chmod +x /usr/local/bin/sing-box; \
    /usr/local/bin/sing-box version; \
    rm -rf /tmp/sing-box*

# Copy compiled Komari telemetry agent
COPY --from=agent-builder /usr/local/bin/komari-agent /usr/local/bin/komari-agent
RUN chmod +x /usr/local/bin/komari-agent

# Configure SSH server defaults
RUN mkdir -p /var/run/sshd /root/.ssh && \
    chmod 700 /root/.ssh

# Copy configuration files and entrypoint
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose Render default port
EXPOSE 10000

# Working directory
WORKDIR /root

# Entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
