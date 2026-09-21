#!/bin/bash

# 颜色代码
GREEN="\033[32m"
PINK="\033[35m"
RESET="\033[0m"

# 检测是否为 Alpine Linux
if ! grep -qi "alpine" /etc/os-release; then
    echo -e "${PINK}不支持此操作，当前系统不是 Alpine Linux。${RESET}"
    exit 1
fi

# 安装必要依赖组件（含 iptables/ip6tables 持久化组件与运行依赖）
install_dependencies() {
    echo -e "${GREEN}正在更新软件源并安装依赖组件...${RESET}"
    if ! apk update && apk add --no-cache curl socat wget iptables ip6tables bash nano tzdata ca-certificates; then
        echo -e "${PINK}安装组件失败，请检查网络设置。${RESET}"
        exit 1
    fi
}

# 生成随机 Gmail 邮箱地址
generate_random_email() {
    local length=10
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local email=""
    for i in $(seq 1 $length); do
        email+="${chars:RANDOM%${#chars}:1}"
    done
    echo "${email}@gmail.com"
}

# 配置 OpenRC 服务
setup_openrc_service() {
    cat > /etc/init.d/hysteria-server << 'EOF'
#!/sbin/openrc-run

name="hysteria-server"
description="Hysteria 2 Server Service"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.err"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/hysteria-server
}

