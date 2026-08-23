#!/bin/bash
set -u

# Argo-only installer based on the Cloudflared/Argo portion of yonggekkk/argosbx.sh.
# This script does NOT install or configure Xray, sing-box, WARP, subscriptions,
# iptables rules, certificates, or any proxy protocol.

set -o pipefail

NAME="argo-only"
DEFAULT_STATE_DIR="${HOME}/.argo-only"
STATE_DIR="${ARGO_STATE_DIR:-$DEFAULT_STATE_DIR}"
PID_FILE="$STATE_DIR/cloudflared.pid"
LOG_FILE="$STATE_DIR/cloudflared.log"
CONF_FILE="$STATE_DIR/config"
BIN_NAME="cloudflared"
SERVICE_NAME="argo-only"

MODE="${ARGO_MODE:-}"
ORIGIN_PORT="${ARGO_PORT:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_TOKEN="${ARGO_TOKEN:-}"

log() { printf '[Argo] %s\n' "$*"; }
warn() { printf '[Argo][WARN] %s\n' "$*" >&2; }
die() { printf '[Argo][ERROR] %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

bin_path() {
    if [ -n "${ARGO_BIN:-}" ]; then
        printf '%s\n' "$ARGO_BIN"
    elif is_root; then
        printf '%s\n' "/usr/local/bin/$BIN_NAME"
    else
        printf '%s\n' "$HOME/.local/bin/$BIN_NAME"
    fi
}

cloudflared_bin() { bin_path; }

ensure_state_dir() {
    mkdir -p "$STATE_DIR" || die "无法创建状态目录：$STATE_DIR"
}

save_config() {
    ensure_state_dir
    umask 077
    cat > "$CONF_FILE" <<CFG
MODE=$MODE
ORIGIN_PORT=$ORIGIN_PORT
ARGO_DOMAIN=$ARGO_DOMAIN
ARGO_TOKEN=$ARGO_TOKEN
CFG
    chmod 600 "$CONF_FILE" 2>/dev/null || true
}

load_config() {
    [ -f "$CONF_FILE" ] || return 0
    # shellcheck disable=SC1090
    . "$CONF_FILE"
}

parse_args() {
    ACTION="${1:-install}"
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode)
                [ $# -ge 2 ] || die "--mode 需要参数"
                MODE="$2"; shift 2 ;;
            --port)
                [ $# -ge 2 ] || die "--port 需要参数"
                ORIGIN_PORT="$2"; shift 2 ;;
            --domain)
                [ $# -ge 2 ] || die "--domain 需要参数"
                ARGO_DOMAIN="$2"; shift 2 ;;
            --token)
                [ $# -ge 2 ] || die "--token 需要参数"
                ARGO_TOKEN="$2"; shift 2 ;;
            --state-dir)
                [ $# -ge 2 ] || die "--state-dir 需要参数"
                STATE_DIR="$2"
                PID_FILE="$STATE_DIR/cloudflared.pid"
                LOG_FILE="$STATE_DIR/cloudflared.log"
                CONF_FILE="$STATE_DIR/config"
                shift 2 ;;
            --bin)
                [ $# -ge 2 ] || die "--bin 需要参数"
                export ARGO_BIN="$2"; shift 2 ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done
}

usage() {
    cat <<'HELP'
Argo-only：独立 Cloudflare Tunnel 安装/管理脚本

临时 Argo（Quick Tunnel，随机 trycloudflare.com 域名）：
  bash argo-only.sh install --mode temp --port 10001

固定 Argo（Cloudflare Zero Trust Tunnel）：
  bash argo-only.sh install --mode fixed \
    --domain argo.example.com \
    --token 'eyJ...'

管理：
  bash argo-only.sh start
  bash argo-only.sh stop
  bash argo-only.sh restart
  bash argo-only.sh status
  bash argo-only.sh show
  bash argo-only.sh uninstall

环境变量方式：
  ARGO_MODE=temp ARGO_PORT=10001 bash argo-only.sh install
  ARGO_MODE=fixed ARGO_DOMAIN=argo.example.com ARGO_TOKEN='eyJ...' bash argo-only.sh install

说明：
  fixed 模式使用 Cloudflare Tunnel Token 启动隧道；公网域名到本机端口的
  Published Application / Ingress 路由仍由 Cloudflare Zero Trust 控制台配置。
  这正是原 argosbx.sh 的固定 Argo 工作方式：cloudflared 只执行 tunnel run --token。
HELP
}

select_mode_interactive() {
    [ -n "$MODE" ] && return 0
    printf '\n1) 临时 Argo（trycloudflare.com）\n2) 固定 Argo（Zero Trust Token）\n选择 [1-2]: '
    read -r choice
    case "$choice" in
        1) MODE="temp" ;;
        2) MODE="fixed" ;;
        *) die "无效选择" ;;
    esac
}

