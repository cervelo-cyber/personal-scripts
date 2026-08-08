#!/usr/bin/env bash
#
# install-podman.sh
#
# 在 Debian 11 / 12+、Ubuntu 20.04+ 等官方仓库 podman 版本过旧（或没有）的系统上，
# 通过第三方静态编译源 mgoltzsche/podman-static 安装 podman >= 5.4.1。
#
# 为什么不用 openSUSE Kubic (devel:kubic:libcontainers) 源：
#   该源已停止维护多年，stable 分支停在 podman 3.x/4.5，unstable 分支也长期卡在
#   4.6~4.9，无法满足 podman >= 5.4.1 的要求，官方仓库页面也已建议弃用。
#
# 本脚本改用 https://github.com/mgoltzsche/podman-static 提供的静态二进制包
# （podman + crun/runc + conmon + netavark + fuse-overlayfs + passt/pasta +
# aardvark-dns + catatonit），不依赖发行版打包版本，持续跟进上游最新 release。
#
# 用法:
#   sudo bash install-podman.sh                  # 安装最新版（默认 >= 5.4.1 要求）
#   sudo bash install-podman.sh -v v5.4.1         # 安装指定版本
#   sudo bash install-podman.sh -u someuser       # 为指定用户配置 subuid/subgid
#   sudo bash install-podman.sh --no-gpg-verify   # 跳过 GPG 签名校验
#   sudo bash install-podman.sh --remove-apt-podman  # 顺带卸载发行版仓库里的旧 podman
#   sudo bash install-podman.sh --force           # 忽略版本检查/已安装检测强制重装
#
set -euo pipefail

# ---------- 默认参数 ----------
PODMAN_VERSION="latest"          # "latest" 或形如 v5.4.1 的具体版本
TARGET_USER="${SUDO_USER:-${USER:-root}}"
DO_GPG_VERIFY=1
REMOVE_APT_PODMAN=0
FORCE=0
MIN_VERSION="5.4.1"
GPG_KEY_ID="0CCF102C4F95D89E583FF1D4F8B5AF50344BB503"
GITHUB_REPO="mgoltzsche/podman-static"
WORKDIR="$(mktemp -d /tmp/podman-static.XXXXXX)"

# ---------- 日志辅助 ----------
info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ---------- 参数解析 ----------
usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)
            PODMAN_VERSION="$2"; shift 2 ;;
        -u|--user)
            TARGET_USER="$2"; shift 2 ;;
        --no-gpg-verify)
            DO_GPG_VERIFY=0; shift ;;
        --remove-apt-podman)
            REMOVE_APT_PODMAN=1; shift ;;
        --force)
            FORCE=1; shift ;;
        -h|--help)
            usage ;;
        *)
            error "未知参数: $1"; usage ;;
    esac
done

# ---------- 基础检查 ----------
if [[ $EUID -ne 0 ]]; then
    error "请使用 root 权限运行本脚本（例如 sudo bash $0）"
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    error "未检测到 apt-get，本脚本仅适用于 Debian/Ubuntu 系发行版"
    exit 1
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "检测到系统: ${PRETTY_NAME:-$ID $VERSION_ID}"
else
    warn "无法读取 /etc/os-release，继续按通用 Debian/Ubuntu 处理"
fi

# ---------- 架构探测 ----------
case "$(uname -m)" in
    x86_64|amd64)   ARCH="amd64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    *)
        error "不支持的架构: $(uname -m)（podman-static 仅提供 amd64/arm64 静态包）"
        exit 1
        ;;
esac
info "目标架构: $ARCH"

# ---------- 版本比较函数 (返回0表示 v1 >= v2) ----------
version_ge() {
    [[ "$1" == "$2" ]] && return 0
    local higher
    higher="$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)"
    [[ "$higher" == "$1" ]]
}

# ---------- 已安装检测 ----------
if command -v podman >/dev/null 2>&1 && [[ $FORCE -eq 0 ]]; then
    CUR_VER="$(podman --version 2>/dev/null | awk '{print $3}')"
    if [[ -n "${CUR_VER:-}" ]] && version_ge "$CUR_VER" "$MIN_VERSION"; then
        info "已检测到 podman $CUR_VER（满足 >= $MIN_VERSION 要求），跳过安装。"
        info "如需强制重新安装，请加 --force 参数。"
        exit 0
    else
        warn "检测到已安装 podman ${CUR_VER:-未知版本}，版本过旧，将继续安装/覆盖。"
    fi
fi

# ---------- 可选：移除发行版仓库里的旧 podman，避免 /usr/bin 与 /usr/local/bin 混淆 ----------
if [[ $REMOVE_APT_PODMAN -eq 1 ]]; then
    if dpkg -s podman >/dev/null 2>&1; then
        info "移除发行版仓库安装的旧 podman 包..."
        apt-get remove -y podman podman-plugins podman-machine-cni >/dev/null 2>&1 || true
    fi
fi

