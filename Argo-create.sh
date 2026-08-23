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

# cloudflared 默认会与 Cloudflare 边缘建立 4 条高可用连接（--ha-connections 默认值为 4）。
#4个高可用连接会分配最少两个不同的数据中心
#4个（不含）以下连接数未知
HA_CONNECTIONS="4"

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

# 掩码显示敏感 Token，仅用于人工核对，不在日志/状态中暴露完整内容
mask_token() {
    local t="$1" len
    len=${#t}
    if [ "$len" -le 10 ]; then
        printf '******\n'
    else
        printf '%s...%s（长度 %d）\n' "${t:0:6}" "${t: -4}" "$len"
    fi
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
  bash argo-only.sh uninstall     # 完整卸载：停止服务、删除本工具安装的 cloudflared 及所有状态文件
  bash argo-only.sh cleanup       # 残留清理：仅清理孤立进程/旧缓存/其它同名服务单元，不卸载、不删本脚本

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
    while true; do
        printf '\n请选择 Argo 隧道类型：\n'
        printf '  1) 临时 Argo（trycloudflare.com，无需注册，重启后域名会变化）\n'
        printf '  2) 固定 Argo（Zero Trust Token，需要自己的域名，域名固定不变）\n'
        printf '请输入 [1-2]: '
        read -r choice
        case "$choice" in
            1) MODE="temp"; break ;;
            2) MODE="fixed"; break ;;
            *) warn "无效选择，请输入 1 或 2" ;;
        esac
    done
}

prompt_port() {
    local p
    while true; do
        printf 'Argo 回源 WS 端口（本机监听的端口，例如 10001）: '
        read -r p
        p="$(printf '%s' "$p" | tr -d '[:space:]')"
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
            ORIGIN_PORT="$p"
            break
        fi
        warn "端口无效，必须是 1-65535 之间的数字，请重新输入"
    done
}

prompt_domain() {
    local d
    while true; do
        printf '固定 Argo 域名（需已在 Cloudflare Zero Trust 中为该 Tunnel 配置好 Public Hostname，\n例如：argo.example.com）: '
        read -r d
        d="$(printf '%s' "$d" | tr -d '[:space:]')"
        if [ -z "$d" ]; then
            warn "域名不能为空，请重新输入"
            continue
        fi
        if [[ ! "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then
            warn "域名格式看起来不正确（应类似 argo.example.com），请重新输入"
            continue
        fi
        ARGO_DOMAIN="$d"
        break
    done
}

prompt_token() {
    local t confirm
    while true; do
        printf 'Cloudflare Tunnel Token（在 Zero Trust → Networks → Tunnels 创建隧道后获取，\n通常以 "ey" 开头）。为避免泄露，粘贴后按回车确认，输入内容不会显示: '
        read -rs t
        printf '\n'
        t="$(printf '%s' "$t" | tr -d '[:space:]')"
        if [ -z "$t" ]; then
            warn "Token 不能为空，请重新输入"
            continue
        fi
        if [[ "$t" != ey* ]]; then
            warn "Token 格式看起来不太对（通常以 \"ey\" 开头），请确认是否复制完整"
            printf '仍然使用该 Token？[y/N]: '
            read -r confirm
            case "$confirm" in
                y|Y) ;;
                *) continue ;;
            esac
        fi
        ARGO_TOKEN="$t"
        break
    done
    log "已获取 Token（掩码显示：$(mask_token "$ARGO_TOKEN")）"
}

collect_config() {
    select_mode_interactive

    case "$MODE" in
        temp|temporary)
            MODE="temp"
            [ -z "$ORIGIN_PORT" ] && prompt_port
            [[ "$ORIGIN_PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字"
            [ "$ORIGIN_PORT" -ge 1 ] && [ "$ORIGIN_PORT" -le 65535 ] || die "端口范围必须为 1-65535"
            ;;
        fixed|named)
            MODE="fixed"
            [ -z "$ARGO_DOMAIN" ] && prompt_domain
            [ -z "$ARGO_TOKEN" ] && prompt_token
            [ -n "$ARGO_DOMAIN" ] || die "固定 Argo 必须提供域名"
            [ -n "$ARGO_TOKEN" ] || die "固定 Argo 必须提供 Token"
            echo
            log "配置确认：域名=$ARGO_DOMAIN，Token=$(mask_token "$ARGO_TOKEN")"
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

    # 直接流式写盘（curl/wget -o 都不会把整个文件缓冲进内存），下载阶段本身
    # 没有可压缩的内存占用；真正影响常驻内存的是运行阶段的连接数，见 HA_CONNECTIONS。
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
            CMD=("$bin" tunnel --url "http://localhost:$ORIGIN_PORT" --edge-ip-version auto --no-autoupdate --protocol http2 --ha-connections "$HA_CONNECTIONS")
            ;;
        fixed)
            # Token 不再作为命令行参数传入，改由 TUNNEL_TOKEN 环境变量提供，
            # 避免在 `ps aux` 中明文暴露给系统上的其他用户（见 start_direct / install_systemd / install_openrc）。
            CMD=("$bin" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --ha-connections "$HA_CONNECTIONS" run)
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
    if [ "$MODE" = "fixed" ]; then
        TUNNEL_TOKEN="$ARGO_TOKEN" nohup "${CMD[@]}" >> "$LOG_FILE" 2>&1 &
    else
        nohup "${CMD[@]}" >> "$LOG_FILE" 2>&1 &
    fi
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
    # 启动命令保存在仅 root 可读的 run.sh 中。
    # - temp 模式：输出重定向进 $LOG_FILE，这样 show_info 才能从日志里抓到 trycloudflare.com 域名
    #   （旧版本这里没有重定向，systemd 下 stdout/stderr 只会进 journal，$LOG_FILE 永远是空的，
    #   导致临时域名一直显示"等待生成"，只能自己去翻进程/journalctl，这是本次修复的主要问题）。
    # - fixed 模式：Token 通过 TUNNEL_TOKEN 环境变量传入，不出现在 --token 命令行参数里，
    #   因此不会在 `ps aux`（对系统上所有用户可见）中明文暴露。
    if [ "$MODE" = "temp" ]; then
        cat > "$STATE_DIR/run.sh" <<EOF_RUN
