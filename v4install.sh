#!/bin/bash

# ==========================================
# 自动化极速部署 Xray VLESS-Reality (纯 IPv4)
# ==========================================

sleep 1

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
cyan='\e[96m'
none='\e[0m'

echo -e "$yellow开始全自动部署 Xray VLESS-Reality...$none"
echo "----------------------------------------------------------------"

# 准备工作
apt-get update -qq
apt-get install -y curl wget sudo jq qrencode net-tools lsof >/dev/null 2>&1

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

# 2. 自动生成节点核心参数
port=$((RANDOM % 55535 + 10000)) # 随机生成 10000-65535 端口
domain="www.overstock.com"       # 默认伪装域名
uuid=$(cat /proc/sys/kernel/random/uuid)

echo -e "$yellow本机 IPv4: ${cyan}${ip}${none}"
echo -e "$yellow节点端口: ${cyan}${port}${none}"
echo -e "$yellow节点域名: ${cyan}${domain}${none}"
echo "----------------------------------------------------------------"

# 3. 安装 Xray 最新官方版本
echo -e "${yellow}正在安装 Xray 官方最新版...$none"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata >/dev/null 2>&1

# 4. 生成密钥对与 ShortID (月份+7位随机)
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

# 6. 优化系统 DNS
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
service xray restart

# 10. 生成节点链接并设置快捷键
fingerprint="safari"
spiderx=""

vless_reality_url="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}&spx=${spiderx}&#VLESS_R_${ip}"
echo $vless_reality_url > ~/_vless_reality_url_

if [[ -n "$ZSH_VERSION" ]]; then
    CONFIG_FILE="$HOME/.zshrc"
elif [[ -n "$BASH_VERSION" ]]; then
    CONFIG_FILE="$HOME/.bashrc"
else
    if [[ -f "$HOME/.bashrc" ]]; then
        CONFIG_FILE="$HOME/.bashrc"
    elif [[ -f "$HOME/.zshrc" ]]; then
        CONFIG_FILE="$HOME/.zshrc"
    else
        CONFIG_FILE="$HOME/.bashrc"
    fi
fi

if ! grep -q "^alias 1keyvr=" "$CONFIG_FILE" 2>/dev/null; then
    echo "alias 1keyvr='cat ~/_vless_reality_url_'" >> "$CONFIG_FILE"
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
echo -e "$green[✓] SWAP、DNS、BBR 调优均已完成。$none"
echo -e "$green[✓] 终端输入 '1keyvr' 可随时找回该链接。$none"
