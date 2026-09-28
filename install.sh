#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        err "请使用: sudo bash -c \"\$(curl -fsSL ...)\" 或切换到 root 用户"
        exit 1
    fi
}

check_root

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."

    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        *)
            warn "未识别的系统类型,尝试继续..."
            ;;
    esac

    info "依赖安装完成"
}

install_deps

# -----------------------
# 工具函数
# 生成随机端口
rand_port() {
    local port
    port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
    echo "$port"
}

# 生成UUID
rand_uuid() {
    local uuid
    if [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    fi
    echo "$uuid"
}

# 生成随机节点名称
rand_name() {
    local name
    name=$(openssl rand -hex 4 2>/dev/null) || name=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo "node-${name}"
}

# -----------------------
# 配置节点名称后缀（可随意输入，直接回车则自动生成随机名称）
echo "请输入节点名称(可随意输入,直接回车则自动生成随机名称):"
read -r user_name
user_name="$(echo "$user_name" | tr -d '[:space:]')"
if [ -z "$user_name" ]; then
    user_name="$(rand_name)"
    info "未输入名称,已自动生成随机节点名称: $user_name"
fi
suffix="-${user_name}"
echo "$suffix" > /root/node_names.txt

# -----------------------
# 部署协议固定为 VLESS Reality（不再交互选择协议）
ENABLE_REALITY=true

# 保存协议标记到文件（供 sb 管理面板读取）
mkdir -p /etc/sing-box
cat > /etc/sing-box/.protocols <<EOF
ENABLE_REALITY=$ENABLE_REALITY
EOF

info "部署协议: VLESS Reality"

# -----------------------
# 连接地址与 Reality SNI 使用默认值（不再询问）
# CUSTOM_IP 留空 => 自动使用本机出口公网 IP
CUSTOM_IP=""
REALITY_SNI="itunes.apple.com"

mkdir -p /etc/sing-box
cat > /etc/sing-box/.config_cache <<EOF
CUSTOM_IP=$CUSTOM_IP
REALITY_SNI=$REALITY_SNI
EOF

# -----------------------
# 配置 VLESS Reality（端口随机、UUID 自动生成）
get_config() {
    info "开始配置 VLESS Reality..."

    PORT_REALITY=$(rand_port)
    UUID=$(rand_uuid)

    info "VLESS Reality 端口: $PORT_REALITY (随机 10000-60000)"
    info "VLESS Reality UUID 已自动生成"
    info "Reality SNI: $REALITY_SNI"

    info "配置完成，继续安装..."
}

get_config

# -----------------------
# 安装 sing-box
install_singbox() {
    info "开始安装 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        read -p "是否重新安装?(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    case "$OS" in
        alpine)
            info "使用 Edge 仓库安装 sing-box"
            apk update || { err "apk update 失败"; exit 1; }
            apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        debian|redhat)
            bash <(curl -fsSL https://sing-box.app/install.sh) || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        *)
            err "未支持的系统,无法安装 sing-box"
            exit 1
            ;;
    esac

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后未找到可执行文件"
        exit 1
    fi

    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    info "sing-box 安装成功: $INSTALLED_VERSION"
}

install_singbox

# -----------------------
# 生成 Reality 密钥对（必须在 sing-box 安装之后）
generate_reality_keys() {
    info "生成 Reality 密钥对..."

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 未安装，无法生成 Reality 密钥"
        exit 1
    fi

    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || {
        err "生成 Reality 密钥失败"
        exit 1
    }

    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || {
        err "生成 Reality ShortID 失败"
        exit 1
    }

    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        exit 1
    fi

    mkdir -p /etc/sing-box
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid

    info "Reality 密钥已生成"
}

generate_reality_keys

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    # 构建 inbounds 内容（使用临时文件避免字符串处理问题）
    local TEMP_INBOUNDS="/tmp/singbox_inbounds_$.json"
    > "$TEMP_INBOUNDS"

    cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": PORT_REALITY_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_REALITY_PLACEHOLDER",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": ["REALITY_SID_PLACEHOLDER"]
        }
      }
    }
INBOUND_REALITY
    sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY|g" "$TEMP_INBOUNDS"
    sed -i "s|UUID_REALITY_PLACEHOLDER|$UUID|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"

    # 生成最终配置
    cat > "$CONFIG_PATH" <<'CONFIG_HEAD'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
CONFIG_HEAD

    cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"

    cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
