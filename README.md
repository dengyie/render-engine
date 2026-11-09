<div align="center">

# RenderEngine

**English** · [简体中文](README.zh-CN.md)

[![Render Deploy](https://img.shields.io/badge/Render-Free%20Web%20Service-46E3B7.svg?style=flat-square&logo=render&logoColor=white)](https://render.com)
[![Alpine Linux](https://img.shields.io/badge/Alpine-3.20%20(x86__64)-0D597F.svg?style=flat-square&logo=alpinelinux&logoColor=white)](https://alpinelinux.org/)
[![Caddy](https://img.shields.io/badge/Caddy-v2%20Multiplexing-1F88C0.svg?style=flat-square&logo=caddy&logoColor=white)](https://caddyserver.com/)
[![tmux](https://img.shields.io/badge/tmux-Session%20Persistence-1BB954.svg?style=flat-square&logo=tmux&logoColor=white)](https://github.com/tmux/tmux)
[![EasyTier](https://img.shields.io/badge/EasyTier-Optional%20smoltcp-FF6600.svg?style=flat-square)](https://github.com/EasyTier/EasyTier)
[![sing-box](https://img.shields.io/badge/sing--box-Optional%20v1.10+-E53E3E.svg?style=flat-square)](https://github.com/SagerNet/sing-box)
[![Memory Footprint](https://img.shields.io/badge/RAM-~30MB%20Footprint-blueviolet.svg?style=flat-square)](#technical-implementations)
[![LINUX DO](https://img.shields.io/badge/Thanks-LINUX%20DO-f59e0b.svg?style=flat-square&logo=discourse&logoColor=white)](https://linux.do)

<p>Single-container runtime environment for Render.com free Docker web services.</p>

<p>
  <a href="https://render.com/deploy?repo=https://github.com/dengyie/render-engine">
    <img src="https://render.com/images/deploy-to-render-button.svg" alt="Deploy to Render">
  </a>
</p>

</div>

Single-container runtime environment for Render.com free Docker web services. By default, the system boots into a zero-configuration persistent Linux web terminal (`ttyd` attached to `tmux`), an OpenSSH server, and an automated keepalive health check endpoint behind a Caddy port multiplexer.

Advanced capabilities—including EasyTier user-space mesh networking (`smoltcp`), sing-box traffic proxying, and Komari host telemetry—operate as decoupled modules that activate on demand when corresponding environment variables are defined.

The container operates without `/dev/net/tun` or `CAP_NET_ADMIN` privileges. Core baseline memory consumption remains around 20 MB to 35 MB, staying well below the 512 MB platform limitation.

---

## Architecture

Render free web services expose a single public HTTP port designated by the `$PORT` environment variable (default: `10000`). Caddy terminates incoming HTTPS and WebSocket connections, dispatching traffic to internal services based on URL path routing:

```text
                           Render Public Edge (Port 10000 / HTTPS / WSS)
                                                 │
                                    ┌────────────┴────────────┐
                                    │   Caddy Multiplexer     │
                                    └────────────┬────────────┘
                                                 │
       ┌──────────────────────┬──────────────────┴──────────────────┬──────────────────────┐
       ▼                      ▼                                     ▼                      ▼
Path: /health          Path: /shell/                         Path: /et (WS)         Path: /vless-ws
┌──────────────┐       ┌──────────────────────┐              ┌──────────────────┐   ┌──────────────────┐
│ Health probe │       │ Web terminal (ttyd)  │              │ EasyTier Mesh    │   │ sing-box VLESS   │
│ (200 OK)     │       │ Basic Authentication │              │ (Optional)       │   │ (Optional)       │
└──────────────┘       └──────────┬───────────┘              └────────┬─────────┘   └──────────────────┘
                                  │                                   │
                         [tmux session: main]               [smoltcp user-space]
                                  │                                   │
                      ┌───────────┴───────────┐            ┌──────────┴──────────┐
                      ▼                       ▼            ▼                     ▼
             State persistence        Mouse scroll /   OpenSSH (Port 22/2222) sing-box (Port 10808)
             across reconnects        50k history      (In-mesh direct SSH)   (In-mesh mixed proxy)
```

### Route Allocation

| Path | Protocol | Backend Target | Mode | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `/health` | HTTP GET | Inline response (`200 OK`) | Core | Platform health check and external spindown prevention |
| `/shell/` | WebSocket / HTTP | `127.0.0.1:7681` | Core | ttyd browser terminal with HTTP Basic Authentication |
| `/et` | WebSocket | `127.0.0.1:11010` | Optional | EasyTier peer tunnel (active when EasyTier is enabled) |
| `/vless-ws` | WebSocket | `127.0.0.1:20808` | Optional | sing-box VLESS WebSocket ingress (active when sing-box is enabled) |

---

## Technical Implementations

### 1. Zero-Configuration Baseline
Deploying without setting any custom environment variables yields a fully operational container:
- OpenSSH host keys generate automatically at boot.
- If `SSH_PASS` is omitted, the startup script generates a cryptographically random 18-character password, displays it in the deploy log, and assigns it to both root SSH and the `/shell/` web console.
- External modules (EasyTier, sing-box, Komari) remain disabled by default, conserving CPU cycles and memory.

### 2. Web Terminal Persistence (ttyd and tmux)
Web terminal connections crossing Cloudflare edge nodes or AWS Application Load Balancers terminate idle WebSockets after 60 to 100 seconds. Direct execution of shell binaries causes process termination upon client disconnection.

This repository resolves both limitations:
- **WebSocket Keepalive**: `ttyd` runs with `--ping-interval 15`, issuing heartbeat frames every 15 seconds to prevent edge proxy timeouts. Caddy applies `flush_interval -1` on the `/shell*` route to disable response buffer delays.
- **Session Persistence**: `ttyd` executes `/usr/local/bin/ttyd-session`, running `tmux -f /root/.tmux.conf new-session -A -s main /bin/bash`. Client disconnects detach the tmux client while background processes remain active. Subsequent browser connections attach back to the existing `main` session without loss of working directory, shell variables, or running jobs.
- **Terminal Capabilities**: `/root/.tmux.conf` enables mouse wheel scrolling (`mouse on`), configures a 50,000-line history buffer (`history-limit 50000`), enables dynamic client window adaptation (`window-size latest`), and eliminates escape key delay (`escape-time 0`).
- **Graceful Termination**: The shutdown handler executes `tmux kill-server` during container termination, giving child tasks an opportunity to flush disk writes before receiving host termination signals.

### 3. Decoupled Modular Extensions
- **EasyTier User-Space Mesh (`smoltcp`)**: When `ENABLE_EASYTIER=true` or `ET_NAME` is configured, `easytier-core` initializes with `--no-tun --use-smoltcp`. It drives an internal user-space TCP/IP stack that handles virtual IP routing without host kernel `CAP_NET_ADMIN` privileges.
- **sing-box Ingress/Egress Proxy**: When `ENABLE_SINGBOX=true` or `SINGBOX_UUID` is defined, `sing-box` generates an in-memory runtime configuration listening on `127.0.0.1:20808` (`/vless-ws`) and `0.0.0.0:10808` (mixed HTTP/SOCKS5 proxy).
- **Filesystem Metric Normalization**: In unprivileged containers on Kubernetes, `statvfs("/")` returns metrics from the host node block device (typically 300+ GB used, reporting 80% to 90% utilization). When `KOMARI_TOKEN` is supplied, `komari-agent` overrides the reported volume total with a fixed virtual allocation (`AGENT_FORCE_DISK_TOTAL`, default: 5 GiB) and calculates used capacity using apparent file sizes across the root filesystem.

### 4. Process Supervisor and Circuit Breaker
`entrypoint.sh` acts as PID 1, running a 5-second polling loop. Individual process IDs (`PID_CADDY`, `PID_SSHD`, `PID_TTYD`, `PID_ET`, `PID_SINGBOX`, `PID_KOMARI`) are tracked directly. Unactivated modules are excluded from the loop, preventing unnecessary restart attempts. A circuit breaker terminates the container if any single core managed service crashes more than 5 consecutive times.

---

## Configuration

### Core Settings (Zero-Config Defaults)

| Variable | Default / Behavior | Description |
| :--- | :--- | :--- |
| `PORT` | `10000` | Public container listening port managed by Render |
| `SSH_PASS` | *(Random 18-char)* | Root password for OpenSSH authentication; printed to startup log if auto-generated |
| `TTYD_USER` | `admin` | HTTP Basic Authentication username for `/shell/` |
| `TTYD_PASS` | Matches `SSH_PASS` | HTTP Basic Authentication password for `/shell/` |
| `SSH_PUBKEY` | *(Optional)* | OpenSSH public key appended to `/root/.ssh/authorized_keys` |

### Optional Extension Settings

| Variable | Default / Behavior | Description |
| :--- | :--- | :--- |
| `ENABLE_EASYTIER` | `false` | Explicitly enables EasyTier mesh networking (`true` / `false`) |
| `ET_NAME` | `render-mesh` | EasyTier mesh network identifier (defining this also activates EasyTier) |
| `ET_SECRET` | `render-mesh-secret` | EasyTier shared network secret |
| `ET_IP` | `10.144.144.90` | Static IPv4 address within the EasyTier mesh |
| `ET_HOSTNAME` | `render-box` | Hostname displayed in EasyTier peer tables |
| `ET_PEERS` | *(Optional)* | Comma-separated list of external EasyTier peer addresses (e.g. `tcp://your-vps.com:11010`) |
| `ENABLE_SINGBOX` | `false` | Explicitly enables sing-box proxy (`true` / `false`) |
| `SINGBOX_UUID` | `1da2cc31-2c34-4b0b-b83c-ce3f7b8e6c2c` | User identifier for sing-box VLESS inbound (defining this activates sing-box) |
| `KOMARI_TOKEN` | *(Optional)* | Authentication token for MangoHub / Komari telemetry |
| `KOMARI_ENDPOINT`| *(Optional)* | Dashboard server URL (e.g. `https://your-dashboard.com`, required when token is set) |
| `KOMARI_FORCE_DISK_TOTAL`| `5368709120` | Virtual disk total in bytes for metric override (5 GiB) |
| `ENABLE_KEEPALIVE`| `true` | Enables autonomous inbound HTTP ping daemon to prevent Render 15-min hibernation |
| `KEEPALIVE_INTERVAL`| `300` | Inbound keepalive ping frequency in seconds (default: 300s / 5m) |
| `KEEPALIVE_URL`| *(Auto)* | Target health URL (auto-detected from Render environment variables) |

---

## Deployment

### Method 1: One-Click Deploy (Render Blueprint)
Click the button below to initiate deployment through Render Blueprint:

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/dengyie/render-engine)

### Method 2: Manual Setup
1. Fork or push this repository to GitHub.
2. Sign in to the [Render Dashboard](https://dashboard.render.com/) and create a new **Web Service**.
3. Link the repository and set:
   - **Environment**: `Docker`
   - **Instance Type**: `Free`
   - **Health Check Path**: `/health`
4. Leave environment variables blank for the default minimal setup, or specify custom variables from the configuration table.
5. Deploy the service. View the deploy logs to obtain the generated credentials.

---

## Client Usage

### 1. Web Terminal Access
Access the web terminal directly from any browser without installing local client tools:
1. Navigate to `https://your-service.onrender.com/shell/`.
2. Enter the credentials configured by `TTYD_USER` and `TTYD_PASS` (or retrieved from the deploy log).
3. The session automatically attaches to the persistent `tmux` session. Running `exit` terminates the session and triggers automatic reinitialization on next reload.

### 2. Spindown Prevention & 24/7 Continuity
Render free tier instances automatically hibernate after 15 minutes of inbound HTTP inactivity, destroying ephemeral container state. To ensure 24/7 continuous operation within Render's generous 750 hours/month free quota (`31 days × 24h = 744h`):
- **Built-in Self-Keepalive (Default)**: `render-engine` includes an autonomous keepalive worker (`ENABLE_KEEPALIVE=true`) that automatically detects the instance's public domain (`RENDER_EXTERNAL_URL`) and issues an HTTP GET to `/health` every 5 minutes. This generates real inbound HTTP traffic, permanently keeping the instance awake without requiring external cron services.
- **External Redundancy (Optional)**: You can additionally set up external monitors (e.g. UptimeRobot, Cron-job.org, or a VPS cron job) targeting `https://your-service.onrender.com/health` at 5–10 minute intervals as a cold-start recovery safeguard.

### 3. EasyTier Mesh Connection (When Enabled)
If EasyTier is activated, connect the local machine to the virtual mesh network:

```bash
sudo easytier-core \
  --network-name "render-mesh" \
  --network-secret "YourSecretKey" \
  --ipv4 "10.144.144.100" \
  --peers "wss://your-service.onrender.com/et"
```

Verify mesh connectivity:
```bash
easytier-cli peer
```

Once connected, access the container via OpenSSH over virtual IP:
```bash
ssh root@10.144.144.90
```

### 4. Proxy Services (When Enabled)
- **In-Mesh Mixed Proxy**: Listening on `0.0.0.0:10808` inside the container. Mesh participants can route HTTP and SOCKS5 traffic using `socks5://10.144.144.90:10808` or `http://10.144.144.90:10808`.
- **Public VLESS Inbound**: Listening on `wss://your-service.onrender.com/vless-ws`, handled by Caddy TLS termination and routed to sing-box on `127.0.0.1:20808`.

---

## Acknowledgments

Special thanks to the [LINUX DO](https://linux.do) community for valuable discussions and technical feedback.

---

## License

This project is licensed under the [MIT License](LICENSE).
