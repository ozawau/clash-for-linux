#!/bin/bash

# 加载系统函数库(Only for RHEL Linux)
# [ -f /etc/init.d/functions ] && source /etc/init.d/functions

#################### 脚本初始化任务 ####################

# 获取脚本工作目录绝对路径
export Server_Dir=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

# 加载.env变量文件
echo "正在加载环境变量..."
source $Server_Dir/.env

# 给二进制启动程序、脚本等添加可执行权限
chmod +x $Server_Dir/bin/*
chmod +x $Server_Dir/scripts/*
chmod +x $Server_Dir/tools/subconverter/subconverter



#################### 变量设置 ####################

Conf_Dir="$Server_Dir/conf"
Temp_Dir="$Server_Dir/temp"
Log_Dir="$Server_Dir/logs"

# 获取 CLASH_SECRET 值，如果不存在则生成一个随机数
Secret=${CLASH_SECRET:-$(openssl rand -hex 32)}

# 初始化跳过下载配置标志
SKIP_DOWNLOAD_CONFIG=false

# 初始化跳过编辑profile标志
SKIP_EDIT_PROFILE=false

# 初始化跳过系统托盘图标标志
SKIP_TRAY_ICON=false

# 处理命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-download-config)
            SKIP_DOWNLOAD_CONFIG=true
            shift
            ;;
        --skip-edit-profile)
            SKIP_EDIT_PROFILE=true
            shift
            ;;
        --skip-tray-icon)
            SKIP_TRAY_ICON=true
            shift
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done


#################### 函数定义 ####################

# 检查依赖是否安装
check_dependencies() {
    if ! command -v yad &> /dev/null; then
        echo -e "\033[33m[WARN] 未检测到 yad，尝试安装...\033[0m"
        if command -v apt &> /dev/null; then
            sudo apt update && sudo apt install -y yad
        elif command -v yum &> /dev/null; then
            sudo yum install -y yad
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y yad
        else
            echo -e "\033[31m[ERROR] 无法安装 yad，请手动安装后重试\033[0m"
            return 1
        fi
    fi
    return 0
}

# 启动系统托盘图标
start_tray_icon() {
    local icon_path="$Server_Dir/icon/Clash_Logo.png"
    
    # 检查图标文件是否存在
    if [ ! -f "$icon_path" ]; then
        echo -e "\033[31m[ERROR] 未找到图标文件: $icon_path\033[0m"
        return 1
    fi
    
    # 检查是否已有Clash托盘图标
    if ps -ef | grep -q "[y]ad.*clash"; then
        echo -e "\n[INFO] 系统托盘图标已存在，跳过添加"
        return 0
    fi
    
    # 启动系统托盘图标
    nohup yad --notification \
        --image="$icon_path" \
        --text="Clash" \
        --command="xdg-open http://127.0.0.1:9090/ui" \
        --no-middle \
        &> "$Log_Dir/tray.log" &
    
    echo -e "\n[INFO] 系统托盘图标已启动"
}

# 自定义action函数，实现通用action功能
success() {
	echo -en "\\033[60G[\\033[1;32m  OK  \\033[0;39m]\r"
	return 0
}

failure() {
	local rc=$?
	echo -en "\\033[60G[\\033[1;31mFAILED\\033[0;39m]\r"
	[ -x /bin/plymouth ] && /bin/plymouth --details
	return $rc
}

action() {
	local STRING rc

	STRING=$1
	echo -n "$STRING "
	shift
	"$@" && success $"$STRING" || failure $"$STRING"
	rc=$?
	echo
	return $rc
}

# 判断命令是否正常执行 函数
if_success() {
	local ReturnStatus=$3
	if [ $ReturnStatus -eq 0 ]; then
		action "$1" /bin/true
	else
		action "$2" /bin/false
		exit 1
	fi
}

# 检查订阅地址并下载配置文件
check_and_download_config() {
    local clash_url="$1"
    local temp_dir="$2"
    local conf_dir="$3"

    # 将 CLASH_URL 变量的值赋给 URL 变量，并检查 CLASH_URL 是否为空
    local url=${clash_url:?Error: clash_url variable is not set or empty}

    # 检查url是否有效
    echo -e '\n正在检测订阅地址...'
    local Text1="Clash订阅地址可访问！"
    local Text2="Clash订阅地址不可访问！"
    
    # 检查URL格式
    if [[ ! $url =~ ^https?:// ]]; then
        echo -e "\033[31m[ERROR] 无效的URL格式: $url\033[0m"
        echo -e "URL必须以 http:// 或 https:// 开头"
        exit 1
    fi

    # 尝试解析域名
    local domain=$(echo "$url" | sed -E 's|^https?://([^/]+).*|\1|')
    if ! host "$domain" >/dev/null 2>&1; then
        echo -e "\033[31m[ERROR] 无法解析域名: $domain\033[0m"
        echo -e "请检查网络连接和DNS设置"
        exit 1
    fi

    # 检查URL可访问性
    curl -o /dev/null -L -k -sS --retry 5 -m 10 --connect-timeout 10 -w "%{http_code}" "$url" | grep -E '^[23][0-9]{2}$' &>/dev/null
    local ReturnStatus=$?
    if_success "$Text1" "$Text2" $ReturnStatus

    # 拉取更新config.yml文件
    echo -e '\n正在下载Clash配置文件...'
    local Text3="配置文件config.yaml下载成功！"
    local Text4="配置文件config.yaml下载失败，退出启动！"

    # 尝试使用curl进行下载
    curl -L -k -sS --retry 5 -m 10 -o "$temp_dir/clash.yaml" "$url"
    ReturnStatus=$?
    if [ $ReturnStatus -ne 0 ]; then
        echo -e "\033[33m[WARN] curl下载失败，尝试使用wget...\033[0m"
        # 如果使用curl下载失败，尝试使用wget进行下载
        for i in {1..10}
        do
            wget -q --no-check-certificate -O "$temp_dir/clash.yaml" "$url"
            ReturnStatus=$?
            if [ $ReturnStatus -eq 0 ]; then
                break
            else
                echo -e "\033[33m[WARN] 第 $i 次wget下载尝试失败\033[0m"
                sleep 1
            fi
        done
    fi
    if_success "$Text3" "$Text4" $ReturnStatus

    # 检查下载的文件是否存在且非空
    if [ ! -s "$temp_dir/clash.yaml" ]; then
        echo -e "\033[31m[ERROR] 下载的配置文件为空或不存在\033[0m"
        exit 1
    fi

    # 重命名clash配置文件
    \cp -a "$temp_dir/clash.yaml" "$temp_dir/clash_config.yaml"

	## 判断订阅内容是否符合clash配置文件标准，尝试转换（当前不支持对 x86_64 以外的CPU架构服务器进行clash配置文件检测和转换，此功能将在后续添加）
	if [[ $CpuArch =~ "x86_64" || $CpuArch =~ "amd64"  ]]; then
		echo -e '\n判断订阅内容是否符合clash配置文件标准:'
		bash $Server_Dir/scripts/clash_profile_conversion.sh
		sleep 3
	fi

	## Clash 配置文件重新格式化及配置
	# 取出代理相关配置 
	#sed -n '/^proxies:/,$p' $Temp_Dir/clash.yaml > $Temp_Dir/proxy.txt
	sed -n '/^proxies:/,$p' $Temp_Dir/clash_config.yaml > $Temp_Dir/proxy.txt

	# 合并形成新的config.yaml
	cat $Temp_Dir/templete_config.yaml > $Temp_Dir/config.yaml
	cat $Temp_Dir/proxy.txt >> $Temp_Dir/config.yaml
	\cp $Temp_Dir/config.yaml $Conf_Dir/
}

# 启动Clash服务
start_clash_service() {
    local server_dir="$1"
    local conf_dir="$2"
    local log_dir="$3"

    echo -e '\n正在启动Clash服务...'
    local Text5="服务启动成功！"
    local Text6="服务启动失败！"
    if [[ $CpuArch =~ "x86_64" || $CpuArch =~ "amd64"  ]]; then
        nohup $server_dir/bin/clash-linux-amd64 -d $conf_dir &> $log_dir/clash.log &
        ReturnStatus=$?
        if_success $Text5 $Text6 $ReturnStatus
    elif [[ $CpuArch =~ "aarch64" ||  $CpuArch =~ "arm64" ]]; then
        nohup $server_dir/bin/clash-linux-arm64 -d $conf_dir &> $log_dir/clash.log &
        ReturnStatus=$?
        if_success $Text5 $Text6 $ReturnStatus
    elif [[ $CpuArch =~ "armv7" ]]; then
        nohup $server_dir/bin/clash-linux-armv7 -d $conf_dir &> $log_dir/clash.log &
        ReturnStatus=$?
        if_success $Text5 $Text6 $ReturnStatus
    else
        echo -e "\033[31m\n[ERROR] Unsupported CPU Architecture！\033[0m"
        exit 1
    fi
}

# 配置系统代理环境变量
setup_proxy_env() {
    # 检查是否有root权限
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "\033[31m[ERROR] 设置系统代理环境变量需要root权限\033[0m"
        echo -e "请使用sudo或以root用户身份运行此脚本"
        return 0
    fi

    # 添加环境变量(root权限)
    cat>/etc/profile.d/clash.sh<<EOF
# 开启系统代理
function proxy_on() {
    export http_proxy=http://127.0.0.1:7890
    export https_proxy=http://127.0.0.1:7890
    export no_proxy=127.0.0.1,localhost
    export HTTP_PROXY=http://127.0.0.1:7890
    export HTTPS_PROXY=http://127.0.0.1:7890
    export NO_PROXY=127.0.0.1,localhost
    echo -e "\033[32m[√] 已开启代理\033[0m"
}

# 关闭系统代理
function proxy_off(){
    unset http_proxy
    unset https_proxy
    unset no_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset NO_PROXY
    echo -e "\033[31m[×] 已关闭代理\033[0m"
}
EOF

    echo -e "请执行以下命令加载环境变量: source /etc/profile.d/clash.sh\n"
    echo -e "请执行以下命令开启系统代理: proxy_on\n"
    echo -e "若要临时关闭系统代理，请执行: proxy_off\n"
}

#################### 任务执行 ####################

## 获取CPU架构信息
# Source the script to get CPU architecture
source $Server_Dir/scripts/get_cpu_arch.sh

# Check if we obtained CPU architecture
if [[ -z "$CpuArch" ]]; then
    echo "Failed to obtain CPU architecture"
    exit 1
fi

## 临时取消环境变量
unset http_proxy
unset https_proxy
unset no_proxy
unset HTTP_PROXY
unset HTTPS_PROXY
unset NO_PROXY

## Clash 订阅地址检测及配置文件下载
if [ "$SKIP_DOWNLOAD_CONFIG" = false ]; then
    check_and_download_config "$CLASH_URL" "$Temp_Dir" "$Conf_Dir"
else
    echo -e "\n[INFO] 跳过配置文件下载..."
fi

# Configure Clash Dashboard
Work_Dir=$(cd $(dirname $0); pwd)
Dashboard_Dir="${Work_Dir}/dashboard/public"
sed -ri "s@^# external-ui:.*@external-ui: ${Dashboard_Dir}@g" $Conf_Dir/config.yaml
sed -r -i '/^secret: /s@(secret: ).*@\1'${Secret}'@g' $Conf_Dir/config.yaml

# Output Dashboard access address and Secret
echo ''
echo -e "Clash Dashboard 访问地址: http://<ip>:9090/ui"
echo -e "Secret: ${Secret}"
echo ''

## 启动Clash服务
start_clash_service "$Server_Dir" "$Conf_Dir" "$Log_Dir"

## 配置系统代理环境变量
if [ "$SKIP_EDIT_PROFILE" = false ]; then
    setup_proxy_env "$Secret"
else
    echo -e "\n[INFO] 跳过系统代理环境变量配置..."
fi

# 启动系统托盘图标
if [ "$SKIP_TRAY_ICON" = false ]; then
    if check_dependencies; then
        start_tray_icon
    fi
else
    echo -e "\n[INFO] 跳过系统托盘图标启动..."
fi