#!/bin/bash
exec ${bin@Q} tunnel --url ${ORIGIN_URL@Q} --edge-ip-version auto --no-autoupdate --protocol http2 --ha-connections ${HA_CONNECTIONS@Q} >> ${LOG_FILE@Q} 2>&1
EOF_RUN
    else
        cat > "$STATE_DIR/run.sh" <<EOF_RUN
#!/bin/bash
export TUNNEL_TOKEN=${ARGO_TOKEN@Q}
exec ${bin@Q} tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --ha-connections ${HA_CONNECTIONS@Q} run >> ${LOG_FILE@Q} 2>&1
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
    # run.sh 内也显式重定向到 $LOG_FILE（与 OpenRC 的 output_log/error_log 指向同一文件，
    # 不会重复写入），确保无论 OpenRC 版本是否正确接管了子进程输出，日志都能稳定写入，
    # 从而让 show_info 能抓到临时域名。fixed 模式同样改用 TUNNEL_TOKEN 环境变量传参。
    cat > "$STATE_DIR/run.sh" <<EOF_RUN
#!/bin/bash
if [ "$MODE" = "fixed" ]; then
  export TUNNEL_TOKEN=${ARGO_TOKEN@Q}
  exec ${bin@Q} tunnel --no-autoupdate --edge-ip-version auto --protocol http2 --ha-connections ${HA_CONNECTIONS@Q} run >> ${LOG_FILE@Q} 2>&1
else
  exec ${bin@Q} tunnel --url ${origin_url@Q} --edge-ip-version auto --no-autoupdate --protocol http2 --ha-connections ${HA_CONNECTIONS@Q} >> ${LOG_FILE@Q} 2>&1
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

# 临时隧道启动后轮询日志，直到抓到 trycloudflare.com 域名再打印出来，
# 不再需要用户自己去翻进程/journalctl 查找。最多等待 20 秒。
wait_for_temp_domain() {
    [ "$MODE" = "temp" ] || return 0
    printf '[Argo] 等待 Cloudflare 分配临时域名'
    local i domain
    for i in $(seq 1 20); do
        domain="$(grep -Eo '[A-Za-z0-9.-]+\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | tail -n1 || true)"
        if [ -n "$domain" ]; then
            printf '\n'
            log "临时域名已生成：https://$domain"
            return 0
        fi
        printf '.'
        sleep 1
    done
    printf '\n'
    warn "等待超时（20秒），日志中暂未检测到临时域名。"
    warn "可稍后执行 'bash $(basename "$0") show' 重新查看，或检查日志：$LOG_FILE"
    warn "如果确认之前运行过旧版本脚本，也可以执行 'bash $(basename "$0") cleanup' 清理残留进程后重试。"
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
        if [ -n "${ARGO_TOKEN:-}" ]; then
            echo "Token     : 已设置（$(mask_token "$ARGO_TOKEN")）"
        else
            echo "Token     : 未设置"
        fi
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
        if [ -n "${ARGO_TOKEN:-}" ]; then
            echo "Token     : 已设置（$(mask_token "$ARGO_TOKEN")）"
        else
            echo "Token     : 未设置"
        fi
        echo
        echo "注意：固定 Tunnel 的公网 Hostname → 本机 WS 端口，需要在"
        echo "Cloudflare Zero Trust → Networks → Tunnels → Routes 中配置。"
    elif [ "$MODE" = "temp" ]; then
        echo "回源地址  : http://localhost:${ORIGIN_PORT:-}"
        local domain
        domain="$(grep -Eo '[A-Za-z0-9.-]+\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | tail -n1 || true)"
        echo "临时域名  : ${domain:-等待 cloudflared 日志生成，可稍后重新执行 show 查看}"
    fi
    echo "日志      : $LOG_FILE"
}