CONFIG_TAIL

    rm -f "$TEMP_INBOUNDS"

    sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 \
       && info "配置文件验证通过" \
       || warn "配置文件验证失败,但继续执行"

    # 保存配置缓存（供 sb 管理面板读取）
    cat > /etc/sing-box/.config_cache <<CACHEEOF
ENABLE_REALITY=$ENABLE_REALITY
REALITY_PORT=$PORT_REALITY
REALITY_UUID=$UUID
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
REALITY_SNI=$REALITY_SNI
CUSTOM_IP=$CUSTOM_IP
CACHEEOF

    info "配置缓存已保存到 /etc/sing-box/.config_cache"
}

# 调用配置生成
create_config

info "配置生成完成，准备设置服务..."

# -----------------------
# 设置服务
setup_service() {
    info "配置系统服务..."

    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"

        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
# 自动拉起（程序崩溃、OOM、被 kill 后自动恢复）
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC

        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        rc-service sing-box restart || {
            err "服务启动失败"
            tail -20 /var/log/sing-box.err 2>/dev/null || tail -20 /var/log/sing-box.log 2>/dev/null || true
            exit 1
        }

        sleep 2
        if rc-service sing-box status >/dev/null 2>&1; then
            info "✅ OpenRC 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi

    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"

        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD

        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            journalctl -u sing-box -n 30 --no-pager
            exit 1
        }

        sleep 2
        if systemctl is-active sing-box >/dev/null 2>&1; then
            info "✅ Systemd 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
    fi

    info "服务配置完成: $SERVICE_PATH"
}

setup_service

# -----------------------
# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# CUSTOM_IP 为空 => 自动检测出口公网 IP
if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接IP或ddns域名 : $PUB_IP"
else
    PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
    if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
        warn "无法获取公网 IP,请手动替换"
    else
        info "检测到公网 IP: $PUB_IP"
    fi
fi

# -----------------------
# 生成链接（仅 VLESS Reality）
generate_uris() {
    local host="$PUB_IP"

    echo "=== VLESS Reality ==="
    echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
    echo ""
}

# -----------------------
# 最终输出
echo ""
echo "=========================================="
info "🎉 Sing-box 部署完成!"
echo "=========================================="
echo ""
info "📋 配置信息:"
echo "   Reality 端口: $PORT_REALITY | UUID: $UUID"
echo "   服务器: $PUB_IP"
echo "   Reality server_name(SNI): $REALITY_SNI"
echo "   节点名称: reality${suffix}"
echo ""
info "📂 文件位置:"
echo "   配置: $CONFIG_PATH"
echo "   服务: $SERVICE_PATH"
echo ""
info "📜 客户端链接:"
generate_uris | while IFS= read -r line; do
    echo "   $line"
done
echo ""
info "🔧 管理命令:"
if [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    echo "   日志: tail -f /var/log/sing-box.log"
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    echo "   日志: journalctl -u sing-box -f"
fi
echo ""
echo "=========================================="

# -----------------------
# 创建 sb 管理脚本
SB_PATH="/usr/local/bin/sb"
info "正在创建 sb 管理面板: $SB_PATH"

cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
SERVICE_NAME="sing-box"

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"
        ID_LIKE="${ID_LIKE:-}"
    else
        ID=""
        ID_LIKE=""
    fi

    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os

# 服务控制
service_start() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" start || systemctl start "$SERVICE_NAME"
}
service_stop() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" stop || systemctl stop "$SERVICE_NAME"
}
service_restart() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" restart || systemctl restart "$SERVICE_NAME"
}
service_status() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" status || systemctl status "$SERVICE_NAME" --no-pager
}

# 读取配置
read_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi

    # 加载协议标记文件
    PROTOCOL_FILE="/etc/sing-box/.protocols"
    if [ -f "$PROTOCOL_FILE" ]; then
        . "$PROTOCOL_FILE"
    fi

    # 加载缓存文件（包含端口密码等详细配置）
    if [ -f "$CACHE_FILE" ]; then
        . "$CACHE_FILE"
    fi

    # 确保有默认值
    REALITY_SNI="${REALITY_SNI:-itunes.apple.com}"
    CUSTOM_IP="${CUSTOM_IP:-}"

    # VLESS Reality 参数
    REALITY_PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
    REALITY_UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
    REALITY_PK=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.private_key // empty' "$CONFIG_PATH" | head -n1)
    REALITY_SID=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.short_id[0] // empty' "$CONFIG_PATH" | head -n1)

    REALITY_PUB=""
    if [ -f /etc/sing-box/.reality_pub ]; then
        REALITY_PUB=$(cat /etc/sing-box/.reality_pub)
    fi
}

