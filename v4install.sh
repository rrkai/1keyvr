#!/bin/bash

# ==========================================
# 自动化极速部署 Xray VLESS-Reality (纯 IPv4)
# 完美兼容: Debian 10+ / Ubuntu 20.04+
# 定制项: 固定端口 11443, 自动安装最新版 Xray
# ==========================================

sleep 1

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
cyan='\e[96m'
none='\e[0m'

echo -e "$yellow开始全自动部署 Xray VLESS-Reality...$none"
echo "----------------------------------------------------------------"

# --- 兼容性：检查是否为 root 用户 ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${red}错误: 此脚本涉及系统底层修改，必须以 root 身份运行！${none}"
    echo -e "${yellow}请先执行 ${cyan}sudo -i${yellow} 切换到 root 用户后，再运行本脚本。${none}"
    exit 1
fi

# --- 兼容性：检查系统发行版 ---
source /etc/os-release
if [[ "${ID}" != "debian" && "${ID}" != "ubuntu" ]]; then
    echo -e "${red}错误: 本脚本仅支持 Debian 和 Ubuntu 系统！检测到当前系统为: ${ID}${none}"
    exit 1
fi

echo -e "${green}系统兼容性检查通过: ${PRETTY_NAME}${none}"
echo "----------------------------------------------------------------"

# 准备工作 (统一使用 apt-get 保证无交互静默运行)
apt-get update -qq
apt-get install -y curl wget sudo jq qrencode net-tools lsof openssl >/dev/null 2>&1