install_all() {
    collect_config
    ensure_state_dir
    install_cloudflared
    save_config
    install_backend
    if [ "$MODE" = "temp" ]; then
        wait_for_temp_domain
    else
        sleep 3
    fi
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

# 残留清理：仅清理"不受当前配置管理"的孤立进程、旧缓存目录、以及可能由旧版本
# 脚本留下的其它同名/相似 systemd 单元。不会：
#   - 删除本脚本文件本身
#   - 删除当前正常安装的 cloudflared 可执行文件
#   - 停止当前正在正常运行、受本脚本管理的服务
# 每一步删除/终止操作都会先列出内容并询问确认，避免误伤系统上其它无关的 cloudflared 用途。
cleanup_residue() {
    load_config
    log "开始清理 Argo 残留进程与缓存（不会删除本脚本，也不会影响当前正常运行的 Argo 服务）"
    echo

    local active_pid=""
    [ -f "$PID_FILE" ] && active_pid="$(cat "$PID_FILE" 2>/dev/null || true)"

    # 1) 扫描残留 cloudflared 进程（排除当前受管 PID），逐个确认后终止
    log "第 1 步：扫描残留的 cloudflared 进程..."
    if command -v pgrep >/dev/null 2>&1; then
        local pids pid cmd found=0 ans
        # 用 -x 按精确进程名匹配（而不是 -f 匹配整条命令行），避免误伤命令行里
        # 恰好包含 "cloudflared"/"tunnel" 字样的无关进程（例如某个正在编辑本脚本的编辑器）
        pids="$(pgrep -x cloudflared 2>/dev/null || true)"
        for pid in $pids; do
            [ -n "$active_pid" ] && [ "$pid" = "$active_pid" ] && continue
            cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
            [ -z "$cmd" ] && continue
            found=1
            printf '发现进程 PID=%s：%s\n' "$pid" "$cmd"
            printf '是否终止该进程？[y/N]: '
            read -r ans
            case "$ans" in
                y|Y)
                    kill -TERM "$pid" 2>/dev/null || true
                    sleep 1
                    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
                    log "已终止 PID=$pid"
                    ;;
                *) log "跳过 PID=$pid" ;;
            esac
        done
        [ "$found" = "0" ] && log "未发现残留 cloudflared 进程"
    else
        warn "系统缺少 pgrep 命令，跳过残留进程扫描"
    fi
    echo

    # 2) 清理失效 PID 文件
    log "第 2 步：清理失效 PID 文件..."
    if [ -f "$PID_FILE" ] && ! is_running; then
        rm -f "$PID_FILE"
        log "已清理失效 PID 文件"
    else
        log "无需清理"
    fi
    echo

    # 3) 可选清空日志文件
    log "第 3 步：日志文件..."
    if [ -f "$LOG_FILE" ]; then
        printf '是否清空日志文件 %s？[y/N]: ' "$LOG_FILE"
        read -r ans
        case "$ans" in
            y|Y) : > "$LOG_FILE"; log "日志已清空" ;;
            *) log "保留日志文件" ;;
        esac
    else
        log "日志文件不存在，跳过"
    fi
    echo

    # 4) 扫描历史 cloudflared 缓存目录（可能由手动操作或旧脚本产生的 cert.pem 等）
    log "第 4 步：扫描历史 cloudflared 缓存目录..."
    local cache_dirs=("$HOME/.cloudflared" "/etc/cloudflared" "/root/.cloudflared")
    local d ans
    for d in "${cache_dirs[@]}"; do
        [ -d "$d" ] || continue
        printf '发现缓存目录：%s（内容：%s）\n' "$d" "$(ls -A "$d" 2>/dev/null | tr '\n' ' ')"
        printf '是否删除该目录？[y/N]: '
        read -r ans
        case "$ans" in
            y|Y) rm -rf "$d"; log "已删除 $d" ;;
            *) log "保留 $d" ;;
        esac
    done
    echo

    # 5) 扫描名称包含 argo/cloudflared 的其它 systemd 单元（排除当前受管单元）
    if is_root && command -v systemctl >/dev/null 2>&1; then
        log "第 5 步：扫描其它可能相关的 systemd 单元..."
        local units u unit_path ans
        units="$(systemctl list-unit-files 2>/dev/null | grep -iE 'argo|cloudflared' | awk '{print $1}' || true)"
        if [ -n "$units" ]; then
            for u in $units; do
                [ "$u" = "${SERVICE_NAME}.service" ] && continue
                printf '发现单元：%s\n' "$u"
                printf '是否停用并删除该单元？[y/N]: '
                read -r ans
                case "$ans" in
                    y|Y)
                        systemctl disable --now "$u" >/dev/null 2>&1 || true
                        unit_path="$(systemctl show -p FragmentPath --value "$u" 2>/dev/null || true)"
                        [ -n "$unit_path" ] && [ -f "$unit_path" ] && rm -f "$unit_path"
                        log "已移除 $u"
                        ;;
                    *) log "保留 $u" ;;
                esac
            done
            systemctl daemon-reload >/dev/null 2>&1 || true
        else
            log "未发现其它相关单元"
        fi
        echo
    fi

    log "残留清理完成。cloudflared 主程序、当前受管服务与本脚本均未被删除。"
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
        cleanup|clean)
            cleanup_residue ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