# ---------- 安装依赖 ----------
info "安装依赖 (curl gnupg iptables uidmap ca-certificates util-linux)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    curl gnupg2 ca-certificates iptables uidmap util-linux

# ---------- 下载 podman-static ----------
cd "$WORKDIR"
TARBALL="podman-linux-${ARCH}.tar.gz"

if [[ "$PODMAN_VERSION" == "latest" ]]; then
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/${TARBALL}"
else
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${PODMAN_VERSION}/${TARBALL}"
fi

info "下载: $DOWNLOAD_URL"
curl -fsSL -o "$TARBALL" "$DOWNLOAD_URL"

# ---------- GPG 签名校验（可选，默认开启） ----------
if [[ $DO_GPG_VERIFY -eq 1 ]]; then
    info "校验发布包 GPG 签名..."
    if curl -fsSL -o "${TARBALL}.asc" "${DOWNLOAD_URL}.asc" 2>/dev/null; then
        if ! command -v gpg >/dev/null 2>&1; then
            apt-get install -y --no-install-recommends gnupg >/dev/null
        fi
        export GNUPGHOME="$WORKDIR/.gnupg"
        mkdir -m 700 -p "$GNUPGHOME"
        if gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$GPG_KEY_ID" 2>/dev/null; then
            if gpg --batch --verify "${TARBALL}.asc" "$TARBALL"; then
                info "GPG 签名校验通过。"
            else
                error "GPG 签名校验失败，为安全起见中止安装。可加 --no-gpg-verify 跳过校验（不推荐）。"
                exit 1
            fi
        else
            warn "无法从 keyserver 获取签名公钥（网络问题常见），跳过签名校验，继续安装。"
        fi
    else
        warn "未找到该版本的 .asc 签名文件，跳过签名校验。"
    fi
else
    warn "已跳过 GPG 签名校验（--no-gpg-verify）。"
fi

# ---------- 解压安装 ----------
info "解压并安装二进制文件到 /usr/local ..."
tar -xzf "$TARBALL"
EXTRACT_DIR="podman-linux-${ARCH}"
if [[ ! -d "$EXTRACT_DIR" ]]; then
    EXTRACT_DIR="$(find . -maxdepth 1 -type d -name 'podman-linux-*' | head -n1)"
fi
cp -a "${EXTRACT_DIR}/usr" "${EXTRACT_DIR}/etc" /

# 确保新装的 /usr/local/bin 在 root 与普通用户的 PATH 中排在系统 podman 之前
hash -r 2>/dev/null || true

# ---------- 版本核验 ----------
INSTALLED_VER="$(/usr/local/bin/podman --version | awk '{print $3}')"
info "已安装 podman 版本: $INSTALLED_VER"
if ! version_ge "$INSTALLED_VER" "$MIN_VERSION"; then
    error "安装完成，但版本 $INSTALLED_VER 低于要求的 $MIN_VERSION，请检查 -v 参数指定的版本。"
    exit 1
fi

# ---------- subuid/subgid（rootless 多 UID/GID 映射） ----------
if id "$TARGET_USER" >/dev/null 2>&1; then
    if ! grep -q "^${TARGET_USER}:" /etc/subuid 2>/dev/null; then
        echo "${TARGET_USER}:100000:200000" >> /etc/subuid
        info "已为用户 $TARGET_USER 写入 /etc/subuid"
    fi
    if ! grep -q "^${TARGET_USER}:" /etc/subgid 2>/dev/null; then
        echo "${TARGET_USER}:100000:200000" >> /etc/subgid
        info "已为用户 $TARGET_USER 写入 /etc/subgid"
    fi
else
    warn "用户 $TARGET_USER 不存在，跳过 subuid/subgid 配置，可用 -u 指定实际用户后重跑。"
fi

# ---------- AppArmor 兼容处理 (Ubuntu >= 23.10 等启用 apparmor 的系统) ----------
if [[ -f /etc/apparmor.d/podman ]]; then
    info "检测到 AppArmor podman profile，调整以适配 /usr/local/bin/podman ..."
    sed -Ei 's!^profile podman /usr/bin/podman !profile podman /usr/{bin,local/bin}/podman !' /etc/apparmor.d/podman || true
    if command -v apparmor_parser >/dev/null 2>&1; then
        apparmor_parser -r /etc/apparmor.d/podman 2>/dev/null || true
    fi
fi

# ---------- systemd: 开机自动重启 restart-policy=always 的容器 ----------
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^podman-restart'; then
    systemctl enable podman-restart >/dev/null 2>&1 || true
    info "已启用 podman-restart.service"
fi

info "podman $INSTALLED_VER 安装完成 ✅"
echo
echo "接下来可以："
echo "  1. 执行 'podman info' 检查环境是否正常"
echo "  2. 如需 rootless 使用，重新登录 $TARGET_USER 使 subuid/subgid 生效"
echo "  3. 如需 docker 命令别名: sudo ln -s /usr/local/bin/podman /usr/local/bin/docker"
echo
echo "卸载方式请参考: https://github.com/${GITHUB_REPO}#binary-uninstallation"
