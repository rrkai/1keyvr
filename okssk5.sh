#!/usr/bin/env bash

set -o pipefail

green="\033[32m"
yellow="\033[33m"
red="\033[31m"
none="\033[0m"

SCRIPT_NAME="sing-box-ss2022-socks5-installer"

SING_BOX_BIN="/usr/local/bin/sing-box"
SING_BOX_DIR="/etc/sing-box"
SING_BOX_CONFIG="/etc/sing-box/config.json"
SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"

SYSCTL_FILE="/etc/sysctl.d/99-sing-box-lite.conf"

SWAP_FILE="/swapfile"
SWAP_SIZE_MB="1024"

GH_REPO_API="https://api.github.com/repos/SagerNet/sing-box/releases"
GH_LATEST_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

# ============================================================
# 输出函数
# ============================================================

info() {
    echo -e "${green}$*${none}"
}

warn() {
    echo -e "${yellow}$*${none}"
}

error() {
    echo -e "${red}$*${none}"
}

die() {
    error "$*"
    exit 1
}

# ============================================================
# 基础检查
# ============================================================

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "错误: 请使用 root 权限运行此脚本。"
    fi
}

check_system() {
    if [[ ! -r /etc/os-release ]]; then
        die "错误: 无法识别系统版本。"
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-0}"
    OS_VERSION_MAJOR="${OS_VERSION_ID%%.*}"

    case "$OS_ID" in
        debian)
            if [[ "$OS_VERSION_MAJOR" -lt 11 ]]; then
                die "错误: 当前 Debian 版本过低，要求 Debian 11+。当前: ${PRETTY_NAME:-unknown}"
            fi
            ;;
        ubuntu)
            if [[ "$OS_VERSION_MAJOR" -lt 20 ]]; then
                die "错误: 当前 Ubuntu 版本过低，要求 Ubuntu 20.04+。当前: ${PRETTY_NAME:-unknown}"
            fi
            ;;
        *)
            die "错误: 当前脚本仅支持 Debian 11+ / Ubuntu 20.04+。当前: ${PRETTY_NAME:-unknown}"
            ;;
    esac

    if ! command -v systemctl >/dev/null 2>&1; then
        die "错误: 未检测到 systemd，本脚本需要 systemd 环境。"
    fi

    info "系统检查通过: ${PRETTY_NAME:-unknown}"
}

check_arch() {
    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64 | amd64)
            OS_ARCH="amd64"
            ;;
        aarch64 | arm64)
            OS_ARCH="arm64"
            ;;
        armv7l)
            OS_ARCH="armv7"
            ;;
        *)
            die "错误: 不支持的系统架构: ${ARCH}"
            ;;
    esac

    info "架构检查通过: ${ARCH} -> ${OS_ARCH}"
}

# ============================================================
# 安装依赖
# ============================================================

install_dependencies() {
    info "正在安装必要依赖..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y || die "apt-get update 失败。"

    apt-get install -y \
        curl \
        wget \
        jq \
        openssl \
        tar \
        gzip \
        coreutils \
        procps \
        iproute2 \
        ca-certificates \
        tzdata \
        systemd-timesyncd \
        || die "依赖安装失败。"

    update-ca-certificates >/dev/null 2>&1 || true
}

# ============================================================
# Swap：已有 swap 就不动
# ============================================================

setup_swap() {
    info "--- [1/6] 检查 Swap ---"

    if swapon --show | awk 'NR>1 {found=1} END {exit !found}'; then
        warn "检测到系统已有 Swap，跳过创建 ${SWAP_FILE}。"
        return 0
    fi

    if [[ -f "$SWAP_FILE" ]]; then
        rm -f "$SWAP_FILE"
    fi

    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" 2>/dev/null || \
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress
    else
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=progress
    fi

    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null || die "mkswap 失败。"
    swapon "$SWAP_FILE" || die "swapon 失败。"

    if ! grep -qE "^[^#]*${SWAP_FILE}[[:space:]]" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi

    info "Swap 配置完成。"
}

# ============================================================
# 时区、NTP、DNS：保守处理
# ============================================================

