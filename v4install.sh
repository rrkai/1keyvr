# 等待1秒, 避免curl下载脚本的打印与脚本本身的显示冲突, 吃掉了提示用户按回车继续的信息
sleep 1

echo -e "                     _ ___                   \n ___ ___ __ __ ___ _| |  _|___ __ __   _ ___ \n|-_ |_  |  |  |-_ | _ |   |- _|  |  |_| |_  |\n|___|___|  _  |___|___|_|_|___|  _  |___|___|\n        |_____|               |_____|        "
red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

error() {
    echo -e "\n$red 输入错误! $none\n"
}

warn() {
    echo -e "\n$yellow $1 $none\n"
}

pause() {
    read -rsp "$(echo -e "按 $green Enter 回车键 $none 继续....或按 $red Ctrl + C $none 取消.")" -d $'\n'
    echo
}

# 确保有 curl 和 wget
apt-get -y install curl wget -qq

# 说明
echo
echo -e "$yellow此脚本仅兼容于Debian 11+系统. 如果你的系统不符合,请Ctrl+C退出脚本$none"
echo -e "本脚本支持带参数执行, 省略交互过程, 详见GitHub."
echo "----------------------------------------------------------------"

# 本机 IP
InFaces=($(ls /sys/class/net/ | grep -E '^(eth|ens|eno|esp|enp|venet|vif)'))

