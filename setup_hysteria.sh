#!/bin/bash

# 颜色代码
GREEN="\e[32m"   # 绿色
PINK="\e[35m"    # 粉色
RESET="\e[0m"    # 重置颜色

# 选择操作
echo -e "${GREEN}请选择操作:${RESET}"
echo -e "${GREEN}1) 安装域名证书并设置 Hysteria${RESET}"
echo -e "${GREEN}2) 修改 Hysteria 配置文件${RESET}"
echo -e "${GREEN}3) 输出当前 Hysteria 配置内容${RESET}"
echo -e "${GREEN}4) 查看 Hysteria 运行状态${RESET}"
echo -e "${GREEN}5) 重启 Hysteria${RESET}"
echo -e "${GREEN}6) 停止 Hysteria${RESET}"
echo -e "${GREEN}7) 查看 Hysteria 日志${RESET}"
echo -e "${GREEN}8) 卸载 Hysteria${RESET}"

# 提示用户输入选项
read -p "$(echo -e "${PINK}请输入选项 (1-8): ${RESET}")" option

if [[ $option -eq 1 ]]; then
    # 提示用户输入解析好的域名、邮箱地址和自定义端口
    read -p "$(echo -e "${PINK}Enter your resolved domain (e.g., ${GREEN}example.com${RESET}): ${RESET}")" domain
    read -p "$(echo -e "${PINK}Enter your email address (e.g., ${GREEN}user@example.com${RESET}): ${RESET}")" email
    read -p "$(echo -e "${PINK}Enter the custom port (e.g., ${GREEN}9443${RESET}): ${RESET}")" port

    # 提示用户输入 UDP 转发的端口范围
    read -p "$(echo -e "${PINK}Enter the starting UDP port for forwarding (e.g., ${GREEN}20000${RESET}): ${RESET}")" start_port
    read -p "$(echo -e "${PINK}Enter the ending UDP port for forwarding (e.g., ${GREEN}40000${RESET}): ${RESET}")" end_port

    # 提示用户输入自定义密码
    read -sp "$(echo -e "${PINK}Enter your desired password (input will be hidden): ${RESET}")" password
    echo # 这一行用于换行

    # 下载并安装 Hysteria
    echo "Downloading and installing Hysteria..."
    if ! bash <(curl -fsSL https://get.hy2.sh/); then
        echo "Failed to install Hysteria. Exiting."
        exit 1
    fi

    # 启用 hysteria-server 服务
    echo "Enabling hysteria-server service..."
    if ! systemctl enable hysteria-server.service; then
        echo "Failed to enable hysteria-server service. Exiting."
        exit 1
    fi

    # 创建/覆盖配置文件 config.yaml
    echo "Writing configuration to /etc/hysteria/config.yaml..."
    cat > /etc/hysteria/config.yaml <<EOF
listen: :$port                        #端口自定义

acme:                                #域名证书 
  domains:
    - $domain                        #用户输入的解析好的域名
  email: $email                      #用户输入的邮箱地址

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
    echo "Hysteria configuration written to /etc/hysteria/config.yaml with domain: $domain, email: $email, port: $port, and password: [REDACTED]"

    # 检查并安装 iptables-persistent
    echo "Installing iptables-persistent..."
    if ! apt update && apt install -y iptables-persistent; then
        echo "Failed to install iptables-persistent. Exiting."
        exit 1
    fi

    # 获取第一个非回环接口的名称
    interface=$(ip a | grep -oP '^\d+: \K[^:]+(?=:)')
    if [ -z "$interface" ]; then
        echo "No network interface found. Exiting."
        exit 1
    fi

    echo "Using interface: $interface"

    # 设置 IPv4 的端口跳跃
    echo "Setting up port forwarding for IPv4..."
    if ! iptables -t nat -A PREROUTING -i "$interface" -p udp --dport $start_port:$end_port -j DNAT --to-destination :$port; then
        echo "Failed to set up IPv4 port forwarding. Exiting."
        exit 1
    fi

    # 设置 IPv6 的端口跳跃
    echo "Setting up port forwarding for IPv6..."
    if ! ip6tables -t nat -A PREROUTING -i "$interface" -p udp --dport $start_port:$end_port -j DNAT --to-destination :$port; then
        echo "Failed to set up IPv6 port forwarding. Exiting."
        exit 1
    fi

    # 保存 iptables 规则
    echo "Saving iptables rules..."
    if ! netfilter-persistent save; then
        echo "Failed to save iptables rules. Exiting."
        exit 1
    fi

    # 启动 Hysteria 服务
    echo "Starting hysteria-server service..."
    if ! systemctl start hysteria-server.service; then
        echo "Failed to start hysteria-server service. Exiting."
        exit 1
    fi

    # 检查 Hysteria 服务状态
    echo "Checking hysteria-server service status..."
    if ! systemctl status hysteria-server.service; then
        echo "Hysteria-server service is not running. Exiting."
        exit 1
    fi

    # 输出配置文件内容
    echo "Displaying the configuration file contents:"
    cat /etc/hysteria/config.yaml

    # 提示用户完成
    echo "Port forwarding setup completed."
    echo "Script execution completed."

elif [[ $option -eq 2 ]]; then
    # 提示用户输入新的配置内容
    echo "Enter the path to the Hysteria config file (default: /etc/hysteria/config.yaml):"
    read -p "$(echo -e "${PINK}Enter path: ${RESET}")" config_path
    config_path=${config_path:-/etc/hysteria/config.yaml}

    # 检查文件是否存在
    if [[ ! -f "$config_path" ]]; then
        echo "Configuration file not found: $config_path. Exiting."
        exit 1
    fi

    # 提示用户输入新的配置内容
    echo "Updating the Hysteria configuration..."
    read -p "$(echo -e "${PINK}Enter the new listen port (e.g., ${GREEN}9443${RESET}): ${RESET}")" new_port
    read -p "$(echo -e "${PINK}Enter the new domain (e.g., ${GREEN}example.com${RESET}): ${RESET}")" new_domain
    read -p "$(echo -e "${PINK}Enter the new email address (e.g., ${GREEN}user@example.com${RESET}): ${RESET}")" new_email
    read -sp "$(echo -e "${PINK}Enter the new password (input will be hidden): ${RESET}")" new_password
    echo # 这一行用于换行

    # 更新配置文件
    echo "Updating configuration in $config_path..."
    sed -i.bak -e "s/listen: .*$/listen: :$new_port/" \
                -e "s/    - .*/    - $new_domain/" \
                -e "s/email: .*/email: $new_email/" \
                -e "s/password: .*/password: $new_password/" "$config_path"

    echo "Configuration updated successfully."
    echo "New configuration:"
    cat "$config_path"

elif [[ $option -eq 3 ]]; then
    # 输出当前 Hysteria 配置内容
    echo "Displaying current Hysteria configuration..."
    config_path="/etc/hysteria/config.yaml"

    # 检查文件是否存在
    if [[ ! -f "$config_path" ]]; then
        echo "Configuration file not found: $config_path. Exiting."
        exit 1
    fi

    # 输出配置文件内容
    cat "$config_path"

elif [[ $option -eq 4 ]]; then
    # 查看 Hysteria 运行状态
    echo "Checking hysteria-server service status..."
    systemctl status hysteria-server.service

elif [[ $option -eq 5 ]]; then
    # 重启 Hysteria
    echo "Restarting hysteria-server service..."
    if ! systemctl restart hysteria-server.service; then
        echo "Failed to restart hysteria-server service. Exiting."
        exit 1
    fi
    echo "Hysteria-server service restarted successfully."

elif [[ $option -eq 6 ]]; then
    # 停止 Hysteria
    echo "Stopping hysteria-server service..."
    if ! systemctl stop hysteria-server.service; then
        echo "Failed to stop hysteria-server service. Exiting."
        exit 1
    fi
    echo "Hysteria-server service stopped successfully."

elif [[ $option -eq 7 ]]; then
    # 查看 Hysteria 运行日志
    echo "Displaying hysteria-server logs..."
    journalctl -u hysteria-server.service

elif [[ $option -eq 8 ]]; then
    # 卸载 Hysteria
    echo "Uninstalling Hysteria..."
    if ! apt remove -y hysteria; then
        echo "Failed to uninstall Hysteria. Exiting."
        exit 1
    fi
    echo "Hysteria uninstalled successfully."

else
    echo "Invalid option selected. Exiting."
    exit 1
fi
