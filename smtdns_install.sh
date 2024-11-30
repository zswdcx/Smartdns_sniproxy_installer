#!/bin/bash

# Colors
RESET="\033[0m"
BLUE="\033[1;34m"
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"

# Helper Functions
log_success() {
    echo -e "${GREEN}$1${RESET}"
}

log_error() {
    echo -e "${RED}$1${RESET}"
}

log_info() {
    echo -e "${CYAN}$1${RESET}"
}

# SmartDNS 一键安装和配置脚本
# 请确保使用 sudo 或 root 权限运行此脚本
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/lthero-big/Smartdns_sniproxy_installer/refs/heads/main/smtdns_install.sh"
REMOTE_STREAM_CONFIG_FILE_URL="https://raw.githubusercontent.com/lthero-big/Smartdns_sniproxy_installer/refs/heads/main/StreamConfig.yaml"


# 脚本版本和更新时间
SCRIPT_VERSION="V_2.3.10"
LAST_UPDATED=$(date +"%Y-%m-%d")
STREAM_CONFIG_FILE="./StreamConfig.yaml"
CONFIG_FILE="/etc/smartdns/smartdns.conf"

# 检测脚本更新
check_script_update() {
  echo -e "${GREEN}Checking for script updates...${RESET}"
  REMOTE_VERSION=$(curl -fsSL "$REMOTE_SCRIPT_URL" | grep -E "^SCRIPT_VERSION=" | cut -d'"' -f2)
  if [ "$REMOTE_VERSION" != "$SCRIPT_VERSION" ]; then
    echo -e "${GREEN}A newer version ($REMOTE_VERSION) is available. Your version: $SCRIPT_VERSION.${RESET}"
    echo -e "${GREEN}是否更新脚本? (y/n)${RESET}"
    read update_choice
    if [[ "$update_choice" == "y" || "$update_choice" == "Y" ]]; then
      echo -e "${GREEN}Updating script...${RESET}"
      curl -fsSL "$REMOTE_SCRIPT_URL" -o "$0"
      chmod +x "$0"
      echo -e "${GREEN}Script updated to version $REMOTE_VERSION. Please restart the script.${RESET}"
      exit 0
    fi
  else
    echo -e "${GREEN}Your script is up-to-date. Version: $SCRIPT_VERSION.${RESET}"
  fi
}

# Run update check on script start
check_script_update

# 检查是否以 root 身份运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[错误] 请以 root 权限运行此脚本！${RESET}"
  exit 1
fi


# 检查必要工具
check_tools() {
    for tool in curl jq; do
        if ! command -v $tool &>/dev/null; then
            echo -e "${RED}$tool 未安装，正在安装...${RESET}"
            sudo apt-get update && sudo apt-get install -y $tool
        fi
    done

    if ! command -v yq &>/dev/null; then
        echo -e "${RED}yq 未安装，尝试通过 pip 安装...${RESET}"
        sudo apt install -y python3-pip
        pip3 install yq
        if ! command -v yq &>/dev/null; then
            echo -e "${RED}yq 安装失败，请手动检查！${RESET}"
            exit 1
        fi
    fi
}


check_tools

# 获取当前外部IP地址和所属地区
IP_INFO=$(curl -s http://ipinfo.io/json)
IP_ADDRESS=$(echo $IP_INFO | jq -r '.ip')
REGION=$(echo $IP_INFO | jq -r '.region')


# 检测 SmartDNS 是否已经安装
check_smartdns_installed() {
    if command -v smartdns &>/dev/null; then
        echo -e "${GREEN}[已安装] 检测到 SmartDNS 已安装！${RESET}"
        return 0
    else
        echo -e "${RED}[未安装] 未检测到 SmartDNS。${RESET}"
        return 1
    fi
}


# 安装 SmartDNS
install_smartdns() {
    echo -e "${BLUE}正在安装 SmartDNS...${RESET}"
    TEMP_DIR="/tmp/smartdns_install"
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR" || exit 1

    wget https://github.com/pymumu/smartdns/releases/download/Release46/smartdns.1.2024.06.12-2222.x86-linux-all.tar.gz
    if [ $? -ne 0 ]; then
        echo -e "${RED}[错误] SmartDNS 安装包下载失败，请检查网络连接！${RESET}"
        exit 1
    fi
    
    stop_system_dns

    tar zxf smartdns.1.2024.06.12-2222.x86-linux-all.tar.gz
    cd smartdns || exit 1

    chmod +x ./install
    ./install -i
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}SmartDNS 安装成功！${RESET}"
    else
        echo -e "${RED}[错误] SmartDNS 安装失败，请检查日志！${RESET}"
        exit 1
    fi

    # 清理安装临时文件
    cd /
    rm -rf "$TEMP_DIR"
}