for i in "${InFaces[@]}"; do  # 从网口循环获取IP
    # 增加超时时间, 以免在某些网络环境下请求IPv6等待太久
    Public_IPv4=$(curl -4s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
    Public_IPv6=$(curl -6s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")

    if [[ -n "$Public_IPv4" ]]; then  # 检查是否获取到IP地址
        IPv4="$Public_IPv4"
    fi
    if [[ -n "$Public_IPv6" ]]; then  # 检查是否获取到IP地址            
        IPv6="$Public_IPv6"
    fi
done

# 通过IP, host, 时区, 生成UUID. 重装脚本不改变, 不改变节点信息, 方便个人使用
uuidSeed=${IPv4}${IPv6}$(cat /proc/sys/kernel/hostname)$(timedatectl | awk '/Time zone/ {print $3}')
default_uuid=$(curl -sL https://www.uuidtools.com/api/generate/v3/namespace/ns:dns/name/${uuidSeed} | grep -oP '[^-]{8}-[^-]{4}-[^-]{4}-[^-]{4}-[^-]{12}')

# 如果你想使用纯随机的UUID
# default_uuid=$(cat /proc/sys/kernel/random/uuid)

# 执行脚本带参数
if [ $# -ge 1 ]; then
    # 第1个参数是搭在ipv4还是ipv6上
    case ${1} in
    4)
        netstack=4
        ip=${IPv4}
        ;;
    6)
        netstack=6
        ip=${IPv6}
        ;;
    *) # initial
        if [[ -n "$IPv4" ]]; then  # 检查是否获取到IP地址
            netstack=4
            ip=${IPv4}
        elif [[ -n "$IPv6" ]]; then  # 检查是否获取到IP地址            
            netstack=6
            ip=${IPv6}
        else
            warn "没有获取到公共IP"
        fi
        ;;
    esac

    # 第2个参数是port
    port=${2}
    if [[ -z $port ]]; then
      port=11443
    fi

    # 第3个参数是域名
    domain=${3}
    if [[ -z $domain ]]; then
      domain="www.overstock.com"
    fi

    # 第4个参数是UUID
    uuid=${4}
    if [[ -z $uuid ]]; then
        uuid=${default_uuid}
    fi

    echo -e "$yellow netstack = ${cyan}${netstack}${none}"
    echo -e "$yellow 本机IP = ${cyan}${ip}${none}"
    echo -e "$yellow 端口 (Port) = ${cyan}${port}${none}"
    echo -e "$yellow 用户ID (User ID / UUID) = $cyan${uuid}${none}"
    echo -e "$yellow SNI = ${cyan}$domain${none}"
    echo "----------------------------------------------------------------"
fi

# pause

# 准备工作
apt update
apt install -y curl wget sudo jq qrencode net-tools lsof

# Xray官方脚本 安装最新版本
echo
echo -e "${yellow}Xray官方脚本安装最新版本$none"
echo "----------------------------------------------------------------"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 更新 geodata
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata

# 如果脚本带参数执行的, 要在安装了xray之后再生成默认私钥公钥shortID
if [[ -n $uuid ]]; then
  # 私钥种子
  reality_key_seed=$(echo -n ${uuid} | md5sum | head -c 32 | base64 -w 0 | tr '+/' '-_' | tr -d '=')

  # 生成私钥公钥 (适配最新版Xray输出格式)
  tmp_key=$(echo -n "${reality_key_seed}" | xargs xray x25519 -i)
  private_key=$(echo "$tmp_key" | grep -iE 'Private' | awk '{print $NF}')
  public_key=$(echo "$tmp_key" | grep -iE 'Public|Password' | awk '{print $NF}')

  # ShortID
  shortid=$(printf "%x" $(date +%m))$(openssl rand -hex 4 | cut -c 1-7)
  
  echo
  echo "私钥公钥要在安装xray之后才可以生成"
  echo -e "$yellow 私钥 (PrivateKey) = ${cyan}${private_key}${none}"
  echo -e "$yellow 公钥 (PublicKey) = ${cyan}${public_key}${none}"
  echo -e "$yellow ShortId = ${cyan}${shortid}${none}"
  echo "----------------------------------------------------------------"
fi

echo "---------- 极速设置 SWAP ----------"
echo -e "$yellow开始检查并设置 SWAP 虚拟内存...$none"
echo "----------------------------------------------------------------"

# 统一设定 SWAP 大小为 1GB，避免空间浪费
FINAL_SWAP_SIZE_MB=1024
echo -e "${green}依据优化策略，统一配置 SWAP 大小为 1GB (1024MB)。${none}"

# 检查是否存在现有的swap文件或分区
existing_swap=$(swapon --show=NAME --noheadings | head -n1)
if [ -n "$existing_swap" ]; then
    echo -e "${yellow}检测到现有 SWAP: $existing_swap, 正在关闭...${none}"
    swapoff "$existing_swap"
    if [ -f "$existing_swap" ]; then
        echo -e "${green}删除旧的 SWAP 文件: $existing_swap${none}"
        rm -f "$existing_swap"
    fi
fi

# 创建新的swap文件 (使用 fallocate 替代缓慢的 dd，实现 0.01 秒瞬间创建)
swap_path="/swapfile"
echo -e "${green}正在极速划分新 SWAP 空间: $swap_path (1024MB)...${none}"
if fallocate -l 1G "$swap_path" 2>/dev/null; then
    echo -e "${green}瞬间分配空间成功。${none}"
else
    # 极少数不支持 fallocate 的旧系统退回到 dd
    dd if=/dev/zero of="$swap_path" bs=1M count=1024 status=none
fi

chmod 600 "$swap_path"
mkswap "$swap_path" >/dev/null 2>&1

# 立即启用新的swap，无需等待重启
swapon "$swap_path"

# 配置开机自启
if ! grep -q "^$swap_path" /etc/fstab; then
    echo -e "${green}配置 SWAP 开机自启 (/etc/fstab)${none}"
    echo "$swap_path none swap sw 0 0" >> /etc/fstab
fi

# 设置vm.swappiness参数
swappiness_value=10
echo -e "${green}设置 vm.swappiness=$swappiness_value${none}"
sed -i '/^vm.swappiness/d' /etc/sysctl.conf
echo "vm.swappiness = $swappiness_value" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1

echo -e "${green}SWAP 设置完成并已当场生效。当前 SWAP 信息:${none}"
swapon --show
echo "----------------------------------------------------------------"
# ---------- 优化 DNS 步骤 ----------
echo -e "$yellow开始修改系统 DNS$none"
echo "----------------------------------------------------------------"

# 检查 /etc/resolv.conf 是否已存在备份
if [[ ! -f /etc/resolv.conf.bak ]]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak
    echo -e "${green}已备份原 /etc/resolv.conf 到 /etc/resolv.conf.bak${none}"
else
    echo -e "${green}/etc/resolv.conf.bak 已存在。${none}"
fi

# 清空 /etc/resolv.conf 并写入新的 DNS 配置
cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF

echo -e "${green}已清空 /etc/resolv.conf 并设置新的 DNS: 1.1.1.1, 9.9.9.9${none}"

# 尝试检查并处理 systemd-resolved 或 NetworkManager
if command -v systemctl &> /dev/null && systemctl is-active --quiet systemd-resolved; then
    echo -e "${yellow}检测到 systemd-resolved 服务正在运行，可能会影响 /etc/resolv.conf 的持久性。${none}"
    if [[ ! -L /etc/resolv.conf ]] && [[ -f /run/systemd/resolve/resolv.conf ]]; then
        echo -e "${green}正在将 /etc/resolv.conf 配置为指向 systemd-resolved 的配置文件...${none}"
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        if [[ -f /etc/systemd/resolved.conf ]]; then
             if [[ ! -f /etc/systemd/resolved.conf.bak ]]; then
                 cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak
                 echo -e "${green}已备份原 /etc/systemd/resolved.conf 到 /etc/systemd/resolved.conf.bak${none}"
             fi
             sed -i '/^\[Resolve\]/a DNS=1.1.1.1 9.9.9.9' /etc/systemd/resolved.conf
             sed -i '/^DNS=/!b;n;s/.*/DNS=1.1.1.1 9.9.9.9/' /etc/systemd/resolved.conf
             sed -i '/FallbackDNS=/c\FallbackDNS=9.9.9.9 1.1.1.1' /etc/systemd/resolved.conf
             sed -i '/^FallbackDNS=/!b;n;s/.*/FallbackDNS=9.9.9.9 1.1.1.1/' /etc/systemd/resolved.conf
             if ! grep -q "^FallbackDNS=" /etc/systemd/resolved.conf; then
                 sed -i '/^\[Resolve\]/a FallbackDNS=9.9.9.9 1.1.1.1' /etc/systemd/resolved.conf
             fi
             sed -i 's/^#DNSSEC=/DNSSEC=/' /etc/systemd/resolved.conf
             sed -i 's/^#DNSOverTLS=/DNSOverTLS=/' /etc/systemd/resolved.conf
             systemctl reload-or-restart systemd-resolved
             echo -e "${green}systemd-resolved 配置已更新并重启。${none}"
        fi
    fi
elif command -v nmcli &> /dev/null; then
    echo -e "${yellow}检测到 NetworkManager，您可能需要手动配置其 DNS 功能。${none}"
else
    echo -e "${green}/etc/resolv.conf 已更新为新 DNS 配置。${none}"
fi

echo "---------- 打开BBR并执行TCP调优脚本 ----------"
echo -e "$yellow开始TCP调优脚本...$none"
echo "----------------------------------------------------------------"
if curl -sSL https://github.com/rrkai/1keyvr/raw/main/tcp.sh | bash; then
    echo -e "${green}TCP 优化 (BBR) 成功。$none"
else
    echo -e "${red}警告: 外部 TCP 优化 (BBR) 脚本执行失败。$none"
fi

echo "----------------------------------------------------------------"
echo -e "$yellow配置 VLESS_Reality 模式$none"
echo "----------------------------------------------------------------"

# 网络栈
if [[ -z $netstack ]]; then
  echo
  echo -e "如果你的小鸡是${magenta}双栈(同时有IPv4和IPv6的IP)${none}，请选择你把Xray搭在哪个'网口'上"
  echo "如果你不懂这段话是什么意思, 请直接回车"
  read -p "$(echo -e "Input ${cyan}4${none} for IPv4, ${cyan}6${none} for IPv6:") " netstack

  if [[ $netstack == "4" ]]; then
    ip=${IPv4}
  elif [[ $netstack == "6" ]]; then
    ip=${IPv6}
  else
    if [[ -n "$IPv4" ]]; then
      ip=${IPv4}
      netstack=4
    elif [[ -n "$IPv6" ]]; then
      ip=${IPv6}
      netstack=6
    else
      warn "没有获取到公共IP"
    fi
  fi
fi

# 端口
if [[ -z $port ]]; then
  default_port=11443
  while :; do
    read -p "$(echo -e "请输入端口 [${magenta}1-65535${none}] Input port (默认Default ${cyan}${default_port}$none):")" port
    [ -z "$port" ] && port=$default_port
    case $port in
    [1-9] | [1-9][0-9] | [1-9][0-9][0-9] | [1-9][0-9][0-9][0-9] | [1-5][0-9][0-9][0-9][0-9] | 6[0-4][0-9][0-9][0-9] | 65[0-4][0-9][0-9] | 655[0-3][0-5])
      echo
      echo -e "$yellow 端口 (Port) = ${cyan}${port}${none}"
      echo "----------------------------------------------------------------"
      break
      ;;
    *)
      error
      ;;
    esac
  done