# 配置定时自动检查更新
setup_auto_update() {
    echo -e "${GREEN}配置每周自动更新任务...${RESET}"
    rc-update add crond default >/dev/null 2>&1
    rc-service crond start >/dev/null 2>&1

    cat > /usr/local/bin/hy2-autoupdate.sh << 'EOF'
#!/bin/bash
bash <(curl -fsSL https://get.hy2.sh/)
rc-service hysteria-server restart
EOF
    chmod +x /usr/local/bin/hy2-autoupdate.sh

    # 每周一凌晨 3:30 自动检查并更新二进制文件
    if ! crontab -l 2>/dev/null | grep -q "hy2-autoupdate.sh"; then
        (crontab -l 2>/dev/null; echo "30 3 * * 1 /usr/local/bin/hy2-autoupdate.sh >/dev/null 2>&1") | crontab -
    fi
}

# 主菜单循环
while true; do
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}      Hysteria 2 - Alpine Linux     ${RESET}"
    echo -e "${GREEN}====================================${RESET}"
    echo -e "${GREEN}1) 域名证书安装 Hysteria${RESET}"
    echo -e "${GREEN}2) 修改 Hysteria 配置${RESET}"
    echo -e "${GREEN}3) 输出当前 Hysteria 配置${RESET}"
    echo -e "${GREEN}4) 查看 Hysteria 运行状态${RESET}"
    echo -e "${GREEN}5) 重启 Hysteria${RESET}"
    echo -e "${GREEN}6) 停止 Hysteria${RESET}"
    echo -e "${GREEN}7) 查看 Hysteria 日志${RESET}"
    echo -e "${GREEN}8) 立即更新 Hysteria 核心${RESET}"
    echo -e "${GREEN}9) 卸载 Hysteria${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e "${PINK}请输入选项 (0-9): ${RESET}")" option

    case $option in
        1)
            install_dependencies
            random_email=$(generate_random_email)

            read -p "$(echo -e "${PINK}输入解析好的域名 (例如 ${GREEN}example.com${RESET}): ${RESET}")" domain
            echo -e "${GREEN}随机生成的邮箱地址为: ${PINK}${random_email}${RESET}"

            read -p "$(echo -e "${PINK}输入自定义端口 (例如 ${GREEN}9443${RESET}): ${RESET}")" port

            read -sp "$(echo -e "${PINK}输入您希望的密码 (输入将被隐藏): ${RESET}")" password
            echo

            # 下载官方二进制程序
            echo -e "${GREEN}正在下载并安装 Hysteria...${RESET}"
            if ! bash <(curl -fsSL https://get.hy2.sh/); then
                echo -e "${PINK}安装 Hysteria 失败，退出中...${RESET}"
                exit 1
            fi

            # 注册 OpenRC 服务
            setup_openrc_service
            rc-update add hysteria-server default

            # 生成配置文件
            mkdir -p /etc/hysteria
            echo -e "${GREEN}正在写入配置到 /etc/hysteria/config.yaml...${RESET}"
            cat > /etc/hysteria/config.yaml <<EOF
listen: :$port

acme:
  domains:
    - $domain
  email: $random_email

auth:
  type: password
  password: $password

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

resolver:
  type: udp
  udp:
    addr: 8.8.8.8:53

sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false
  tcpPorts: 80,443,20000-40000
  udpPorts: all

outbounds:
  - name: v4_prefer
    type: direct
    direct:
      mode: 46
  - name: v4
    type: direct
    direct:
      mode: 4
  - name: v6
    type: direct
    direct:
      mode: 6
acl:
  inline:
    - v4_prefer(all)
EOF

            echo -e "${GREEN}Hysteria 配置已写入到 /etc/hysteria/config.yaml${RESET}"

            # 检测网卡
            NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -E "eth|ens" | head -n 1)

            if [ -z "$NIC" ]; then
                echo -e "${PINK}未能自动获取网卡名称，跳过端口跳跃配置。${RESET}"
            else
                echo -e "${GREEN}检测到的网卡名称为: $NIC${RESET}"

                read -p "$(echo -e "${PINK}请输入跳跃端口范围的起始端口 (例如 20000): ${RESET}")" START_PORT
                read -p "$(echo -e "${PINK}请输入跳跃端口范围的结束端口 (例如 40000): ${RESET}")" END_PORT
                read -p "$(echo -e "${PINK}请输入目标端口 (例如 9443): ${RESET}")" TARGET_PORT

                if [[ ! "$START_PORT" =~ ^[0-9]+$ || ! "$END_PORT" =~ ^[0-9]+$ || ! "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
                    echo -e "${PINK}输入无效，端口必须为数字。${RESET}"
                    exit 1
                fi

                if [[ "$START_PORT" -ge "$END_PORT" ]]; then
                    echo -e "${PINK}起始端口必须小于结束端口。${RESET}"
                    exit 1
                fi

                # 清除旧规则
                echo "清除已有的端口跳跃规则..."
                iptables -t nat -D PREROUTING -i "$NIC" -p udp --dport "$START_PORT:$END_PORT" -j DNAT --to-destination :"$TARGET_PORT" 2>/dev/null
                ip6tables -t nat -D PREROUTING -i "$NIC" -p udp --dport "$START_PORT:$END_PORT" -j DNAT --to-destination :"$TARGET_PORT" 2>/dev/null

                # 设置 IPv4 与 IPv6 规则
                echo "设置端口跳跃规则 ($START_PORT-$END_PORT -> $TARGET_PORT)..."
                iptables -t nat -A PREROUTING -i "$NIC" -p udp --dport "$START_PORT:$END_PORT" -j DNAT --to-destination :"$TARGET_PORT"
                ip6tables -t nat -A PREROUTING -i "$NIC" -p udp --dport "$START_PORT:$END_PORT" -j DNAT --to-destination :"$TARGET_PORT" 2>/dev/null

                # 保存 Alpine 防火墙规则并设为开机加载
                echo "保存 iptables 规则..."
                rc-service iptables save 2>/dev/null
                rc-service ip6tables save 2>/dev/null
                rc-update add iptables default 2>/dev/null
                rc-update add ip6tables default 2>/dev/null

                echo -e "${GREEN}端口跳跃规则已成功设置并持久化。${RESET}"
            fi

            # 配置自动更新
            setup_auto_update

            # 启动服务
            echo -e "${GREEN}启动 hysteria-server 服务...${RESET}"
            rc-service hysteria-server start

            # 检查服务状态
            if ! rc-service hysteria-server status | grep -q "started"; then
                echo -e "${PINK}Hysteria 服务未能成功启动。请检查配置或日志 (/var/log/hysteria.err)。${RESET}"
                exit 1
            fi

            echo -e "${GREEN}Hysteria 服务已成功启动！${RESET}"
            ;;

        2)
            echo -e "${GREEN}正在编辑 Hysteria 配置...${RESET}"
            nano /etc/hysteria/config.yaml

            echo -e "${GREEN}修改已保存，重启 Hysteria 服务...${RESET}"
            rc-service hysteria-server restart
            echo -e "${GREEN}Hysteria 服务已重启！${RESET}"
            ;;

        3)
            echo -e "${GREEN}当前 Hysteria 配置: ${RESET}"
            cat /etc/hysteria/config.yaml
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        4)
            echo -e "${GREEN}Hysteria 服务状态: ${RESET}"
            rc-service hysteria-server status
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        5)
            echo -e "${GREEN}重启 Hysteria 服务...${RESET}"
            rc-service hysteria-server restart
            echo -e "${GREEN}Hysteria 服务已重启！${RESET}"
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        6)
            echo -e "${GREEN}停止 Hysteria 服务...${RESET}"
            rc-service hysteria-server stop
            echo -e "${GREEN}Hysteria 服务已停止！${RESET}"
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        7)
            echo -e "${GREEN}查看 Hysteria 日志 (按 Ctrl+C 退出日志查看)...${RESET}"
            tail -n 50 -f /var/log/hysteria.log /var/log/hysteria.err 2>/dev/null
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        8)
            echo -e "${GREEN}正在检查并更新 Hysteria 核心...${RESET}"
            bash <(curl -fsSL https://get.hy2.sh/)
            rc-service hysteria-server restart
            echo -e "${GREEN}更新完成，服务已重启！${RESET}"
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        9)
            echo -e "${PINK}正在卸载 Hysteria...${RESET}"
            rc-service hysteria-server stop 2>/dev/null
            rc-update del hysteria-server default 2>/dev/null
            rm -f /etc/init.d/hysteria-server
            rm -rf /etc/hysteria/
            rm -f /usr/local/bin/hysteria
            rm -f /usr/local/bin/hy2-autoupdate.sh
            rm -f /var/log/hysteria.log /var/log/hysteria.err
            crontab -l 2>/dev/null | grep -v "hy2-autoupdate.sh" | crontab -
            echo -e "${GREEN}Hysteria 已成功完全卸载！${RESET}"
            echo -e "${GREEN}按任意键返回主菜单...${RESET}"
            read -n 1 -s
            ;;

        0)
            echo -e "${GREEN}退出...${RESET}"
            exit 0
            ;;

        *)
            echo -e "${PINK}无效选项，请输入 0 到 9 的数字。${RESET}"
            sleep 1
            ;;
    esac
done
