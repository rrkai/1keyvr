if [[ ! -f /etc/resolv.conf.bak ]]; then
    # 如果没有备份，先备份原文件
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

# 尝试检查并处理 systemd-resolved 或 NetworkManager 等可能覆盖 /etc/resolv.conf 的服务
if command -v systemctl &> /dev/null && systemctl is-active --quiet systemd-resolved; then
    echo -e "${yellow}检测到 systemd-resolved 服务正在运行，可能会影响 /etc/resolv.conf 的持久性。${none}"
    echo -e "${yellow}建议检查 /etc/systemd/resolved.conf 或相关网络配置。${none}"
    # 创建 /etc/resolv.conf 的符号链接到 systemd-resolved 提供的文件，以实现持久化
    if [[ ! -L /etc/resolv.conf ]] && [[ -f /run/systemd/resolve/resolv.conf ]]; then
        echo -e "${green}正在将 /etc/resolv.conf 配置为指向 systemd-resolved 的配置文件...${none}"
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        # 然后修改 systemd-resolved 的配置
        if [[ -f /etc/systemd/resolved.conf ]]; then
             # 备份 resolved.conf
             if [[ ! -f /etc/systemd/resolved.conf.bak ]]; then
                 cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak
                 echo -e "${green}已备份原 /etc/systemd/resolved.conf 到 /etc/systemd/resolved.conf.bak${none}"
             fi
             # 修改 DNS 和 FallbackDNS
             sed -i '/^\[Resolve\]/a DNS=1.1.1.1 9.9.9.9' /etc/systemd/resolved.conf
             sed -i '/^DNS=/!b;n;s/.*/DNS=1.1.1.1 9.9.9.9/' /etc/systemd/resolved.conf # 如果上面没匹配到[Resolve]，这行也不会执行
             sed -i '/FallbackDNS=/c\FallbackDNS=9.9.9.9 1.1.1.1' /etc/systemd/resolved.conf
             sed -i '/^FallbackDNS=/!b;n;s/.*/FallbackDNS=9.9.9.9 1.1.1.1/' /etc/systemd/resolved.conf # 如果上面没匹配到FallbackDNS，这行也不会执行
             # 如果没有 FallbackDNS 行，则添加
             if ! grep -q "^FallbackDNS=" /etc/systemd/resolved.conf; then
                 sed -i '/^\[Resolve\]/a FallbackDNS=9.9.9.9 1.1.1.1' /etc/systemd/resolved.conf
             fi
             # 启用 DNSSEC 和 DNSOverTLS (可选，但通常推荐)
             sed -i 's/^#DNSSEC=/DNSSEC=/' /etc/systemd/resolved.conf
             sed -i 's/^#DNSOverTLS=/DNSOverTLS=/' /etc/systemd/resolved.conf
             # 重启服务使配置生效
             systemctl reload-or-restart systemd-resolved
             echo -e "${green}systemd-resolved 配置已更新并重启。${none}"
        fi
    fi
elif command -v nmcli &> /dev/null; then
    # 如果使用 NetworkManager，它也可能管理 DNS
    echo -e "${yellow}检测到 NetworkManager，可能会影响 /etc/resolv.conf 的持久性。${none}"
    echo -e "${yellow}您可能需要通过 NetworkManager 配置 DNS 或禁用其 DNS 管理功能。${none}"
else
    # 如果没有检测到常见的 DNS 管理服务，写入 /etc/resolv.conf 通常是持久的
    echo -e "${green}/etc/resolv.conf 已更新为新 DNS 配置。${none}"
fi
