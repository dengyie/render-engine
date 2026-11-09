<div align="center">

# RenderEngine

<p>面向 Render.com 免费 Docker Web Service 的单容器全功能运行环境</p>

[![Render Deploy](https://img.shields.io/badge/Render-Free%20Web%20Service-46E3B7.svg?style=flat-square&logo=render&logoColor=white)](https://render.com)
[![Alpine Linux](https://img.shields.io/badge/Alpine-3.20%20(x86__64)-0D597F.svg?style=flat-square&logo=alpinelinux&logoColor=white)](https://alpinelinux.org/)
[![Caddy](https://img.shields.io/badge/Caddy-v2%20Multiplexing-1F88C0.svg?style=flat-square&logo=caddy&logoColor=white)](https://caddyserver.com/)
[![tmux](https://img.shields.io/badge/tmux-Session%20Persistence-1BB954.svg?style=flat-square&logo=tmux&logoColor=white)](https://github.com/tmux/tmux)
[![EasyTier](https://img.shields.io/badge/EasyTier-Optional%20smoltcp-FF6600.svg?style=flat-square)](https://github.com/EasyTier/EasyTier)
[![sing-box](https://img.shields.io/badge/sing--box-Optional%20v1.10+-E53E3E.svg?style=flat-square)](https://github.com/SagerNet/sing-box)
[![Memory Footprint](https://img.shields.io/badge/RAM-~30MB%20Footprint-blueviolet.svg?style=flat-square)](#关键技术实现)
[![LINUX DO](https://img.shields.io/badge/Thanks-LINUX%20DO-f59e0b.svg?style=flat-square&logo=discourse&logoColor=white)](https://linux.do)

[English](README.md) · [简体中文](README.zh-CN.md)

<p>
  <a href="https://render.com/deploy?repo=https://github.com/dengyie/render-engine">
    <img src="https://render.com/images/deploy-to-render-button.svg" alt="Deploy to Render">
  </a>
</p>

</div>

该项目针对 Render.com 免费 Docker Web Service 运行环境设计。默认以零配置启动，在单个容器内整合了基于 ttyd 与 tmux 的持久化 Web 终端、OpenSSH 服务端以及自动化保活探针，由前端 Caddy 负责单端口流量分流。

EasyTier 用户态网格组网（smoltcp）、sing-box 代理以及 Komari 节点监控等高级功能均解耦为可选扩展模块，仅在配置了对应环境变量时按需激活。

容器运行在无 `/dev/net/tun` 设备与无 `CAP_NET_ADMIN` 特权的受限环境中。基础核心组件常驻内存介于 20 MB 至 35 MB 之间，远低于平台 512 MB 的内存上限。

---

## 架构设计

Render 免费实例仅开放由环境变量 `$PORT`（默认 10000）指定的单一公网端口。Caddy 负责终结外部 HTTPS 与 WebSocket 流量，依据请求路径将流量转发至容器内部的对应组件：

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
│ 存活探针     │       │ Web 终端 (ttyd)      │              │ EasyTier 虚拟网  │   │ sing-box VLESS   │
│ (200 OK)     │       │ Basic 身份认证       │              │ (可选模块)       │   │ (可选模块)       │
└──────────────┘       └──────────┬───────────┘              └────────┬─────────┘   └──────────────────┘
                                  │                                   │
                         [tmux 会话: main]                   [smoltcp 用户态]
                                  │                                   │
                      ┌───────────┴───────────┐            ┌──────────┴──────────┐
                      ▼                       ▼            ▼                     ▼
             连接中断状态保持         鼠标滚轮滑动 /       OpenSSH (端口 22/2222) sing-box (端口 10808)
             重连自动恢复上下文       50,000 行历史缓冲    (网格内直连 SSH)       (网格内混合代理)
```

### 路由分发规划

| 请求路径 | 传输协议 | 后端目标 | 属性 | 功能说明 |
| :--- | :--- | :--- | :--- | :--- |
| `/health` | HTTP GET | 内存直接响应（`200 OK`） | 核心 | 供平台健康检查及外部保活探针探测 |
| `/shell/` | WebSocket / HTTP | `127.0.0.1:7681` | 核心 | 受 Basic 认证保护的 ttyd 浏览器终端 |
| `/et` | WebSocket | `127.0.0.1:11010` | 可选 | EasyTier 对等节点传输通道（启用 EasyTier 时生效） |
| `/vless-ws` | WebSocket | `127.0.0.1:20808` | 可选 | sing-box VLESS WebSocket 入站代理（启用代理时生效） |

---

## 关键技术实现

### 1. 零配置极简启动底座
用户在 Render 部署时无需预设任何业务环境变量，容器即可正常运行：
- OpenSSH 自动完成宿主密钥生成。
- 若未提供 `SSH_PASS`，脚本自动生成 18 位随机安全密码，在启动日志中明确输出，并统一配置为 root SSH 密码与 `/shell/` 终端认证凭据。
- EasyTier、sing-box 与 Komari 监控探针默认处于休眠关闭状态，不额外占用 CPU 周期与内存。

### 2. Web 终端断联防护与会话持久化
穿透 Cloudflare CDN 与 AWS Application Load Balancer 时，空闲超过 60 至 100 秒的 WebSocket 会被边缘网关阻断。如果直接运行原生 shell 二进制，一旦客户端连接中断，子进程会立即收到挂断信号退出。

系统实施了针对性工程处理：
- **WebSocket 传输保活**：`ttyd` 启动时指定 `--ping-interval 15`，每隔 15 秒主动下发心跳帧，规避边缘网关因空闲掐断连接。Caddy 对 `/shell*` 路由配置 `flush_interval -1`，关闭反向代理的缓冲区延迟。
- **tmux 会话守护**：`ttyd` 执行 `/usr/local/bin/ttyd-session` 包装脚本，以 `tmux -f /root/.tmux.conf new-session -A -s main /bin/bash` 命令启动终端。网络掉线或页面刷新只会注销 tmux 客户端，后台运行的会话不受影响。新连接接入后会自动 Attach 回已有的 `main` 会话，保持原有的工作目录、变量与正在运行的进程。
- **终端环境配置**：`/root/.tmux.conf` 启用了鼠标模式（`mouse on`），设置 50,000 行历史缓冲区（`history-limit 50000`），开启最新客户端窗口大小自适应（`window-size latest`），并将按键延迟设为零（`escape-time 0`）。
- **容器平滑停机**：容器接收到停机信号时，退出函数先调用 `tmux kill-server` 关闭终端会话树，使前后台程序在底层收到强制终结信号前完成数据刷盘。

### 3. 解耦扩展模块
- **EasyTier 用户态网格（smoltcp）**：当设置 `ENABLE_EASYTIER=true` 或指定了 `ET_NAME` 时，`easytier-core` 自动加载并以 `--no-tun --use-smoltcp` 运行，无需内核 `CAP_NET_ADMIN` 特权即可在用户空间接管虚拟 IP 路由。
- **sing-box 代理服务**：当设置 `ENABLE_SINGBOX=true` 或指定了 `SINGBOX_UUID` 时，系统自动生成配置并在 `127.0.0.1:20808`（WebSocket 入站）与 `0.0.0.0:10808`（本地混合代理）监听。
- **多租户容器磁盘指标对齐**：在 Kubernetes 共享集群上，无特权容器执行 `statvfs("/")` 会返回底层物理盘容量（通常已用 300+ GB）。当配置 `KOMARI_TOKEN` 唤醒探针时，`komari-agent` 将磁盘总容量锁定为预设虚拟配额（`AGENT_FORCE_DISK_TOTAL`，默认 5 GiB），并自动跳过 `/proc`、`/sys`、`/dev`、`/run` 伪文件系统计算根目录真实体积。

### 4. 进程看门狗与熔断机制
`/entrypoint.sh` 作为 PID 1 运行，执行间隔为 5 秒的存活检测循环。看门狗直接维护各服务的独立进程标识（`PID_CADDY`、`PID_SSHD`、`PID_TTYD`、`PID_ET`、`PID_SINGBOX`、`PID_KOMARI`），未激活的扩展模块不进入检测循环。当单一核心服务连续异常重启达到 5 次时，触发熔断终止容器，防止死循环耗尽资源。

---

## 环境变量配置

### 核心参数（零配置可用）

| 变量名 | 默认值 / 机制 | 功能说明 |
| :--- | :--- | :--- |
| `PORT` | `10000` | 平台分配的容器公网端口 |
| `SSH_PASS` | *(自动生成18位密码)* | OpenSSH root 用户登录密码；若未填则随机生成并在启动日志输出 |
| `TTYD_USER` | `admin` | `/shell/` 终端 Basic 认证用户名 |
| `TTYD_PASS` | 同 `SSH_PASS` | `/shell/` 终端 Basic 认证密码 |
| `SSH_PUBKEY` | *(可选)* | 写入 `/root/.ssh/authorized_keys` 的 OpenSSH 公钥 |

### 可选扩展参数

| 变量名 | 默认值 / 机制 | 功能说明 |
| :--- | :--- | :--- |
| `ENABLE_EASYTIER` | `false` | 显式启用 EasyTier 组网模块（`true` / `false`） |
| `ET_NAME` | `render-mesh` | EasyTier 虚拟网名称（配置此项自动激活组网） |
| `ET_SECRET` | `render-mesh-secret` | EasyTier 虚拟网通信密钥 |
| `ET_IP` | `10.144.144.90` | 容器在虚拟网内的静态 IPv4 地址 |
| `ET_HOSTNAME` | `render-box` | 在虚拟网对等列表中的主机名 |
| `ET_PEERS` | *(可选)* | 外部 EasyTier 对等节点地址列表，以逗号分隔（如 `tcp://your-vps.com:11010`） |
| `ENABLE_SINGBOX` | `false` | 显式启用 sing-box 代理模块（`true` / `false`） |
| `SINGBOX_UUID` | `1da2cc31-2c34-4b0b-b83c-ce3f7b8e6c2c` | sing-box VLESS 鉴权标识（配置此项自动激活代理） |
| `KOMARI_TOKEN` | *(可选)* | MangoHub 节点认证凭据 |
| `KOMARI_ENDPOINT` | *(可选)* | MangoHub 监控面板地址（如 `https://your-dashboard.com`，配置 Token 时必填） |
| `KOMARI_FORCE_DISK_TOTAL` | `5368709120` | 磁盘虚拟配额字节数（5 GiB） |
| `ENABLE_KEEPALIVE` | `true` | 启用自主内置 Inbound HTTP 保活巡检，防止 Render 15 分钟闲置休眠 |
| `KEEPALIVE_INTERVAL` | `300` | 保活拨测频率秒数（默认 300 秒 / 5 分钟） |
| `KEEPALIVE_URL` | *(自动)* | 目标健康探测地址（默认自动从 Render 环境变量解析自身公网域名） |

---

## 部署流程

### 方式一：一键快速部署（推荐）
点击下方按钮直接进入 Render Blueprint 进行一键配置：

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/dengyie/render-engine)

### 方式二：手动配置部署
1. 把本仓库 Fork 或推送至 GitHub 个人仓库。
2. 登录 [Render Dashboard](https://dashboard.render.com/)，新建一个 **Web Service**。
3. 关联该仓库并设定参数：
   - **Environment**：`Docker`
   - **Instance Type**：`Free`
   - **Health Check Path**：`/health`
4. 环境变量可留空（享受零配置体验），或按需填入扩展参数。
5. 点击部署，查看控制台部署日志即可获取终端访问地址与初始密码。

---

## 客户端使用指南

### 1. Web 终端直接访问
无需在本地安装任何客户端工具，直接通过浏览器管理容器：
1. 打开 `https://your-service.onrender.com/shell/`。
2. 输入 `TTYD_USER` 与 `TTYD_PASS` 设定的认证凭据（或从部署日志中复制）。
3. 终端自动挂载持久化 `tmux` 会话。输入 `exit` 可销毁当前会话并在下次刷新时重置干净环境。

### 2. 实例防休眠与 24/7 持续运行
Render 免费层在连续 15 分钟无外部入站 HTTP 请求后会自动销毁 Pod 并在访问时冷启动。为了在 Render 充裕的每月 750 小时免费额度内（`31 天 × 24h = 744h`）实现全月 24/7 不间断运行且不丢失会话上下文：
- **内置自主保活引擎（默认开启）**：`render-engine` 内置了守护任务（`ENABLE_KEEPALIVE=true`），会自动读取平台分配的公网域名（`RENDER_EXTERNAL_URL`），每隔 5 分钟向自身 `/health` 发起真实的入站 HTTP 拨测，持续重置 Render 的闲置计时器，无需手动搭建外部定时任务。
- **外部监控兜底（可选）**：如遇到容器意外崩溃或需冷启动自愈，亦可在外部监控系统（如 Uptime Kuma、Cron-job.org 或自建 VPS Crontab）中添加 HTTP GET 拨测，以 5 至 10 分钟为周期请求 `https://your-service.onrender.com/health`。

### 3. EasyTier 虚拟网连接（按需启用时）
若启用了 EasyTier 组网模块，在客户端主机启动进程打通隧道：

```bash
sudo easytier-core \
  --network-name "render-mesh" \
  --network-secret "YourSecretKey" \
  --ipv4 "10.144.144.100" \
  --peers "wss://your-service.onrender.com/et"
```

查询网格连通状态：
```bash
easytier-cli peer
```

通过虚拟 IP 直接登录 SSH：
```bash
ssh root@10.144.144.90
```

### 4. 代理服务接入（按需启用时）
- **虚拟网内混合代理**：容器在 `0.0.0.0:10808` 监听 HTTP 与 SOCKS5 流量。网格内节点可把代理地址指向 `socks5://10.144.144.90:10808` 或 `http://10.144.144.90:10808`。
- **公网 VLESS 入站**：客户端通过 `wss://your-service.onrender.com/vless-ws` 接入，流量经 Caddy 解密后投递至 `127.0.0.1:20808`。

---

## 致谢

感谢 [LINUX DO](https://linux.do) 社区在技术实现与方案探讨中提供的启发与支持。

---

## 许可证

本项目依据 [MIT License](LICENSE) 条款开源发布。