fi

# Xray UUID
if [[ -z $uuid ]]; then
  while :; do
    echo -e "请输入 "$yellow"UUID"$none" "
    read -p "$(echo -e "(默认ID: ${cyan}${default_uuid}$none):")" uuid
    [ -z "$uuid" ] && uuid=$default_uuid
    case $(echo -n $uuid | sed -E 's/[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}//g') in
    "")
        echo
        echo -e "$yellow UUID = $cyan$uuid$none"
        echo "----------------------------------------------------------------"
        break
        ;;
    *)
        error
        ;;
    esac
  done
fi

# x25519公私钥
if [[ -z $private_key ]]; then
  # 私钥种子
  reality_key_seed=$(echo -n ${uuid} | md5sum | head -c 32 | base64 -w 0 | tr '+/' '-_' | tr -d '=')

  # 生成默认私钥公钥 (适配最新版Xray输出格式)
  tmp_key=$(echo -n "${reality_key_seed}" | xargs xray x25519 -i)
  default_private_key=$(echo "$tmp_key" | grep -iE 'Private' | awk '{print $NF}')
  default_public_key=$(echo "$tmp_key" | grep -iE 'Public|Password' | awk '{print $NF}')
  
  echo -e "请输入 "$yellow"x25519 Private Key"$none" x25519私钥 :"
  read -p "$(echo -e "(默认私钥 Private Key: ${cyan}${default_private_key}$none):")" private_key
  if [[ -z "$private_key" ]]; then 
    private_key=$default_private_key
    public_key=$default_public_key
  else
    tmp_key=$(echo -n "${private_key}" | xargs xray x25519 -i)
    private_key=$(echo "$tmp_key" | grep -iE 'Private' | awk '{print $NF}')
    public_key=$(echo "$tmp_key" | grep -iE 'Public|Password' | awk '{print $NF}')
  fi

  echo
  echo -e "$yellow 私钥 (PrivateKey) = ${cyan}${private_key}$none"
  echo -e "$yellow 公钥 (PublicKey) = ${cyan}${public_key}$none"
  echo "----------------------------------------------------------------"