collect_config() {
    select_mode_interactive

    case "$MODE" in
        temp|temporary)
            MODE="temp"
            if [ -z "$ORIGIN_PORT" ]; then
                printf 'Argo 回源 WS 端口: '
                read -r ORIGIN_PORT
            fi
            [[ "$ORIGIN_PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字"
            [ "$ORIGIN_PORT" -ge 1 ] && [ "$ORIGIN_PORT" -le 65535 ] || die "端口范围必须为 1-65535"
            ;;
        fixed|named)
            MODE="fixed"
            if [ -z "$ARGO_DOMAIN" ]; then
                printf '固定 Argo 域名（例如 argo.example.com）: '
                read -r ARGO_DOMAIN
            fi
            if [ -z "$ARGO_TOKEN" ]; then
                printf 'Cloudflare Tunnel Token（ey...）: '
                read -r ARGO_TOKEN
            fi
            [ -n "$ARGO_DOMAIN" ] || die "固定 Argo 必须提供域名"
            [ -n "$ARGO_TOKEN" ] || die "固定 Argo 必须提供 Token"
            ;;
        *)
            die "--mode 只能是 temp 或 fixed"
            ;;
    esac
}

install_cloudflared() {
    local bin url arch tmp
    bin="$(cloudflared_bin)"
    if [ -x "$bin" ]; then
        log "检测到 cloudflared：$($bin --version 2>/dev/null | head -n1 || true)"
        return 0
    fi

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) die "不支持的 CPU 架构：$(uname -m)。原脚本仅处理 amd64/arm64。" ;;
    esac

    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch"
    tmp="${bin}.tmp.$$"
    log "下载 cloudflared：$url"
    mkdir -p "$(dirname "$bin")" || die "无法创建安装目录：$(dirname "$bin")"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 10 -o "$tmp" "$url" || die "cloudflared 下载失败"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 -O "$tmp" "$url" || die "cloudflared 下载失败"
    else
        die "需要 curl 或 wget"
    fi

    chmod +x "$tmp" || die "无法给 cloudflared 加执行权限"
    "$tmp" --version >/dev/null 2>&1 || { rm -f "$tmp"; die "下载的 cloudflared 无法执行"; }
    mv -f "$tmp" "$bin" || die "无法安装 cloudflared 到：$bin"
    chmod +x "$bin"
    log "cloudflared 安装完成：$($bin --version 2>/dev/null | head -n1)"
}

build_command() {
    local bin
    bin="$(cloudflared_bin)"
    case "$MODE" in
        temp)
            CMD=("$bin" tunnel --url "http://localhost:$ORIGIN_PORT" --edge-ip-version auto --no-autoupdate --protocol http2)
            ;;
        fixed)
            CMD=("$bin" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token "$ARGO_TOKEN")
            ;;
        *) die "未设置有效的 MODE" ;;
    esac
}

is_running() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    return 0
}

cleanup_stale_pid() {
    if [ -f "$PID_FILE" ] && ! is_running; then
        rm -f "$PID_FILE"
    fi
}

