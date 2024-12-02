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
while true; do
    echo -e "${GREEN}请选择操作:${RESET}"
    echo -e "${GREEN}1) 域名证书安装 Hysteria${RESET}"
    echo -e "${GREEN}2) 修改 Hysteria 配置${RESET}"
    echo -e "${GREEN}3) 输出当前 Hysteria 配置${RESET}"
    echo -e "${GREEN}4) 查看 Hysteria 运行状态${RESET}"
    echo -e "${GREEN}5) 重启 Hysteria${RESET}"
    echo -e "${GREEN}6) 停止 Hysteria${RESET}"
    echo -e "${GREEN}7) 查看 Hysteria 日志${RESET}"
    echo -e "${GREEN}8) 卸载 Hysteria${RESET}"
    echo -e "${GREEN}9) 退出${RESET}"

    # 提示用户输入选项
    read -p "$(echo -e "${PINK}请输入选项 (1-9): ${RESET}")" option

    if [[ $option -eq 1 ]]; then
        # 提示用户输入解析好的域名和自定义端口
        read -p "$(echo -e "${PINK}输入解析好的域名 (例如 ${GREEN}example.com${RESET}): ${RESET}")" domain
        echo -e "${GREEN}随机生成的邮箱地址为: ${PINK}${random_email}${RESET}"

        read -p "$(echo -e "${PINK}输入自定义端口 (例如 ${GREEN}9443${RESET}): ${RESET}")" port

        # 提示用户输入自定义密码
        read -sp "$(echo -e "${PINK}输入您希望的密码 (输入将被隐藏): ${RESET}")" password
        echo # 换行

        # 下载并安装 Hysteria
        echo -e "${GREEN}正在下载并安装 Hysteria...${RESET}"
        if ! bash <(curl -fsSL https://get.hy2.sh/); then
            echo -e "${PINK}安装 Hysteria 失败。退出中...${RESET}"
            exit 1
        fi

        # 启用 hysteria-server 服务
        echo -e "${GREEN}启用 hysteria-server 服务...${RESET}"
        if ! systemctl enable hysteria-server.service; then
            echo -e "${PINK}启用 hysteria-server 服务失败。退出中...${RESET}"
            exit 1
        fi

        # 创建/覆盖配置文件 config.yaml
        echo -e "${GREEN}正在写入配置到 /etc/hysteria/config.yaml...${RESET}"
        cat > /etc/hysteria/config.yaml <<EOF
listen: :$port                        # 端口自定义

acme:                                # 域名证书 
  domains:
    - $domain                        # 用户输入的解析好的域名
  email: $random_email                # 随机生成的邮箱地址

auth:
  type: password
  password: $password                 # 用户输入的自定义密码

masquerade:
  type: proxy
  proxy:
    url: https://bing.com            # 伪装网站
    rewriteHost: true

outbounds:                           # 出站端口设置
  - name: v4
    type: direct
    direct:
      mode: 4
  - name: v6
    type: direct
    direct:
      mode: 6

acl:
  inline:                            # 内置出站规则，从上到下优先出站
   - v4(0.0.0.0/0)                   # v4 分流
   - v6(::/0)                        # v6分流
   - direct(all)                     # 其它直连出站
EOF

        # 提示用户完成 Hysteria 的配置
        echo -e "${GREEN}Hysteria 配置已写入到 /etc/hysteria/config.yaml，域名: $domain, 邮箱: $random_email, 端口: $port, 密码: [已隐藏]${RESET}"

        # 自动检测网卡名称，假设 eth0 是默认网卡名称
        NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -E "eth|ens" | head -n 1)

        if [ -z "$NIC" ]; then
            echo -e "${PINK}未能找到网卡名称，请手动设置！${RESET}"
            exit 1
        fi

        echo -e "${GREEN}检测到的网卡名称为: $NIC${RESET}"

        # 提示用户输入端口范围和目标端口
        read -p "$(echo -e "${PINK}请输入跳跃端口范围的起始端口 (例如 20000): ${RESET}")" START_PORT
        read -p "$(echo -e "${PINK}请输入跳跃端口范围的结束端口 (例如 40000): ${RESET}")" END_PORT
        read -p "$(echo -e "${PINK}请输入目标端口 (例如 9443): ${RESET}")" TARGET_PORT

        # 检查端口输入是否有效
        if [[ ! "$START_PORT" =~ ^[0-9]+$ || ! "$END_PORT" =~ ^[0-9]+$ || ! "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
            echo -e "${PINK}输入无效，端口必须为数字。${RESET}"
            exit 1
        fi

        # 检查起始端口和结束端口的大小关系
        if [[ "$START_PORT" -ge "$END_PORT" ]]; then
            echo -e "${PINK}起始端口必须小于结束端口。${RESET}"
            exit 1
        fi

        # 清除旧的 iptables 规则（避免重复添加）
        echo "清除已有的端口跳跃规则..."
        iptables -t nat -D PREROUTING -i "$NIC" -p udp --dport "$START_PORT:$END_PORT" -j DNAT --to-destination :"$TARGET_PORT" 2>/dev/null
        ip6tables -t nat -D PREROUTING -i "$NIC" -p udp --dport "$START_PORT:$END_PORT" -j DNAT --to-destination :"$TARGET_PORT" 2>/dev/null

        # 安装 iptables-persistent
        echo "安装 iptables-persistent..."
        apt update
        apt install -y iptables-persistent

        # 设置 IPv4 和 IPv6 的 iptables 规则
        echo "设置端口跳跃规则 ($START_PORT-$END_PORT -> $TARGET_PORT)..."

        # IPv4 规则
        iptables -t nat -A PREROUTING -i "$NIC" -p udp --dport "$START_PORT:$END_PORT" -j DNAT --to-destination :"$TARGET_PORT"
        # IPv6 规则
        ip6tables -t nat -A PREROUTING -i "$NIC" -p udp --dport "$START_PORT:$END_PORT" -j DNAT --to-destination :"$TARGET_PORT"

        # 保存规则
        echo "保存 iptables 规则..."
        netfilter-persistent save

        # 重启 iptables 服务
        echo "重启 iptables 服务..."
        systemctl restart netfilter-persistent

        echo -e "${GREEN}端口跳跃规则已成功设置，iptables 服务已重启。${RESET}"

        # 启动 Hysteria 服务
        echo -e "${GREEN}启动 hysteria-server 服务...${RESET}"
        if ! systemctl start hysteria-server.service; then
            echo -e "${PINK}启动 hysteria-server 服务失败。退出中...${RESET}"
            exit 1
        fi

        # 检查 Hysteria 服务状态
        echo -e "${GREEN}检查 hysteria-server 服务状态...${RESET}"
        if ! systemctl is-active --quiet hysteria-server.service; then
            echo -e "${PINK}Hysteria 服务未能成功启动。请检查配置和日志。${RESET}"
            exit 1
        fi

        echo -e "${GREEN}Hysteria 服务已成功启动！${RESET}"

    elif [[ $option -eq 2 ]]; then
        echo -e "${GREEN}正在编辑 Hysteria 配置...${RESET}"
        nano /etc/hysteria/config.yaml

        # 重启 Hysteria 服务
        echo -e "${GREEN}修改已保存，重启 Hysteria 服务...${RESET}"
        systemctl restart hysteria-server.service
        echo -e "${GREEN}Hysteria 服务已重启！${RESET}"

    elif [[ $option -eq 3 ]]; then
        echo -e "${GREEN}当前 Hysteria 配置: ${RESET}"
        cat /etc/hysteria/config.yaml
        echo -e "${GREEN}按任意键返回主菜单...${RESET}"
        read -n 1 -s
        continue

    elif [[ $option -eq 4 ]]; then
        echo -e "${GREEN}Hysteria 服务状态: ${RESET}"
        systemctl status hysteria-server.service
        echo -e "${GREEN}按任意键返回主菜单...${RESET}"
        read -n 1 -s
        continue

    elif [[ $option -eq 5 ]]; then
        echo -e "${GREEN}重启 Hysteria 服务...${RESET}"
        systemctl restart hysteria-server.service
        echo -e "${GREEN}Hysteria 服务已重启！${RESET}"
        echo -e "${GREEN}按任意键返回主菜单...${RESET}"
        read -n 1 -s
        continue

    elif [[ $option -eq 6 ]]; then
        echo -e "${GREEN}停止 Hysteria 服务...${RESET}"
        systemctl stop hysteria-server.service
        echo -e "${GREEN}Hysteria 服务已停止！${RESET}"
        echo -e "${GREEN}按任意键返回主菜单...${RESET}"
        read -n 1 -s
        continue

    elif [[ $option -eq 7 ]]; then
        echo -e "${GREEN}查看 Hysteria 日志...${RESET}"
        journalctl -u hysteria-server.service -f
        echo -e "${GREEN}按任意键返回主菜单...${RESET}"
        read -n 1 -s
        continue

    elif [[ $option -eq 8 ]]; then
        echo -e "${GREEN}卸载 Hysteria...${RESET}"
        systemctl stop hysteria-server.service
        systemctl disable hysteria-server.service
        apt remove --purge -y hysteria
        rm -rf /etc/hysteria/
        echo -e "${GREEN}Hysteria 已成功卸载！${RESET}"
        echo -e "${GREEN}按任意键返回主菜单...${RESET}"
        read -n 1 -s
        continue

    elif [[ $option -eq 9 ]]; then
        echo -e "${GREEN}退出...${RESET}"
        exit 0

    else
        echo -e "${PINK}无效选项，请选择 1 到 9 的数字。${RESET}"
        echo -e "${GREEN}按任意键返回主菜单...${RESET}"
        read -n 1 -s
        continue
    fi
done

# 脚本运行结束后自动执行选项 4
echo -e "${GREEN}自动执行选项 4: 检查 Hysteria 服务状态...${RESET}"
systemctl status hysteria-server.service