fi

# ShortID
if [[ -z $shortid ]]; then
  default_shortid=$(printf "%x" $(date +%m))$(openssl rand -hex 4 | cut -c 1-7)
  while :; do
    echo -e "请输入 "$yellow"ShortID"$none" :"
    read -p "$(echo -e "(默认ShortID: ${cyan}${default_shortid}$none):")" shortid
    [ -z "$shortid" ] && shortid=$default_shortid
    if [[ ${#shortid} -gt 16 ]]; then
      error
      continue
    elif [[ $(( ${#shortid} % 2 )) -ne 0 ]]; then
      error
      continue
    else
      echo
      echo -e "$yellow ShortID = ${cyan}${shortid}$none"
      echo "----------------------------------------------------------------"
      break
    fi
  done
fi

# 目标网站
if [[ -z $domain ]]; then
  echo -e "请输入一个 ${magenta}合适的域名${none} Input the domain"
  read -p "(例如: www.overstock.com): " domain
  [ -z "$domain" ] && domain="www.overstock.com"

  echo
  echo -e "$yellow SNI = ${cyan}$domain$none"
  echo "----------------------------------------------------------------"
fi

# 配置config.json
echo -e "$yellow配置 /usr/local/etc/xray/config.json $none"
echo "----------------------------------------------------------------"
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
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv6"
        },
        "tag": "force-ipv6"
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
      "2001:4860:4860::8888",
      "2606:4700:4700::1111",
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

# 重启 Xray
echo -e "$yellow重启 Xray$none"
echo "----------------------------------------------------------------"
service xray restart

# 指纹FingerPrint
fingerprint="safari"

# SpiderX
spiderx=""

echo
echo "---------- Xray 配置信息 -------------"
echo -e "$green ---提示..这是 VLESS Reality 服务器配置--- $none"
echo -e "$yellow 地址 (Address) = $cyan${ip}$none"
echo -e "$yellow 端口 (Port) = ${cyan}${port}${none}"
echo -e "$yellow 用户ID (User ID / UUID) = $cyan${uuid}$none"
echo -e "$yellow 流控 (Flow) = ${cyan}xtls-rprx-vision${none}"
echo -e "$yellow 加密 (Encryption) = ${cyan}none${none}"
echo -e "$yellow 传输协议 (Network) = ${cyan}tcp$none"
echo -e "$yellow 伪装类型 (header type) = ${cyan}none$none"
echo -e "$yellow 底层传输安全 (TLS) = ${cyan}reality$none"
echo -e "$yellow SNI = ${cyan}${domain}$none"
echo -e "$yellow 指纹 (Fingerprint) = ${cyan}${fingerprint}$none"
echo -e "$yellow 公钥 (PublicKey) = ${cyan}${public_key}$none"
echo -e "$yellow ShortId = ${cyan}${shortid}$none"
echo -e "$yellow SpiderX = ${cyan}${spiderx}$none"
echo "---------- END -------------"
echo
echo "---------- 以下是节点链接 ----------"
echo
if [[ $netstack == "6" ]]; then
  ip=[$ip]
fi
vless_reality_url="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}&spx=${spiderx}&#VLESS_R_${ip}"
vless_reality_url_encoded=$(echo "$vless_reality_url" | sed 's/#/%23/g')
echo -e "${cyan}${vless_reality_url}${none}"
echo
echo "---------- 以上是节点链接 ----------"
echo $vless_reality_url > ~/_vless_reality_url_

# ---------- 新增: 设置永久性快捷键 1keyvr ----------
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
else
    echo -e "${green} 检测到 '1keyvr' 别名已存在于 $CONFIG_FILE${none}"
fi

source "$CONFIG_FILE" > /dev/null 2>&1 || true

echo -e "$green DNS 优化完成，主 DNS: 1.1.1.1, 副 DNS: 9.9.9.9 $none"
echo -e "$green 秒级设置SWAP虚拟内存(${FINAL_SWAP_SIZE_MB}MB)完成，TCP参数微调优完成。 $none" 
echo -e "$green 快捷键设置完成！现在您可以直接在终端输入 '1keyvr' 来查看节点信息。$none"
echo "----------------------------------------------------------------"
echo