# 查看现有的上游 DNS
view_upstream_dns() {
    echo -e "${CYAN}当前配置的上游 DNS 列表：${RESET}"
    grep -E '^server [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$CONFIG_FILE" || echo -e "${YELLOW}暂无配置的上游 DNS。${RESET}"
}


# 添加上游 DNS 为组
add_upstream_dns_group() {

    # 添加自定义上游组 DNS
    while true; do
        echo -e "${BLUE}是否需要添加自定义上游组 DNS？(y/N): ${RESET}"
        read -r add_dns
        if [[ "$add_dns" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}请输入上游 DNS 的 IP 地址（格式：11.22.33.44）：${RESET}"
            read -r dns_ip
            if [[ ! $dns_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${RED}无效的 IP 地址，请重新输入！${RESET}"
                return
            fi

            echo -e "${BLUE}请输入该组的名称（例如：us）：${RESET}"
            read -r group_name
            if [[ -z $group_name ]]; then
                echo -e "${RED}组名称不能为空，请重新输入！${RESET}"
                return
            fi

            echo "server $dns_ip -group $group_name -exclude-default-group" >> "$CONFIG_FILE"
            echo -e "${GREEN}已成功添加上游 DNS：server $dns_ip -group $group_name -exclude-default-group${RESET}"
        else
            break
        fi
    done
}


# 查看现有的上游 DNS 组
view_upstream_dns_groups() {
    echo -e "${CYAN}当前配置的上游 DNS 组：${RESET}"
    grep -E '^server [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ -group' "$CONFIG_FILE" | awk '{print $2, $4}' || echo -e "${YELLOW}暂无配置的上游 DNS 组。${RESET}"
}

# 配置 SmartDNS
configure_smartdns() {
    echo -e "${BLUE}正在配置 SmartDNS...${RESET}"

    CONFIG_FILE="/etc/smartdns/smartdns.conf"

    # 默认配置文件内容
    DEFAULT_CONFIG="bind [::]:53

dualstack-ip-selection no
speed-check-mode none
serve-expired-prefetch-time 21600
prefetch-domain yes
cache-size 32768
cache-persist yes
cache-file /etc/smartdns/cache
prefetch-domain yes
serve-expired yes
serve-expired-ttl 259200
serve-expired-reply-ttl 3
prefetch-domain yes
serve-expired-prefetch-time 21600
cache-checkpoint-time 86400

# 默认上游 DNS
server 8.8.8.8
server 8.8.4.4"

    # 写入默认配置文件
    echo "$DEFAULT_CONFIG" > "$CONFIG_FILE"
    echo -e "${GREEN}默认配置文件已生成：$CONFIG_FILE${RESET}"

    # 提示用户添加自定义上游 DNS
    while true; do
        echo -e "${BLUE}是否需要添加自定义上游 DNS？(y/N): ${RESET}"
        read -r add_dns
        if [[ "$add_dns" =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}请输入上游 DNS 格式（例如：11.22.33.44 -group us -exclude-default-group）:${RESET}"
            read -r custom_dns
            if [[ "$custom_dns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                echo "server $custom_dns" >> "$CONFIG_FILE"
                echo -e "${GREEN}已添加自定义上游 DNS: $custom_dns${RESET}"
            else
                echo -e "\033[31m无效的格式，请重试！${RESET}"
            fi
        else
            break
        fi
    done

    echo -e "${GREEN}SmartDNS 配置完成！${RESET}"
}

# 检测并释放占用端口 53 的服务
release_port_53() {
    echo -e "${BLUE}检查端口 53 的占用情况...${RESET}"

    if lsof -i :53 | grep -q LISTEN; then
        echo -e "\033[31m端口 53 被以下进程占用：${RESET}"
        lsof -i :53

        # 检测 systemd-resolved
        if systemctl is-active --quiet systemd-resolved; then
            echo -e "\033[33msystemd-resolved 正在运行，占用端口 53。${RESET}"
            echo -e "\033[33m尝试停止 systemd-resolved 服务...${RESET}"
            systemctl stop systemd-resolved
            systemctl disable systemd-resolved
            echo -e "${GREEN}[成功] systemd-resolved 服务已停止并禁用。${RESET}"
        fi

        # 停止其他占用进程
        lsof -i :53 | awk 'NR>1 {print $2}' | xargs -r kill -9
        echo -e "${GREEN}端口 53 已释放。${RESET}"
    else
        echo -e "${GREEN}端口 53 未被占用。${RESET}"
    fi
}





# 显示脚本标题
echo -e "${BLUE}======================================${RESET}"
echo -e "${GREEN}       一键配置 SmartDNS 脚本          ${RESET}"
echo -e "${CYAN}       版本：  $SCRIPT_VERSION                ${RESET}"
echo -e "${CYAN}       更新时间：$LAST_UPDATED         ${RESET}"
echo -e "${CYAN}       配置文件路径：$CONFIG_FILE       ${RESET}"
echo -e "${CYAN}       流媒体配置：$STREAM_CONFIG_FILE ${RESET}"
echo -e "${BLUE}======================================${RESET}"
echo -e "\n"
# # 查看一级流媒体平台列表
# view_streaming_platforms() {
#     if [[ ! -f "$STREAM_CONFIG_FILE" ]]; then
#         echo -e "${RED}[错误] 未找到 StreamConfig.yaml 文件，请检查路径：$STREAM_CONFIG_FILE${RESET}"
#         return
#     fi

#     echo -e "${CYAN}流媒体平台列表:${RESET}"
#     yq '. | keys' "$STREAM_CONFIG_FILE" | jq -r '.[]' | nl || echo -e "${YELLOW}暂无可用的流媒体平台配置。${RESET}"
# }


# 查看已添加的平台
view_added_platforms() {
    echo -e "${CYAN}已添加的平台:${RESET}"
    grep -E '^# ' "$CONFIG_FILE" | sed 's/^# //' | uniq || echo -e "${YELLOW}暂无已添加的平台。${RESET}"
}

# 检测平台是否已添加
is_platform_added() {
    local platform_name="$1"
    grep -q "^# $platform_name" "$CONFIG_FILE"
}

# 添加域名规则到配置文件
add_domain_rules() {
    local method="$1"  # nameserver or address
    local domains="$2" # domain list
    local identifier="$3" # group name or IP
    local platform_name="$4" # platform name

    # 添加注释
    echo "# $platform_name" >>"$CONFIG_FILE"
    if [[ "$method" == "nameserver" ]]; then
        while IFS= read -r domain; do
            echo "nameserver /$domain/$identifier" >>"$CONFIG_FILE"
        done <<<"$domains"
    elif [[ "$method" == "address" ]]; then
        while IFS= read -r domain; do
            echo "address /$domain/$identifier" >>"$CONFIG_FILE"
        done <<<"$domains"
    fi
    echo -e "${GREEN}已成功将 $platform_name 的域名添加为 $method 方式，并添加注释。${RESET}"
}

# 修改已存在平台的规则
modify_platform_rules() {
    local platform_name="$1"
    local domains="$2"

    echo -e "${CYAN}请选择新的添加方式：${RESET}"
    echo -e "${YELLOW}1. nameserver方式${RESET}"
    echo -e "${YELLOW}2. address方式${RESET}"
    read -r add_method

    case $add_method in
    1)
        echo -e "${CYAN}请输入已存在的 DNS 组名称（例如：us）：${RESET}"
        read -r group_name
        if ! grep -q " -group $group_name" "$CONFIG_FILE"; then
            echo -e "${RED}指定的 DNS 组不存在！请先创建组。${RESET}"
            return
        fi
        # 删除现有规则
        sed -i "/^# $platform_name/,/^$/d" "$CONFIG_FILE"
        add_domain_rules "nameserver" "$domains" "$group_name" "$platform_name"
        ;;
    2)
        echo -e "${CYAN}请输入 DNS 服务器的 IP 地址（例如：11.22.33.44）：${RESET}"
        read -r dns_ip
        if [[ ! $dns_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${RED}无效的 IP 地址，请重新输入！${RESET}"
            return
        fi
        # 删除现有规则
        sed -i "/^# $platform_name/,/^$/d" "$CONFIG_FILE"
        add_domain_rules "address" "$domains" "$dns_ip" "$platform_name"
        ;;
    *)
        echo -e "${RED}无效选择，请重新输入！${RESET}"
        ;;
    esac
}


# 服务管理函数
manage_service() {
    local service=$1
    local action=$2
    local description=$3

    echo -e "${CYAN}正在${description} ${service} 服务...${RESET}"
    systemctl $action $service
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${service} ${description}成功。${RESET}"
    else
        echo -e "${RED}${service} ${description}失败，请检查系统日志。${RESET}"
        return 1
    fi
}

# 检查服务状态函数
check_service_status() {
    local service=$1
    local service_name=$2

    local is_active=$(systemctl is-active "$service" 2>/dev/null)
    local is_enabled=$(systemctl is-enabled "$service" 2>/dev/null)

    echo -e "${CYAN}${service_name} 服务状态：${RESET}$( [ "$is_active" == "active" ] && echo -e "${GREEN}运行中${RESET}" || echo -e "${RED}已停止${RESET}" )"
    echo -e "${CYAN}${service_name} 开机自启：${RESET}$( [ "$is_enabled" == "enabled" ] && echo -e "${GREEN}已启用${RESET}" || echo -e "${RED}未启用${RESET}" )"
}

# 恢复服务并设置开机自启
restore_service() {
    local service=$1
    manage_service "$service" start "启动"
    manage_service "$service" enable "设置为开机启动"
}

# 停止服务并禁用开机自启
stop_service() {
    local service=$1
    manage_service "$service" stop "停止"
    manage_service "$service" disable "关闭开机自启"
}

# SmartDNS 状态检查
check_smartdns_status() {
    check_service_status "smartdns" "SmartDNS"
}

# 系统 DNS 状态检查
check_system_dns_status() {
    check_service_status "systemd-resolved" "system DNS (systemd-resolved)"
}

# 恢复系统 DNS 服务
restore_system_dns() {
    stop_service "smartdns"
    restore_service "systemd-resolved"
    echo -e "${GREEN}系统 DNS 服务已启动并设置为开机启动。${RESET}"
}

# 停止系统 DNS 服务
stop_system_dns() {
    stop_service "systemd-resolved"
    echo -e "${GREEN}系统 DNS 服务已停止并关闭开机自启。${RESET}"
}

# 恢复 SmartDNS 服务
start_smartdns() {
    stop_service "systemd-resolved"
    restore_service "smartdns"
    echo -e "${GREEN}SmartDNS 服务已启动并设置为开机启动！${RESET}"
}

# 停止 SmartDNS 服务
stop_smartdns() {
    stop_service "smartdns"
    echo -e "${GREEN}SmartDNS 服务已停止并关闭开机自启。${RESET}"
}



# 查看流媒体平台列表
view_streaming_platforms() {

    check_files

    if [[ ! -f "$STREAM_CONFIG_FILE" ]]; then
        echo -e "${RED}[错误] 未找到 StreamConfig.yaml 文件，请检查路径：$STREAM_CONFIG_FILE${RESET}"
        return
    fi

    echo -e "${CYAN}流媒体平台列表:${RESET}"
    yq '. | keys' "$STREAM_CONFIG_FILE" | jq -r '.[]' | nl || echo -e "${YELLOW}暂无可用的流媒体平台配置。${RESET}"

    echo -e "${CYAN}是否查看二级键内容？(y/N): ${RESET}"
    read -r view_nested
    if [[ "$view_nested" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}请输入一级流媒体平台序号：${RESET}"
        read -r platform_index
        platform_name=$(yq '. | keys' "$STREAM_CONFIG_FILE" | jq -r ".[$((platform_index - 1))]")
        if [[ -z $platform_name ]]; then
            echo -e "${RED}无效的序号，请重新输入！${RESET}"
            return
        fi
        echo -e "${CYAN}二级键内容：${RESET}"
        yq ".$platform_name | keys" "$STREAM_CONFIG_FILE" | jq -r '.[]' | nl
    fi
}

# 查看指定一级平台的二级流媒体
view_nested_streaming_platforms() {
    local platform_name="$1"
    echo -e "${CYAN}以下是 $platform_name 的二级流媒体平台列表：${RESET}"
    yq ".$platform_name | keys" "$STREAM_CONFIG_FILE" | jq -r '.[]' | nl || echo -e "${YELLOW}该平台暂无配置的二级流媒体。${RESET}"
}

# 添加所有流媒体平台
add_all_streaming_platforms() {
    if [[ ! -f "$STREAM_CONFIG_FILE" ]]; then
        echo -e "${RED}[错误] 未找到 StreamConfig.yaml 文件，请检查路径：$STREAM_CONFIG_FILE${RESET}"
        return
    fi

    echo -e "${CYAN}请选择添加方式：${RESET}"
    echo -e "${YELLOW}1. nameserver方式${RESET}"
    echo -e "${YELLOW}2. address方式${RESET}"
    read -r add_method

    case $add_method in
    1)
        echo -e "${CYAN}请输入已存在的 DNS 组名称（例如：us）：${RESET}"
        read -r group_name
        if ! grep -q " -group $group_name" "$CONFIG_FILE"; then
            echo -e "${RED}指定的 DNS 组不存在！请先创建组。${RESET}"
            return
        fi

        yq '.' "$STREAM_CONFIG_FILE" | jq -r 'paths | select(length == 2) | .[0] as $k1 | .[1] as $k2 | "\($k1) \($k2)"' | while read -r platform sub_platform; do
            domains=$(yq ".$platform.$sub_platform[]" "$STREAM_CONFIG_FILE" | tr -d '"')
            echo "# $sub_platform" >>"$CONFIG_FILE"
            while IFS= read -r domain; do
                echo "nameserver /$domain/$group_name" >>"$CONFIG_FILE"
            done <<<"$domains"
        done
        echo -e "${GREEN}所有流媒体平台域名已添加为 nameserver 方式。${RESET}"
        ;;
    2)
        echo -e "${CYAN}请输入 DNS 服务器的 IP 地址（例如：11.22.33.44）：${RESET}"
        read -r dns_ip
        if [[ ! $dns_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${RED}无效的 IP 地址，请重新输入！${RESET}"
            return
        fi

        yq '.' "$STREAM_CONFIG_FILE" | jq -r 'paths | select(length == 2) | .[0] as $k1 | .[1] as $k2 | "\($k1) \($k2)"' | while read -r platform sub_platform; do
            domains=$(yq ".$platform.$sub_platform[]" "$STREAM_CONFIG_FILE" | tr -d '"')
            echo "# $sub_platform" >>"$CONFIG_FILE"
            while IFS= read -r domain; do
                echo "address /$domain/$dns_ip" >>"$CONFIG_FILE"
            done <<<"$domains"
        done
        echo -e "${GREEN}所有流媒体平台域名已添加为 address 方式。${RESET}"
        ;;
    *)
        echo -e "${RED}无效选择，请重新输入！${RESET}"
        ;;
    esac
}


# File Existence Check
check_files() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "未找到 SmartDNS 配置文件：$CONFIG_FILE"
        log_info "请确保 SmartDNS 已安装。"
        exit 1
    fi

    if [[ ! -f "$STREAM_CONFIG_FILE" ]]; then
        log_error "未找到流媒体配置文件：$STREAM_CONFIG_FILE"
        log_info "正在下载默认配置文件..."
        wget -q "$REMOTE_STREAM_CONFIG_FILE_URL" -O "$STREAM_CONFIG_FILE"
        if [[ $? -eq 0 ]]; then
            log_success "默认流媒体配置文件已下载。"
        else
            log_error "下载流媒体配置文件失败，请检查网络连接。"
            exit 1
        fi
    fi
}

# 添加流媒体平台到 SmartDNS
add_streaming_platform() {
    check_files

    echo -e "${CYAN}请输入一级流媒体平台序号：${RESET}"
    yq '. | keys' "$STREAM_CONFIG_FILE" | jq -r '.[]' | nl || echo -e "${YELLOW}暂无可用的流媒体平台配置。${RESET}"
    read -r platform_index

    platform_name=$(yq '. | keys' "$STREAM_CONFIG_FILE" | jq -r ".[$((platform_index - 1))]")
    if [[ -z $platform_name ]]; then
        echo -e "${RED}无效的序号，请重新输入！${RESET}"
        return
    fi

    echo -e "${CYAN}您选择的一级平台是：${GREEN}$platform_name${RESET}"

    echo -e "${CYAN}请输入二级流媒体平台序号：${RESET}"
    view_nested_streaming_platforms "$platform_name"
    read -r nested_index

    nested_name=$(yq ".$platform_name | keys" "$STREAM_CONFIG_FILE" | jq -r ".[$((nested_index - 1))]")
    if [[ -z $nested_name ]]; then
        echo -e "${RED}无效的序号，请重新输入！${RESET}"
        return
    fi

    echo -e "${CYAN}您选择的二级平台是：${GREEN}$nested_name${RESET}"
    domains=$(yq ".$platform_name.$nested_name[]" "$STREAM_CONFIG_FILE" | tr -d '"')

    if [[ -z $domains ]]; then
        echo -e "${YELLOW}该流媒体平台暂无配置的域名。${RESET}"
        return
    fi

    if is_platform_added "$nested_name"; then
        echo -e "${YELLOW}该平台已存在，是否需要修改其配置？(y/N)${RESET}"
        read -r modify_choice
        if [[ "$modify_choice" =~ ^[Yy]$ ]]; then
            modify_platform_rules "$nested_name" "$domains"
        else
            echo -e "${CYAN}操作取消。${RESET}"
        fi
    else
        echo -e "${CYAN}请选择添加方式：${RESET}"
        echo -e "${YELLOW}1. nameserver方式${RESET}"
        echo -e "${YELLOW}2. address方式${RESET}"
        read -r add_method

        case $add_method in
        1)
            view_upstream_dns_groups

            echo -e "${CYAN}请输入已存在的 DNS 组名称（例如：us）：${RESET}"
            read -r group_name
            if ! grep -q " -group $group_name" "$CONFIG_FILE"; then
                echo -e "${RED}指定的 DNS 组不存在！请先创建组。${RESET}"
                return
            fi
            add_domain_rules "nameserver" "$domains" "$group_name" "$nested_name"
            ;;
        2)
            view_upstream_dns

            echo -e "${CYAN}请输入 DNS 服务器的 IP 地址（例如：11.22.33.44）：${RESET}"
            read -r dns_ip
            if [[ ! $dns_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${RED}无效的 IP 地址，请重新输入！${RESET}"
                return
            fi
            add_domain_rules "address" "$domains" "$dns_ip" "$nested_name"
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入！${RESET}"
            ;;
        esac
    fi
}



# 主功能菜单
while true; do
    echo -e "${GREEN}请选择要执行的操作：${RESET}"
    echo -e "${CYAN}1.${RESET} ${GREEN} 安装 SmartDNS${RESET}"
    echo -e "${CYAN}2.${RESET} ${GREEN} 重新配置 DNS${RESET}"
    echo -e "${CYAN}3.${RESET} ${GREEN} 查看已配置的上游 DNS${RESET}"
    echo -e "${CYAN}4.${RESET} ${GREEN} 添加上游 DNS 并分组${RESET}"
    echo -e "${CYAN}5.${RESET} ${GREEN} 查看已配置的上游 DNS 组${RESET}"
    echo -e "${CYAN}6.${RESET} ${GREEN} 查看流媒体平台列表${RESET}"
    echo -e "${CYAN}7.${RESET} ${GREEN} 添加流媒体平台到 SmartDNS${RESET}"
    echo -e "${CYAN}8.${RESET} ${GREEN} 一键添加所有流媒体平台${RESET}"
    echo -e "${YELLOW}-------------------------${RESET}"
    echo -e "${CYAN}9.${RESET} ${GREEN} 启动/重启 SmartDNS 服务并开机自启${RESET}"
    echo -e "${CYAN}10.${RESET} ${GREEN}停止 SmartDNS 并关闭开机自启${RESET}"
    echo -e "${CYAN}11.${RESET} ${GREEN}启动/重启 系统DNS 并开机自启动${RESET}"
    echo -e "${CYAN}12.${RESET} ${GREEN}停止 系统DNS 并关闭开机自启${RESET}"
    echo -e "${CYAN}13.${RESET} ${GREEN}检测脚本更新${RESET}"
    echo -e "${CYAN}q.${RESET} ${RED}退出脚本${RESET}"
    echo -e "${YELLOW}-------------------------${RESET}"

    check_smartdns_status
    check_system_dns_status


    echo -e "\n${YELLOW}请选择 :${RESET}"
    read -r choice

    case $choice in
    1)
        check_smartdns_installed || install_smartdns
        ;;
    2)
        configure_smartdns
        ;;
    3)
        view_upstream_dns
        ;;
    4)
        add_upstream_dns_group
        ;;
    5)
        view_upstream_dns_groups
        ;;
    6)
        view_streaming_platforms
        ;;
    7)
        add_streaming_platform
        ;;
    8)
        add_all_streaming_platforms
        ;;
    9)
        start_smartdns
        ;;
    10)
        stop_smartdns
        ;;
    11)
        restore_system_dns
        ;;
    12)
        stop_system_dns
        ;;
    13)
        check_script_update
        ;;
    q)
        echo -e "${RED}退出脚本...${RESET}"
        exit 0
        ;;
    *)
        echo -e "${RED}无效选择，请重新输入！${RESET}"
        ;;
    esac
done