start_direct() {
    ensure_state_dir
    cleanup_stale_pid
    if is_running; then
        log "Argo 已在运行，PID=$(cat "$PID_FILE")"
        return 0
    fi

    build_command
    log "启动 Cloudflared Argo..."
    nohup "${CMD[@]}" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 2

    if ! kill -0 "$pid" 2>/dev/null; then
        warn "cloudflared 启动失败，最后日志："
        tail -n 30 "$LOG_FILE" 2>/dev/null || true
        rm -f "$PID_FILE"
        return 1
    fi

    log "Argo 已启动，PID=$pid"
}

stop_direct() {
    local pid
    if [ ! -f "$PID_FILE" ]; then
        log "没有找到 Argo PID 文件"
        return 0
    fi
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            sleep 1
            kill -0 "$pid" 2>/dev/null || break
        done
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    log "Argo 已停止"
}

service_backend() {
    if is_root && command -v systemctl >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
        echo systemd
    elif is_root && command -v rc-service >/dev/null 2>&1; then
        echo openrc
    else
        echo direct
    fi
}

install_systemd() {
    local bin
    bin="$(cloudflared_bin)"
    ORIGIN_URL="http://localhost:$ORIGIN_PORT"
    export ORIGIN_URL
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF_SERVICE
[Unit]
Description=Cloudflare Argo Tunnel (Argo-only)
After=network.target
Wants=network.target

[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=/bin/bash ${STATE_DIR}/run.sh
Restart=on-failure
RestartSec=5s
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    chmod 600 "/etc/systemd/system/${SERVICE_NAME}.service"
    # Store the exact launch command in a root-readable script. Token is never exposed in ps args by this wrapper.
    if [ "$MODE" = "temp" ]; then
        cat > "$STATE_DIR/run.sh" <<EOF_RUN
#!/bin/bash
exec ${bin@Q} tunnel --url ${ORIGIN_URL@Q} --edge-ip-version auto --no-autoupdate --protocol http2
EOF_RUN
    else
        cat > "$STATE_DIR/run.sh" <<EOF_RUN
#!/bin/bash
exec ${bin@Q} tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token ${ARGO_TOKEN@Q}
EOF_RUN
    fi
    chmod 700 "$STATE_DIR/run.sh"
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
}

install_openrc() {
    local bin
    bin="$(cloudflared_bin)"
    local origin_url="http://localhost:$ORIGIN_PORT"
    cat > "/etc/init.d/${SERVICE_NAME}" <<EOF_RC
#!/sbin/openrc-run
description="Cloudflare Argo Tunnel (Argo-only)"
command="${bin}"
command_args=""
command_background="yes"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

depend() {
    need net
}

start_pre() {
    rm -f "${PID_FILE}"
}
EOF_RC
    cat > "$STATE_DIR/run.sh" <<EOF_RUN
#!/bin/bash
if [ "$MODE" = "fixed" ]; then
  exec ${bin@Q} tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token ${ARGO_TOKEN@Q}
else
  exec ${bin@Q} tunnel --url ${origin_url@Q} --edge-ip-version auto --no-autoupdate --protocol http2
fi
EOF_RUN
    chmod 700 "$STATE_DIR/run.sh"
    sed -i "s|^command=.*|command=\"/bin/bash\"|" "/etc/init.d/${SERVICE_NAME}"
    sed -i "s|^command_args=.*|command_args=\"$STATE_DIR/run.sh\"|" "/etc/init.d/${SERVICE_NAME}"
    chmod +x "/etc/init.d/${SERVICE_NAME}"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || rc-service "$SERVICE_NAME" start
}

install_backend() {
    case "$(service_backend)" in
        systemd) install_systemd ;;
        openrc) install_openrc ;;
        direct) start_direct ;;
    esac
}

stop_backend() {
    case "$(service_backend)" in
        systemd) systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true ;;
        openrc) rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true ;;
        direct) stop_direct ;;
    esac
}