setup_time_dns() {
    info "--- [2/6] 配置时区、NTP 与 DNS ---"

    IP_TZ="$(curl -fsSL --max-time 5 http://ip-api.com/line?fields=timezone 2>/dev/null || echo "UTC")"

    if [[ "$IP_TZ" == Asia/* ]]; then
        TARGET_TZ="Asia/Hong_Kong"
    else
        TARGET_TZ="UTC"
    fi

    timedatectl set-timezone "$TARGET_TZ" 2>/dev/null || true
    timedatectl set-ntp true 2>/dev/null || true

    systemctl enable --now systemd-timesyncd 2>/dev/null || true
    systemctl restart systemd-timesyncd 2>/dev/null || true

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d

        cat > /etc/systemd/resolved.conf.d/99-sing-box-dns.conf << EOF
[Resolve]
DNS=1.1.1.1 9.9.9.9
FallbackDNS=8.8.8.8 1.0.0.1
DNSSEC=no
DNSOverTLS=no
EOF

        systemctl restart systemd-resolved 2>/dev/null || true
    else
        if [[ ! -f /etc/resolv.conf.bak ]]; then
            cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
        fi

        if [[ ! -L /etc/resolv.conf ]]; then
            cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF
        else
            warn "/etc/resolv.conf 是软链接，跳过直接写入 DNS。"
        fi
    fi

    info "时区、NTP 与 DNS 配置完成。"
}

# ============================================================
# 轻量 sysctl：只写保守参数
# ============================================================

setup_sysctl() {
    info "--- [3/6] 配置 BBR 与轻量网络优化 ---"

    cat > "$SYSCTL_FILE" << 'EOF'
# Sing-box lite network tuning
# Compatible with Debian 11+ / Ubuntu 20.04+

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

net.ipv4.ip_local_port_range = 1024 65535

net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192

vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.panic_on_oom = 0
EOF

    if sysctl --system >/tmp/${SCRIPT_NAME}-sysctl.log 2>&1; then
        info "网络优化参数已应用。"
    else
        warn "部分 sysctl 参数可能未生效，已跳过致命错误。日志：/tmp/${SCRIPT_NAME}-sysctl.log"
    fi

    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        warn "当前系统可能不支持或未启用 BBR，脚本将继续运行。"
    fi
}

# ============================================================
# 获取 sing-box 版本
# ============================================================

github_api_get_all_releases() {
    curl -fsSL --retry 3 --connect-timeout 10 \
        -H "User-Agent: ${SCRIPT_NAME}" \
        "$GH_REPO_API"
}

github_api_get_latest_release() {
    curl -fsSL --retry 3 --connect-timeout 10 \
        -H "User-Agent: ${SCRIPT_NAME}" \
        "$GH_LATEST_API"
}

get_sing_box_version() {
    info "--- [4/6] 获取 Sing-box 版本 ---"

    TARGET_VERSION=""
    VERSION_SOURCE=""

    warn "优先尝试获取 Sing-box 1.13.x 最新稳定版..."

    RELEASES_JSON="$(github_api_get_all_releases 2>/dev/null || true)"

    if [[ -n "$RELEASES_JSON" ]] && echo "$RELEASES_JSON" | jq empty >/dev/null 2>&1; then
        TARGET_VERSION="$(
            echo "$RELEASES_JSON" \
            | jq -r '.[] | select(.prerelease == false and .draft == false) | .tag_name' \
            | grep -E '^v1\.13\.[0-9]+$' \
            | sort -Vr \
            | head -n 1 \
            | sed 's/^v//'
        )"
    fi

    if [[ -n "$TARGET_VERSION" && "$TARGET_VERSION" != "null" ]]; then
        VERSION_SOURCE="1.13.x"
        info "已锁定 Sing-box 1.13.x 版本: v${TARGET_VERSION}"
        return 0
    fi

    warn "未获取到可用的 1.13.x 稳定版，开始 fallback 到 latest 稳定版..."

    LATEST_JSON="$(github_api_get_latest_release 2>/dev/null || true)"

    if [[ -n "$LATEST_JSON" ]] && echo "$LATEST_JSON" | jq empty >/dev/null 2>&1; then
        TARGET_VERSION="$(
            echo "$LATEST_JSON" \
            | jq -r 'select(.prerelease == false and .draft == false) | .tag_name' \
            | sed 's/^v//'
        )"
    fi

    if [[ -n "$TARGET_VERSION" && "$TARGET_VERSION" != "null" ]]; then
        VERSION_SOURCE="latest"
        info "已 fallback 到 Sing-box latest 稳定版: v${TARGET_VERSION}"
        return 0
    fi

    if [[ -n "$RELEASES_JSON" ]] && echo "$RELEASES_JSON" | jq empty >/dev/null 2>&1; then
        TARGET_VERSION="$(
            echo "$RELEASES_JSON" \
            | jq -r '.[] | select(.prerelease == false and .draft == false) | .tag_name' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -Vr \
            | head -n 1 \
            | sed 's/^v//'
        )"
    fi

    if [[ -n "$TARGET_VERSION" && "$TARGET_VERSION" != "null" ]]; then
        VERSION_SOURCE="stable-fallback"
        info "已使用稳定版兜底版本: v${TARGET_VERSION}"
        return 0
    fi

    die "错误: 无法获取 Sing-box 1.13.x 或 latest 稳定版本。请检查 GitHub 访问。"
}

# ============================================================
# 安装 sing-box
# ============================================================

install_sing_box() {
    info "正在安装 Sing-box v${TARGET_VERSION}..."

    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${TARGET_VERSION}/sing-box-${TARGET_VERSION}-linux-${OS_ARCH}.tar.gz"

    TMP_DIR="$(mktemp -d)"
    cd "$TMP_DIR" || die "无法进入临时目录。"

    if ! wget --tries=3 --timeout=30 -qO sing-box.tar.gz "$DOWNLOAD_URL"; then
        rm -rf "$TMP_DIR"
        die "错误: Sing-box 下载失败: ${DOWNLOAD_URL}"
    fi

    if [[ ! -s sing-box.tar.gz ]]; then
        rm -rf "$TMP_DIR"
        die "错误: 下载文件为空。"
    fi

    if ! tar -xzf sing-box.tar.gz; then
        rm -rf "$TMP_DIR"
        die "错误: 解压 Sing-box 失败。"
    fi

    EXTRACTED_BIN="sing-box-${TARGET_VERSION}-linux-${OS_ARCH}/sing-box"

    if [[ ! -f "$EXTRACTED_BIN" ]]; then
        rm -rf "$TMP_DIR"
        die "错误: 未找到 sing-box 可执行文件，可能是架构包名变化。"
    fi

    install -m 755 "$EXTRACTED_BIN" "$SING_BOX_BIN"

    cd /root || true
    rm -rf "$TMP_DIR"

    if ! "$SING_BOX_BIN" version >/dev/null 2>&1; then
        die "错误: Sing-box 安装后无法运行。"
    fi

    info "Sing-box 安装完成: $("$SING_BOX_BIN" version | head -n 1)"
}

# ============================================================
# 工具函数
# ============================================================

get_random_port() {
    local port

    while true; do
        port="$(shuf -i 10000-60000 -n 1)"

        if ! ss -tuln | awk '{print $5}' | grep -qE "[:.]${port}$"; then
            echo "$port"
            return 0
        fi
    done
}

base64_no_wrap() {
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w 0
    else
        base64 | tr -d '\n'
    fi
}

urlencode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0; pos<strlen; pos++ )); do
        c="${string:$pos:1}"
        case "$c" in
            [a-zA-Z0-9.~_-])
                encoded+="$c"
                ;;
            *)
                printf -v o '%%%02X' "'$c"
                encoded+="$o"
                ;;
        esac
    done

    echo "$encoded"
}

make_ss_uri() {
    local method="$1"
    local password="$2"
    local server="$3"
    local port="$4"
    local name="$5"

    local enc_method
    local enc_password
    local enc_name

    enc_method="$(urlencode "$method")"
    enc_password="$(urlencode "$password")"
    enc_name="$(urlencode "$name")"

    echo "ss://${enc_method}:${enc_password}@${server}:${port}#${enc_name}"
}

make_ss_legacy_uri() {
    local method="$1"
    local password="$2"
    local server="$3"
    local port="$4"
    local name="$5"

    local userinfo
    local enc_name

    userinfo="$(echo -n "${method}:${password}" | base64_no_wrap)"
    enc_name="$(urlencode "$name")"

    echo "ss://${userinfo}@${server}:${port}#${enc_name}"
}

make_socks_uri() {
    local username="$1"
    local password="$2"
    local server="$3"
    local port="$4"
    local name="$5"

    local enc_user
    local enc_pass
    local enc_name

    enc_user="$(urlencode "$username")"
    enc_pass="$(urlencode "$password")"
    enc_name="$(urlencode "$name")"

    echo "socks5://${enc_user}:${enc_pass}@${server}:${port}#${enc_name}"
}

# ============================================================
# 老配置检测：只处理节点相关入站
# ============================================================

inspect_old_node_config() {
    OLD_CONFIG_FOUND="false"
    OLD_NODE_FOUND="false"
    OLD_SS_PORT=""
    OLD_SOCKS_PORT=""

    if [[ ! -f "$SING_BOX_CONFIG" ]]; then
        return 0
    fi

    OLD_CONFIG_FOUND="true"

    if ! jq empty "$SING_BOX_CONFIG" >/dev/null 2>&1; then
        warn "检测到旧配置文件，但 JSON 格式异常，将备份后重写完整配置。"
        OLD_NODE_FOUND="unknown"
        return 0
    fi

    OLD_SS_PORT="$(
        jq -r '
          (.inbounds // [])
          | map(select((.type // "") == "shadowsocks" or (.tag // "") == "ss2022-in" or (.tag // "") == "ss-in"))
          | .[0].listen_port // empty
        ' "$SING_BOX_CONFIG"
    )"

    OLD_SOCKS_PORT="$(
        jq -r '
          (.inbounds // [])
          | map(select((.type // "") == "socks" or (.tag // "") == "socks5-in" or (.tag // "") == "socks-in"))
          | .[0].listen_port // empty
        ' "$SING_BOX_CONFIG"
    )"

    if [[ -n "$OLD_SS_PORT" || -n "$OLD_SOCKS_PORT" ]]; then
        OLD_NODE_FOUND="true"
    fi
}

backup_old_config() {
    if [[ -f "$SING_BOX_CONFIG" ]]; then
        BACKUP_FILE="${SING_BOX_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$SING_BOX_CONFIG" "$BACKUP_FILE"
        warn "已备份旧配置到: ${BACKUP_FILE}"
    fi
}

write_fresh_config() {
    cat > "$SING_BOX_CONFIG" << EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss2022-in",
      "listen": "::",
      "listen_port": ${SS_PORT},
      "method": "2022-blake3-aes-256-gcm",
      "password": "${SS_PASS}",
      "tcp_fast_open": true
    },
    {
      "type": "socks",
      "tag": "socks5-in",
      "listen": "::",
      "listen_port": ${SOCKS_PORT},
      "users": [
        {
          "username": "${SOCKS_USER}",
          "password": "${SOCKS_PASS}"
        }
      ],
      "tcp_fast_open": true
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

replace_node_in_existing_config() {
    local tmp_config
    tmp_config="$(mktemp)"

    jq \
      --argjson ss_port "$SS_PORT" \
      --argjson socks_port "$SOCKS_PORT" \
      --arg ss_pass "$SS_PASS" \
      --arg socks_user "$SOCKS_USER" \
      --arg socks_pass "$SOCKS_PASS" \
      '
      def is_old_node_inbound:
        ((.tag // "") as $tag | ["ss2022-in","ss-in","socks5-in","socks-in"] | index($tag)) != null
        or
        ((.type // "") as $type | ["shadowsocks","socks"] | index($type)) != null;

      .log = (.log // {"level":"warn","timestamp":true})
      |
      .inbounds = (
        ((.inbounds // []) | map(select(is_old_node_inbound | not)))
        +
        [
          {
            "type": "shadowsocks",
            "tag": "ss2022-in",
            "listen": "::",
            "listen_port": $ss_port,
            "method": "2022-blake3-aes-256-gcm",
            "password": $ss_pass,
            "tcp_fast_open": true
          },
          {
            "type": "socks",
            "tag": "socks5-in",
            "listen": "::",
            "listen_port": $socks_port,
            "users": [
              {
                "username": $socks_user,
                "password": $socks_pass
              }
            ],
            "tcp_fast_open": true
          }
        ]
      )
      |
      .outbounds = (
        if ((.outbounds // []) | type == "array" and length > 0)
        then .outbounds
        else [{"type":"direct","tag":"direct"}]
        end
      )
      ' "$SING_BOX_CONFIG" > "$tmp_config"

    if jq empty "$tmp_config" >/dev/null 2>&1; then
        mv "$tmp_config" "$SING_BOX_CONFIG"
    else
        rm -f "$tmp_config"
        die "错误: 生成新配置失败，已保留旧配置备份。"
    fi
}

# ============================================================
# 生成或替换节点配置
# ============================================================

generate_or_replace_node_config() {
    info "--- [5/6] 生成 / 替换 SS2022 与 SOCKS5 节点配置 ---"

    SS_PORT="$(get_random_port)"
    SOCKS_PORT="$(get_random_port)"

    while [[ "$SOCKS_PORT" == "$SS_PORT" ]]; do
        SOCKS_PORT="$(get_random_port)"
    done

    SS_PASS="$(openssl rand -base64 32)"
    SOCKS_USER="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10)"
    SOCKS_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)"

    mkdir -p "$SING_BOX_DIR"

    inspect_old_node_config

    if [[ "$OLD_CONFIG_FOUND" == "true" ]]; then
        backup_old_config

        if jq empty "$SING_BOX_CONFIG" >/dev/null 2>&1; then
            if [[ "$OLD_NODE_FOUND" == "true" ]]; then
                warn "检测到旧节点配置，将只替换节点相关入站。"
                [[ -n "$OLD_SS_PORT" ]] && warn "旧 SS 入站端口: ${OLD_SS_PORT}"
                [[ -n "$OLD_SOCKS_PORT" ]] && warn "旧 SOCKS 入站端口: ${OLD_SOCKS_PORT}"
            else
                warn "检测到已有 sing-box 配置，但未发现旧 SS/SOCKS 节点，将追加新节点入站。"
            fi

            replace_node_in_existing_config
        else
            warn "旧配置 JSON 异常，已备份并重写为标准 SS2022 + SOCKS5 配置。"
            write_fresh_config
        fi
    else
        write_fresh_config
    fi

    chmod 600 "$SING_BOX_CONFIG"

    if ! "$SING_BOX_BIN" check -c "$SING_BOX_CONFIG"; then
        error "Sing-box 配置校验失败，最近生成的配置如下："
        cat "$SING_BOX_CONFIG"
        die "请检查配置。"
    fi

    info "节点配置已生成 / 替换并校验通过。"
}

# ============================================================
# systemd
# ============================================================

setup_systemd() {
    info "--- [6/6] 配置并启动 Sing-box 服务 ---"

    MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"

    if [[ "$MEM_MB" -le 256 ]]; then
        GO_MEM_LIMIT="80MiB"
    elif [[ "$MEM_MB" -le 512 ]]; then
        GO_MEM_LIMIT="120MiB"
    else
        GO_MEM_LIMIT="150MiB"
    fi

    cat > "$SING_BOX_SERVICE" << EOF
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SING_BOX_BIN} run -c ${SING_BOX_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

Environment=GOGC=50
Environment=GOMEMLIMIT=${GO_MEM_LIMIT}

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${SING_BOX_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box

    sleep 2

    if ! systemctl is-active --quiet sing-box; then
        error "Sing-box 启动失败，最近日志如下："
        journalctl -u sing-box --no-pager -n 80
        exit 1
    fi

    info "Sing-box 服务已启动。"
}

# ============================================================
# 防火墙
# ============================================================

setup_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "active"; then
        ufw allow "${SS_PORT}/tcp" >/dev/null 2>&1 || true
        ufw allow "${SS_PORT}/udp" >/dev/null 2>&1 || true
        ufw allow "${SOCKS_PORT}/tcp" >/dev/null 2>&1 || true
        warn "已尝试放行 ufw 端口。"
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${SS_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${SS_PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${SOCKS_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        warn "已尝试放行 firewalld 端口。"
    fi
}

# ============================================================
# 获取公网 IP
# ============================================================

get_server_ip() {
    SERVER_IP="$(
        curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -fsSL --max-time 5 http://checkip.amazonaws.com 2>/dev/null \
        || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
        || echo "YOUR_SERVER_IP"
    )"

    SERVER_IP="$(echo "$SERVER_IP" | tr -d '\r\n ')"
}

# ============================================================
# 输出结果
# ============================================================

print_result() {
    get_server_ip

    SS_NAME="SS2022-${SERVER_IP}"
    SOCKS_NAME="SOCKS5-${SERVER_IP}"

    SS_URI="$(make_ss_uri "2022-blake3-aes-256-gcm" "$SS_PASS" "$SERVER_IP" "$SS_PORT" "$SS_NAME")"
    SS_LEGACY_URI="$(make_ss_legacy_uri "2022-blake3-aes-256-gcm" "$SS_PASS" "$SERVER_IP" "$SS_PORT" "$SS_NAME")"
    SOCKS_URI="$(make_socks_uri "$SOCKS_USER" "$SOCKS_PASS" "$SERVER_IP" "$SOCKS_PORT" "$SOCKS_NAME")"

    echo -e "\n${green}=================方糖网络====================${none}"
    echo -e "${green}🎉 部署完成！节点信息如下：${none}"
    echo -e "${green}=========================================${none}\n"

    echo -e "${yellow}[服务器信息]${none}"
    echo -e "系统: ${green}${PRETTY_NAME:-unknown}${none}"
    echo -e "服务器 IP: ${green}${SERVER_IP}${none}"
    echo -e "Sing-box 版本: ${green}v${TARGET_VERSION}${none}"
    echo -e "Go 内存限制: ${green}${GO_MEM_LIMIT}${none}"
    echo -e "参数优化: ${green}BBR+FQ+DNS+临时内存优化完成${none}"
    echo ""

    echo -e "${yellow}[SS2022 节点信息]${none}"
    echo -e "协议: ${green}Shadowsocks 2022${none}"
    echo -e "地址: ${green}${SERVER_IP}${none}"
    echo -e "端口: ${green}${SS_PORT}${none}"
    echo -e "加密方式: ${green}2022-blake3-aes-256-gcm${none}"
    echo -e "密码: ${green}${SS_PASS}${none}"
    echo -e "推荐链接: ${green}${SS_URI}${none}"
    echo -e "兼容链接: ${green}${SS_LEGACY_URI}${none}"
    echo ""

    echo -e "${yellow}[SOCKS5 节点信息]${none}"
    echo -e "协议: ${green}SOCKS5${none}"
    echo -e "地址: ${green}${SERVER_IP}${none}"
    echo -e "端口: ${green}${SOCKS_PORT}${none}"
    echo -e "用户名: ${green}${SOCKS_USER}${none}"
    echo -e "密码: ${green}${SOCKS_PASS}${none}"
    echo -e "链接: ${green}${SOCKS_URI}${none}"

    echo -e "\n${green}=================方糖网络====================${none}"
}

# ============================================================
# 主流程
# ============================================================

main() {
    check_root
    check_system
    check_arch

    info "=== 开始部署 / 替换 Sing-box SS2022 + SOCKS5 节点 ==="

    install_dependencies
    setup_swap
    setup_time_dns
    setup_sysctl

    get_sing_box_version
    install_sing_box

    generate_or_replace_node_config
    setup_systemd
    setup_firewall

    print_result
}

main "$@"
