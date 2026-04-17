#!/bin/bash

# ==========================================
# 颜色定义
# ==========================================
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
none="\033[0m"

# 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "${red}错误: 请使用 root 权限运行此脚本。${none}"
   exit 1
fi

echo -e "${green}=== 开始优化系统配置 ===${none}"

# ==========================================
# 1. 自动设置 1GB Swap (强制覆盖现有配置)
# ==========================================
echo -e "${green}--- [1/3] 配置 1GB Swap 空间 ---${none}"
SWAP_FILE="/swapfile"
SWAP_SIZE="1G"

# 如果 Swap 正在使用，先关闭它
if swapon --show | grep -q "$SWAP_FILE"; then
    echo -e "${yellow}检测到 Swap ($SWAP_FILE) 正在运行，正在关闭...${none}"
    swapoff "$SWAP_FILE"
fi

# 如果文件已存在，直接删除以便重新创建（覆盖）
if [ -f "$SWAP_FILE" ]; then
    echo -e "${yellow}检测到旧的 Swap 文件，正在删除并准备重新创建...${none}"
    rm -f "$SWAP_FILE"
fi

echo -e "${green}正在创建 $SWAP_SIZE 的 Swap 文件...${none}"
# 优先使用 fallocate 预分配空间（速度快），如果文件系统不支持则降级使用 dd
fallocate -l $SWAP_SIZE $SWAP_FILE || dd if=/dev/zero of=$SWAP_FILE bs=1M count=1024 status=progress

# 设置安全权限并格式化为 Swap
chmod 600 $SWAP_FILE
mkswap $SWAP_FILE
swapon $SWAP_FILE

# 写入 fstab 实现开机自动挂载持久化
if ! grep -q "$SWAP_FILE" /etc/fstab; then
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    echo -e "${green}已将 Swap 配置写入 /etc/fstab 实现持久化。${none}"
fi
echo -e "${green}Swap 重新创建并启用成功。${none}"

# ==========================================
# 2. 设置时区为 UTC 并安装/开启系统时间同步
# ==========================================
echo -e "${green}--- [2/3] 配置时区和 systemd-timesyncd ---${none}"

echo -e "${green}正在将时区设置为 UTC...${none}"
timedatectl set-timezone UTC

# 检查 systemd-timesyncd 是否安装，未安装则使用 apt 安装
if ! command -v systemd-timesyncd &> /dev/null && ! dpkg -s systemd-timesyncd &> /dev/null; then
    echo -e "${yellow}未检测到 systemd-timesyncd 服务，正在尝试通过 apt 安装...${none}"
    apt-get update -y && apt-get install -y systemd-timesyncd
fi

echo -e "${green}正在启用并启动 NTP 时间同步...${none}"
timedatectl set-ntp true
systemctl enable --now systemd-timesyncd
systemctl restart systemd-timesyncd
echo -e "${green}时区已成功设置为 UTC，并已开启系统时间同步。${none}"

# ==========================================
# 3. 优化 DNS 配置
# ==========================================
echo -e "${green}--- [3/3] 配置 DNS 服务 ---${none}"

# 如果没有备份，先备份原文件
if [[ ! -f /etc/resolv.conf.bak ]]; then
    cp /etc/resolv.conf /etc/resolv.conf.bak
    echo -e "${green}已备份原 /etc/resolv.conf 到 /etc/resolv.conf.bak${none}"
else
    echo -e "${yellow}/etc/resolv.conf.bak 已存在。${none}"
fi

# 清空 /etc/resolv.conf 并写入新的 DNS 配置
cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF
echo -e "${green}已清空 /etc/resolv.conf 并设置新的 DNS: 1.1.1.1, 9.9.9.9${none}"

# 尝试检查并处理 systemd-resolved 等可能覆盖配置的服务
if command -v systemctl &> /dev/null && systemctl is-active --quiet systemd-resolved; then
    echo -e "${yellow}检测到 systemd-resolved 服务正在运行，可能会影响 /etc/resolv.conf 的持久性。${none}"
    echo -e "${yellow}建议检查 /etc/systemd/resolved.conf 或相关网络配置。${none}"
    
    # 创建 /etc/resolv.conf 的符号链接以实现持久化
    if [[ ! -L /etc/resolv.conf ]] && [[ -f /run/systemd/resolve/resolv.conf ]]; then
        echo -e "${green}正在将 /etc/resolv.conf 配置为指向 systemd-resolved 的配置文件...${none}"
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi

    # 然后修改 systemd-resolved 的配置
    if [[ -f /etc/systemd/resolved.conf ]]; then
         # 备份 resolved.conf
         if [[ ! -f /etc/systemd/resolved.conf.bak ]]; then
             cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak
             echo -e "${green}已备份原 /etc/systemd/resolved.conf 到 /etc/systemd/resolved.conf.bak${none}"
         fi
         
         # 先删除旧的 DNS/FallbackDNS 行，防止脚本重复运行导致数据不断累加
         sed -i '/^DNS=/d' /etc/systemd/resolved.conf
         sed -i '/^FallbackDNS=/d' /etc/systemd/resolved.conf
         
         # 在 [Resolve] 块下直接追加配置
         sed -i '/^\[Resolve\]/a DNS=1.1.1.1 9.9.9.9\nFallbackDNS=9.9.9.9 1.1.1.1' /etc/systemd/resolved.conf
         
         # 启用 DNSSEC 和 DNSOverTLS
         sed -i 's/^#*DNSSEC=.*/DNSSEC=yes/' /etc/systemd/resolved.conf
         sed -i 's/^#*DNSOverTLS=.*/DNSOverTLS=yes/' /etc/systemd/resolved.conf
       
         # 重启服务使配置生效
         systemctl reload-or-restart systemd-resolved
         echo -e "${green}systemd-resolved 配置已更新并重启。${none}"
    fi
elif command -v nmcli &> /dev/null; then
    # 如果使用 NetworkManager，它也可能管理 DNS
    echo -e "${yellow}检测到 NetworkManager，可能会影响 /etc/resolv.conf 的持久性。${none}"
    echo -e "${yellow}您可能需要通过 NetworkManager 配置 DNS 或禁用其 DNS 管理功能。${none}"
else
    echo -e "${green}/etc/resolv.conf 已更新为新 DNS 配置。${none}"
fi

echo -e "${green}=== 所有系统优化配置执行完毕 ===${none}"