# 获取公网IP（原始方法）
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && echo "$ip" && return 0
    done
    echo "YOUR_SERVER_IP"
}

# 生成并保存URI
generate_uris() {
    read_config || return 1

    # 优先使用用户自定义入口 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="$CUSTOM_IP"
    else
        PUBLIC_IP=$(get_public_ip)
    fi

    node_suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")

    URI_FILE="/etc/sing-box/uris.txt"
    > "$URI_FILE"

    REALITY_SNI="${REALITY_SNI:-itunes.apple.com}"
    echo "=== VLESS Reality ===" >> "$URI_FILE"
    echo "vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}" >> "$URI_FILE"
    echo "" >> "$URI_FILE"

    info "URI 已保存到: $URI_FILE"
}

# 查看URI
action_view_uri() {
    info "正在生成并显示 URI..."
    generate_uris || { err "生成 URI 失败"; return 1; }
    echo ""
    cat /etc/sing-box/uris.txt
}

# 查看配置文件路径
action_view_config() {
    echo "$CONFIG_PATH"
}

# 编辑配置
action_edit_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "配置文件不存在: $CONFIG_PATH"
        return 1
    fi

    ${EDITOR:-nano} "$CONFIG_PATH" 2>/dev/null || ${EDITOR:-vi} "$CONFIG_PATH"

    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
            info "配置校验通过,已重启服务"
            service_restart || warn "重启失败"
            generate_uris || true
        else
            warn "配置校验失败,服务未重启"
        fi
    fi
}

# 重置Vless Reality端口
action_reset_reality() {
    read_config || return 1

    read -p "输入新的 Vless Reality 端口(回车保持 $REALITY_PORT): " new_port
    new_port="${new_port:-$REALITY_PORT}"

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="vless" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 Vless Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 更新sing-box
action_update() {
    info "开始更新 sing-box..."
    if [ "$OS" = "alpine" ]; then
        apk update && apk upgrade sing-box || bash <(curl -fsSL https://sing-box.app/install.sh)
    else
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi

    info "更新完成,已重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1)
        info "当前版本: $NEW_VER"
        service_restart || warn "重启失败"
    fi
}

# 卸载
action_uninstall() {
    read -p "确认卸载 sing-box?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0

    info "正在卸载..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        apk del sing-box 2>/dev/null || true
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        apt purge -y sing-box >/dev/null 2>&1 || true
    fi
    rm -rf /etc/sing-box /var/log/sing-box* /usr/local/bin/sb /usr/bin/sing-box /root/node_names.txt 2>/dev/null || true
    info "卸载完成"
}

# 动态生成菜单
show_menu() {
    read_config 2>/dev/null || true

    cat <<'MENU'

==========================
 Sing-box 管理面板 (快速指令sb)
==========================
1) 查看节点链接
2) 查看配置文件路径
3) 编辑配置文件
MENU

    # 构建端口重置选项映射
    declare -g -A MENU_MAP
    local option=4

    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 重置 Vless Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))
    fi

    # 固定功能选项
    MENU_MAP[$option]="start"
    echo "$option) 启动服务"
    option=$((option + 1))

    MENU_MAP[$option]="stop"
    echo "$option) 停止服务"
    option=$((option + 1))

    MENU_MAP[$option]="restart"
    echo "$option) 重启服务"
    option=$((option + 1))

    MENU_MAP[$option]="status"
    echo "$option) 查看状态"
    option=$((option + 1))

    MENU_MAP[$option]="update"
    echo "$option) 更新 sing-box"
    option=$((option + 1))

    MENU_MAP[$option]="uninstall"
    echo "$option) 卸载 sing-box"

    cat <<MENU2
0) 退出
==========================
MENU2
}

# 主循环
while true; do
    show_menu
    read -p "请输入选项: " opt

    # 处理退出
    if [ "$opt" = "0" ]; then
        exit 0
    fi

    # 处理固定选项
    case "$opt" in
        1) action_view_uri ;;
        2) action_view_config ;;
        3) action_edit_config ;;
        *)
            # 处理动态选项
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                reset_reality) action_reset_reality ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status ;;
                update) action_update ;;
                uninstall) action_uninstall; exit 0 ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac

    echo ""
done
SB_SCRIPT

chmod +x "$SB_PATH"
ln -sf /usr/local/bin/sb /usr/bin/sb
info "✅ 管理面板已创建,可输入 sb 打开管理面板"