# 1. 强制获取本机的公网 IPv4
echo -e "${green}正在获取本机公网 IPv4 地址...${none}"
InFaces=($(ls /sys/class/net/ | grep -E '^(eth|ens|eno|esp|enp|venet|vif)'))
for i in "${InFaces[@]}"; do
    Public_IPv4=$(curl -4s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
    if [[ -n "$Public_IPv4" ]]; then
        ip="$Public_IPv4"
        break
    fi
done

if [[ -z "$ip" ]]; then
    echo -e "$red无法获取公网 IPv4 地址，脚本终止。$none"
    exit 1
fi

# 2. 生成节点核心参数 (端口固定为 11443)
port=11443                       # 已固定端口为 11443
domain="www.overstock.com"       # 默认伪装域名
uuid=$(cat /proc/sys/kernel/random/uuid)

echo -e "$yellow本机 IPv4: ${cyan}${ip}${none}"
echo -e "$yellow节点端口: ${cyan}${port}${none}"
echo -e "$yellow节点域名: ${cyan}${domain}${none}"
echo "----------------------------------------------------------------"

# 3. 安装 Xray 最新版本 (并加入失败拦截机制)
echo -e "${yellow}正在安装 Xray 最新版...$none"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata >/dev/null 2>&1

# 校验安装是否真正成功
if ! command -v xray &> /dev/null; then
    echo -e "${red}致命错误: Xray 核心安装失败！请检查你的服务器网络是否能正常访问 GitHub。${none}"
    exit 1
fi

# 4. 生成密钥对与优雅 ShortID (1位月份+7位随机)
reality_key_seed=$(echo -n ${uuid} | md5sum | head -c 32 | base64 -w 0 | tr '+/' '-_' | tr -d '=')
tmp_key=$(echo -n "${reality_key_seed}" | xargs xray x25519 -i)
private_key=$(echo "$tmp_key" | grep -iE 'Private' | awk '{print $NF}')
public_key=$(echo "$tmp_key" | grep -iE 'Public|Password' | awk '{print $NF}')
shortid=$(printf "%x" $(date +%m))$(openssl rand -hex 4 | cut -c 1-7)

# 5. 极速设置 SWAP (1GB)
echo -e "$yellow正在极速配置 1GB SWAP...$none"
FINAL_SWAP_SIZE_MB=1024
existing_swap=$(swapon --show=NAME --noheadings | head -n1)
if [ -n "$existing_swap" ]; then
    swapoff "$existing_swap"
    [ -f "$existing_swap" ] && rm -f "$existing_swap"
fi

swap_path="/swapfile"
if ! fallocate -l 1G "$swap_path" 2>/dev/null; then
    dd if=/dev/zero of="$swap_path" bs=1M count=1024 status=none
fi
chmod 600 "$swap_path"
mkswap "$swap_path" >/dev/null 2>&1
swapon "$swap_path"

if ! grep -q "^$swap_path" /etc/fstab; then
    echo "$swap_path none swap sw 0 0" >> /etc/fstab
fi
sed -i '/^vm.swappiness/d' /etc/sysctl.conf
echo "vm.swappiness = 10" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1

# 6. 优化系统 DNS (完美兼容 Ubuntu systemd-resolved)
echo -e "$yellow正在优化系统 DNS...$none"
[ ! -f /etc/resolv.conf.bak ] && cp /etc/resolv.conf /etc/resolv.conf.bak
cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF

if command -v systemctl &> /dev/null && systemctl is-active --quiet systemd-resolved; then
    if [[ ! -L /etc/resolv.conf ]] && [[ -f /run/systemd/resolve/resolv.conf ]]; then
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        if [[ -f /etc/systemd/resolved.conf ]]; then
             [ ! -f /etc/systemd/resolved.conf.bak ] && cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak
             sed -i '/^\[Resolve\]/a DNS=1.1.1.1 9.9.9.9' /etc/systemd/resolved.conf
             sed -i '/^DNS=/!b;n;s/.*/DNS=1.1.1.1 9.9.9.9/' /etc/systemd/resolved.conf
             sed -i '/FallbackDNS=/c\FallbackDNS=9.9.9.9 1.1.1.1' /etc/systemd/resolved.conf
             sed -i '/^FallbackDNS=/!b;n;s/.*/FallbackDNS=9.9.9.9 1.1.1.1/' /etc/systemd/resolved.conf
             if ! grep -q "^FallbackDNS=" /etc/systemd/resolved.conf; then
                 sed -i '/^\[Resolve\]/a FallbackDNS=9.9.9.9 1.1.1.1' /etc/systemd/resolved.conf
             fi
             sed -i 's/^#DNSSEC=/DNSSEC=/' /etc/systemd/resolved.conf
             sed -i 's/^#DNSOverTLS=/DNSOverTLS=/' /etc/systemd/resolved.conf
             systemctl reload-or-restart systemd-resolved >/dev/null 2>&1
        fi
    fi
fi

# 7. 打开BBR并执行TCP调优
echo -e "$yellow正在应用 TCP BBR 调优脚本...$none"
curl -sSL https://github.com/rrkai/1keyvr/raw/main/tcp.sh | bash >/dev/null 2>&1

# 8. 写入 Xray 配置文件
echo -e "$yellow正在生成 /usr/local/etc/xray/config.json...$none"
# 防呆机制：确保配置目录一定存在
mkdir -p /usr/local/etc/xray/

cat > /usr/local/etc/xray/config.json <<-EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${domain}:443",
          "xver": 0,
          "serverNames": ["${domain}"],
          "privateKey": "${private_key}",
          "shortIds": ["${shortid}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv4"
        },
        "tag": "force-ipv4"
    },
    {
        "protocol": "socks",
        "settings": {
            "servers": [{
                "address": "127.0.0.1",
                "port": 40000
            }]
         },
        "tag": "socks5-warp"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

# 9. 重启 Xray 使得配置生效
systemctl daemon-reload
systemctl restart xray
systemctl enable xray >/dev/null 2>&1

# 10. 生成节点链接并设置快捷键
fingerprint="safari"
spiderx=""

vless_reality_url="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}&spx=${spiderx}&#VLESS_R_${ip}"
echo "$vless_reality_url" > /root/_vless_reality_url_

# 将快捷键写入 root 用户的配置
if [[ -f "/root/.zshrc" ]]; then
    CONFIG_FILE="/root/.zshrc"
else
    CONFIG_FILE="/root/.bashrc"
    [ ! -f "$CONFIG_FILE" ] && touch "$CONFIG_FILE"
fi

if ! grep -q "^alias 1keyvr=" "$CONFIG_FILE" 2>/dev/null; then
    echo "alias 1keyvr='cat /root/_vless_reality_url_'" >> "$CONFIG_FILE"
fi
source "$CONFIG_FILE" > /dev/null 2>&1 || true

echo
echo "---------- 部署完成 | 节点信息 -------------"
echo -e "$yellow 地址 (IP)       = $cyan${ip}$none"
echo -e "$yellow 端口 (Port)     = $cyan${port}$none"
echo -e "$yellow UUID          = $cyan${uuid}$none"
echo -e "$yellow 伪装域名 (SNI)  = $cyan${domain}$none"
echo -e "$yellow 公钥 (pbk)      = $cyan${public_key}$none"
echo -e "$yellow ShortID (sid) = $cyan${shortid}$none"
echo "------------------------------------------------"
echo -e "${green}您的 VLESS 节点链接如下：${none}"
echo -e "${cyan}${vless_reality_url}${none}"
echo "------------------------------------------------"
echo -e "$green[✓] OS 兼容、SWAP、DNS、BBR 调优均已完成。$none"
echo -e "$green[✓] 终端输入 '1keyvr' 可随时找回该链接。$none"
