set -e

# 1. 备份 sysctl.conf
BACKUP_FILE="/etc/sysctl.conf.bk_$(date +%Y%m%d_%H%M%S)"
echo "[+] 备份 sysctl.conf 到 $BACKUP_FILE"
sudo cp /etc/sysctl.conf "$BACKUP_FILE"

# 2. 写入优化参数
echo "[+] 写入优化参数..."
sudo tee /etc/sysctl.conf > /dev/null <<EOF
# 使用 BBR 拥塞控制（快速起速）
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 增加缓冲区大小（保证高带宽）
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.netdev_max_backlog=300000

# TCP 内存优化（三档：最小值/默认值/最大值）
net.ipv4.tcp_rmem=4096 131072 134217728
net.ipv4.tcp_wmem=4096 131072 134217728

# 提高文件描述符限制
fs.file-max=2097152

# TIME-WAIT 优化（减少延迟连接残留）
net.ipv4.tcp_tw_reuse=1

# 启用 TCP Fast Open（减少握手延迟）
net.ipv4.tcp_fastopen=3

# 启用 TCP 窗口自动调节
net.ipv4.tcp_window_scaling=1

# 减少 SYN 队列丢包
net.ipv4.tcp_max_syn_backlog=262144
net.core.somaxconn=65535

# 开启低延迟队列调度
net.ipv4.tcp_low_latency=1

# 提高 ephemeral port 范围
net.ipv4.ip_local_port_range=10240 65535
EOF

# 3. 应用配置
echo "[+] 应用 sysctl 配置..."
sudo sysctl -p

# 4. 验证 BBR 是否启用
echo "[+] 验证 TCP 拥塞控制算法:"
sysctl net.ipv4.tcp_congestion_control
echo "[+] 当前可用算法:"
sysctl net.ipv4.tcp_available_congestion_control

echo "[+] 优化完成！建议测试网络性能: iperf3 或 speedtest-cli"
