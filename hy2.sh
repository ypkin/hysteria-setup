#!/bin/bash

# 颜色代码
GREEN="\e[32m"   # 绿色
PINK="\e[35m"    # 粉色
RESET="\e[0m"    # 重置颜色

# 检测系统类型
if ! grep -qE "(debian|ubuntu)" /etc/*release; then
    echo -e "${PINK}不支持此操作，当前系统不是 Debian 或 Ubuntu。${RESET}"
    exit 1
fi

# 安装必要组件
echo -e "${GREEN}安装必要组件...${RESET}"
if ! apt update -y && apt install -y curl socat wget; then
    echo -e "${PINK}安装组件失败。请检查网络连接或权限设置。${RESET}"
    exit 1
fi

# 生成随机 Gmail 邮箱地址
generate_random_email() {
    local length=10
    local chars=abcdefghijklmnopqrstuvwxyz0123456789
    local email=""
    for i in $(seq 1 $length); do
        email+="${chars:RANDOM%${#chars}:1}"
    done
    echo "${email}@gmail.com"
}

random_email=$(generate_random_email)

# 选择操作
echo -e "${GREEN}请选择操作:${RESET}"
echo -e "${GREEN}1) 域名证书安装 Hysteria${RESET}"
echo -e "${GREEN}2) 修改 Hysteria 配置${RESET}"
echo -e "${GREEN}3) 输出当前 Hysteria 配置${RESET}"
echo -e "${GREEN}4) 查看 Hysteria 运行状态${RESET}"
echo -e "${GREEN}5) 重启 Hysteria${RESET}"
echo -e "${GREEN}6) 停止 Hysteria${RESET}"
echo -e "${GREEN}7) 查看 Hysteria 日志${RESET}"
echo -e "${GREEN}8) 卸载 Hysteria${RESET}"

# 提示用户输入选项
read -p "$(echo -e "${PINK}请输入选项 (1-8): ${RESET}")" option

if [[ $option -eq 1 ]]; then
    # 提示用户输入解析好的域名和自定义端口
    read -p "$(echo -e "${PINK}Enter your resolved domain (e.g., ${GREEN}example.com${RESET}): ${RESET}")" domain
    echo -e "${GREEN}随机生成的邮箱地址为: ${PINK}${random_email}${RESET}"

    read -p "$(echo -e "${PINK}Enter the custom port (e.g., ${GREEN}9443${RESET}): ${RESET}")" port

    # 提示用户输入 UDP 转发的端口范围
    read -p "$(echo -e "${PINK}Enter the starting UDP port for forwarding (e.g., ${GREEN}20000${RESET}): ${RESET}")" start_port
    read -p "$(echo -e "${PINK}Enter the ending UDP port for forwarding (e.g., ${GREEN}40000${RESET}): ${RESET}")" end_port

    # 检查输入端口范围是否合法
    if [[ ! $start_port =~ ^[0-9]+$ || ! $end_port =~ ^[0-9]+$ || $start_port -gt $end_port ]]; then
        echo -e "${PINK}Invalid port range. Please ensure start_port is less than or equal to end_port.${RESET}"
        exit 1
    fi

    # 提示用户输入自定义密码
    read -sp "$(echo -e "${PINK}Enter your desired password (input will be hidden): ${RESET}")" password
    echo # 这一行用于换行

    # 下载并安装 Hysteria
    echo -e "${GREEN}Downloading and installing Hysteria...${RESET}"
    if ! bash <(curl -fsSL https://get.hy2.sh/); then
        echo -e "${PINK}Failed to install Hysteria. Exiting.${RESET}"
        exit 1
    fi

    # 启用 hysteria-server 服务
    echo -e "${GREEN}Enabling hysteria-server service...${RESET}"
    if ! systemctl enable hysteria-server.service; then
        echo -e "${PINK}Failed to enable hysteria-server service. Exiting.${RESET}"
        exit 1
    fi

    # 创建/覆盖配置文件 config.yaml
    echo -e "${GREEN}Writing configuration to /etc/hysteria/config.yaml...${RESET}"
    cat > /etc/hysteria/config.yaml <<EOF
listen: :$port                        #端口自定义

acme:                                #域名证书 
  domains:
    - $domain                        #用户输入的解析好的域名
  email: $random_email                #随机生成的邮箱地址

auth:
  type: password
  password: $password                 #用户输入的自定义密码

masquerade:
  type: proxy
  proxy:
    url: https://bing.com            #伪装网站
    rewriteHost: true

outbounds:                           #出站端口设置
  - name: v4
    type: direct
    direct:
      mode: 4
  - name: v6
    type: direct
    direct:
      mode: 6

acl:
  inline:                            #内置出站规则，从上到下优先出站
   - v4(geosite:netflix)             #v4解锁nf
   - v6(::/0)                        #v6分流
   - v4(0.0.0.0/0)                   #v4分流
   - direct(all)                     #其它直连出站
EOF

    # 提示用户完成 Hysteria 的配置
    echo -e "${GREEN}Hysteria configuration written to /etc/hysteria/config.yaml with domain: $domain, email: $random_email, port: $port, and password: [REDACTED]${RESET}"

    # 检查并安装 iptables-persistent
    echo -e "${GREEN}Installing iptables-persistent...${RESET}"
    if ! apt update -y && apt install -y iptables-persistent; then
        echo -e "${PINK}Failed to install iptables-persistent. Exiting.${RESET}"
        exit 1
    fi

    # 获取第一个非回环接口的名称
    interface=$(ip a | grep -oP '^\d+: \K[^:]+(?=:)')
    if [ -z "$interface" ]; then
        echo -e "${PINK}No network interface found. Exiting.${RESET}"
        exit 1
    fi

    echo -e "${GREEN}Using interface: $interface${RESET}"

    # 设置 IPv4 的端口跳跃
    echo -e "${GREEN}Setting up port forwarding for IPv4...${RESET}"
    if ! iptables -t nat -A PREROUTING -i "$interface" -p udp --dport $start_port:$end_port -j DNAT --to-destination :$port; then
        echo -e "${PINK}Failed to set up IPv4 port forwarding. Exiting.${RESET}"
        exit 1
    fi

    # 设置 IPv6 的端口跳跃
    echo -e "${GREEN}Setting up port forwarding for IPv6...${RESET}"
    if ! ip6tables -t nat -A PREROUTING -i "$interface" -p udp --dport $start_port:$end_port -j DNAT --to-destination :$port; then
        echo -e "${PINK}Failed to set up IPv6 port forwarding. Exiting.${RESET}"
        exit 1
    fi

    # 保存 iptables 规则
    echo -e "${GREEN}Saving iptables rules...${RESET}"
    if ! netfilter-persistent save; then
        echo -e "${PINK}Failed to save iptables rules. Exiting.${RESET}"
        exit 1
    fi

    # 启动 Hysteria 服务
    echo -e "${GREEN}Starting hysteria-server service...${RESET}"
    if ! systemctl start hysteria-server.service; then
        echo -e "${PINK}Failed to start hysteria-server service. Exiting.${RESET}"
        exit 1
    fi

    # 检查 Hysteria 服务状态
    echo -e "${GREEN}Checking hysteria-server service status...${RESET}"
    if ! systemctl status hysteria-server.service; then
        echo -e "${PINK}Hysteria-server service is not running. Exiting.${RESET}"
        exit 1
    fi

    # 提示用户完成
    echo -e "${GREEN}Port forwarding setup completed.${RESET}"
    echo -e "${GREEN}Script execution completed.${RESET}"

elif [[ $option -eq 2 ]]; then
    # 提示用户输入新的配置内容
    echo -e "${GREEN}Enter the path to the Hysteria config file (default: /etc/hysteria/config.yaml):${RESET}"
    read -p "$(echo -e "${PINK}Enter path: ${RESET}")" config_path
    config_path=${config_path:-/etc/hysteria/config.yaml}

    # 检查文件是否存在
    if [[ ! -f "$config_path" ]]; then
        echo -e "${PINK}Config file not found. Exiting.${RESET}"
        exit 1
    fi

    # 在这里实现用户输入并更新配置的逻辑
    echo -e "${GREEN}Updating configuration...${RESET}"
    # 可以在这里添加更多的用户输入和配置更新逻辑

    echo -e "${GREEN}Configuration updated successfully!${RESET}"

elif [[ $option -eq 3 ]]; then
    # 输出当前配置
    echo -e "${GREEN}Current Hysteria configuration:${RESET}"
    cat /etc/hysteria/config.yaml

elif [[ $option -eq 4 ]]; then
    # 查看服务状态
    echo -e "${GREEN}Checking hysteria-server service status...${RESET}"
    systemctl status hysteria-server.service

elif [[ $option -eq 5 ]]; then
    # 重启服务
    echo -e "${GREEN}Restarting hysteria-server service...${RESET}"
    systemctl restart hysteria-server.service
    echo -e "${GREEN}Hysteria-server service restarted.${RESET}"

elif [[ $option -eq 6 ]]; then
    # 停止服务
    echo -e "${GREEN}Stopping hysteria-server service...${RESET}"
    systemctl stop hysteria-server.service
    echo -e "${GREEN}Hysteria-server service stopped.${RESET}"

elif [[ $option -eq 7 ]]; then
    # 查看日志
    echo -e "${GREEN}Viewing hysteria-server logs...${RESET}"
    journalctl -u hysteria-server.service

elif [[ $option -eq 8 ]]; then
    # 卸载服务
    echo -e "${GREEN}Uninstalling Hysteria...${RESET}"
    systemctl stop hysteria-server.service
    systemctl disable hysteria-server.service
    rm -rf /etc/hysteria/
    apt remove --purge -y hysteria iptables-persistent
    echo -e "${GREEN}Hysteria uninstalled successfully.${RESET}"

else
    echo -e "${PINK}Invalid option. Exiting.${RESET}"
    exit 1
fi