start_backend() {
    case "$(service_backend)" in
        systemd) systemctl start "$SERVICE_NAME" ;;
        openrc) rc-service "$SERVICE_NAME" start ;;
        direct) start_direct ;;
    esac
}

restart_backend() {
    case "$(service_backend)" in
        systemd) systemctl restart "$SERVICE_NAME" ;;
        openrc) rc-service "$SERVICE_NAME" restart ;;
        direct) stop_direct; start_direct ;;
    esac
}

status_backend() {
    local bin
    bin="$(cloudflared_bin)"
    echo "=================================================="
    echo "Argo-only 状态"
    echo "=================================================="
    echo "模式      : ${MODE:-未配置}"
    echo "状态目录  : $STATE_DIR"
    echo "cloudflared: $bin"
    if [ -x "$bin" ]; then
        echo "版本      : $($bin --version 2>/dev/null | head -n1 || true)"
    else
        echo "版本      : 未安装"
    fi
    if [ "$MODE" = "fixed" ]; then
        echo "固定域名  : ${ARGO_DOMAIN:-未设置}"
        echo "Token     : ${ARGO_TOKEN:+已设置}"
    elif [ "$MODE" = "temp" ]; then
        echo "回源端口  : ${ORIGIN_PORT:-未设置}"
    fi
    echo

    case "$(service_backend)" in
        systemd)
            systemctl --no-pager --full status "$SERVICE_NAME" 2>/dev/null || true
            ;;
        openrc)
            rc-service "$SERVICE_NAME" status 2>/dev/null || true
            ;;
        direct)
            if is_running; then
                echo "进程状态  : 运行中（PID=$(cat "$PID_FILE")）"
            else
                echo "进程状态  : 未运行"
            fi
            ;;
    esac
}

show_info() {
    load_config
    echo "=================================================="
    echo "Argo-only 配置"
    echo "=================================================="
    echo "模式      : ${MODE:-未配置}"
    if [ "$MODE" = "fixed" ]; then
        echo "固定域名  : ${ARGO_DOMAIN:-未设置}"
        echo "Token     : ${ARGO_TOKEN:+已设置}"
        echo
        echo "注意：固定 Tunnel 的公网 Hostname → 本机 WS 端口，需要在"
        echo "Cloudflare Zero Trust → Networks → Tunnels → Routes 中配置。"
    elif [ "$MODE" = "temp" ]; then
        echo "回源地址  : http://localhost:${ORIGIN_PORT:-}"
        local domain
        domain="$(grep -Eo '[A-Za-z0-9.-]+\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | tail -n1 || true)"
        echo "临时域名  : ${domain:-等待 cloudflared 日志生成}"
    fi
    echo "日志      : $LOG_FILE"
}

install_all() {
    collect_config
    ensure_state_dir
    install_cloudflared
    save_config
    install_backend
    sleep 3
    status_backend
    show_info
}

uninstall_all() {
    load_config
    stop_backend
    if is_root && command -v systemctl >/dev/null 2>&1; then
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if is_root && [ -e "/etc/init.d/${SERVICE_NAME}" ]; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/${SERVICE_NAME}"
    fi
    rm -rf "$STATE_DIR"
    local bin
    bin="$(cloudflared_bin)"
    if [[ "$bin" == /usr/local/bin/cloudflared || "$bin" == "$HOME/.local/bin/cloudflared" ]]; then
        rm -f "$bin"
    fi
    log "Argo-only 已卸载"
}

main() {
    parse_args "$@"
    case "$ACTION" in
        install)
            install_all ;;
        start|stop|restart|status|show)
            load_config
            case "$ACTION" in
                start) start_backend ;;
                stop) stop_backend ;;
                restart) restart_backend ;;
                status) status_backend ;;
                show) show_info ;;
            esac
            ;;
        uninstall|del)
            uninstall_all ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
