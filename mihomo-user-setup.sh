#!/usr/bin/env bash
#
# mihomo-user-setup.sh
# 用户环境下的 mihomo 一键部署与管理脚本（无需 root 权限）
# 使用用户级 systemd 管理进程，支持开机自启、崩溃自动重启
#
# 用法:
#   安装:       bash mihomo-user-setup.sh install
#   设置订阅:   bash mihomo-user-setup.sh sub <订阅链接>
#   更新订阅:   bash mihomo-user-setup.sh sub-update
#   启动:       bash mihomo-user-setup.sh start
#   停止:       bash mihomo-user-setup.sh stop
#   重启:       bash mihomo-user-setup.sh restart
#   开机自启:   bash mihomo-user-setup.sh enable
#   取消自启:   bash mihomo-user-setup.sh disable
#   状态:       bash mihomo-user-setup.sh status
#   日志:       bash mihomo-user-setup.sh log
#   卸载:       bash mihomo-user-setup.sh uninstall
#   帮助:       bash mihomo-user-setup.sh help
#

set -euo pipefail

# ============================================================
# 配置区 - 可根据需要修改
# ============================================================
MIHOMO_HOME="$HOME/.mihomo"
MIHOMO_BIN="$HOME/.local/bin/mihomo"
MIHOMO_CONFIG_DIR="$MIHOMO_HOME/config"
MIHOMO_CONFIG="$MIHOMO_CONFIG_DIR/config.yaml"
MIHOMO_SUB_FILE="$MIHOMO_HOME/.subscription"
MIHOMO_ENV_FILE="$MIHOMO_HOME/.env"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SYSTEMD_SERVICE="mihomo.service"

# 默认端口（避免和系统级 7890 冲突）
DEFAULT_HTTP_PORT=17890
DEFAULT_SOCKS_PORT=17891
DEFAULT_MIXED_PORT=17892
DEFAULT_CONTROLLER_PORT=19090
DEFAULT_SECRET=""

# GitHub 加速前缀（国内可能需要）
GITHUB_PROXY_LIST=(
    "https://ghfast.top/"
    "https://gh-proxy.org/"
    "https://mirror.ghproxy.com/"
    ""
)

# ============================================================
# 颜色
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
title()   { echo -e "\n${CYAN}==== $* ====${NC}"; }

# ============================================================
# 工具函数
# ============================================================

normalize_sub_url() {
    local url="$*"

    url="${url#"${url%%[![:space:]]*}"}"
    url="${url%"${url##*[![:space:]]}"}"

    if [[ ${#url} -ge 2 ]]; then
        if [[ "${url:0:1}" == "'" && "${url: -1}" == "'" ]]; then
            url="${url:1:${#url}-2}"
        elif [[ "${url:0:1}" == '"' && "${url: -1}" == '"' ]]; then
            url="${url:1:${#url}-2}"
        fi
    fi

    printf '%s\n' "$url"
}

is_suspicious_sub_url() {
    local url="$1"

    [[ "$url" == http://* || "$url" == https://* ]] || return 1
    [[ "$url" == *\?* ]] || return 1
    [[ "$url" == *"&"* || "$url" == *"%26"* ]] && return 1

    case "$url" in
        *target=*|*insert=*|*emoji=*|*udp=*|*filename=*|*url=*|*token=*|*subscribe*|*sub?*)
            return 0
            ;;
    esac

    return 1
}

get_shell_rc() {
    local login_shell="${SHELL##*/}"

    case "$login_shell" in
        zsh) echo "$HOME/.zshrc" ;;
        bash) echo "$HOME/.bashrc" ;;
        *)
            if [[ -f "$HOME/.zshrc" ]]; then
                echo "$HOME/.zshrc"
            else
                echo "$HOME/.bashrc"
            fi
            ;;
    esac
}

remove_mihomo_shell_aliases() {
    local shell_rc="$1"

    [[ -f "$shell_rc" ]] || return 0

    sed -i '/# >>> mihomo user proxy >>>/,/# <<< mihomo user proxy <<</d' "$shell_rc"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)   echo "arm64" ;;
        armv7l|armhf)    echo "armv7" ;;
        *)               error "不支持的架构: $arch"; exit 1 ;;
    esac
}

load_env() {
    if [[ -f "$MIHOMO_ENV_FILE" ]]; then
        source "$MIHOMO_ENV_FILE"
    fi
    HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"
    SOCKS_PORT="${SOCKS_PORT:-$DEFAULT_SOCKS_PORT}"
    MIXED_PORT="${MIXED_PORT:-$DEFAULT_MIXED_PORT}"
    CONTROLLER_PORT="${CONTROLLER_PORT:-$DEFAULT_CONTROLLER_PORT}"
    SECRET="${SECRET:-$DEFAULT_SECRET}"
}

save_env() {
    cat > "$MIHOMO_ENV_FILE" << EOF
HTTP_PORT=$HTTP_PORT
SOCKS_PORT=$SOCKS_PORT
MIXED_PORT=$MIXED_PORT
CONTROLLER_PORT=$CONTROLLER_PORT
SECRET=$SECRET
EOF
}

try_download() {
    local url="$1"
    local output="$2"
    local timeout="${3:-30}"

    for proxy in "${GITHUB_PROXY_LIST[@]}"; do
        local full_url="${proxy}${url}"
        info "尝试下载: $full_url"
        if curl -fsSL --connect-timeout 10 --max-time "$timeout" -o "$output" "$full_url" 2>/dev/null; then
            info "下载成功"
            return 0
        fi
    done
    return 1
}

# ============================================================
# systemd 相关
# ============================================================

# 检查用户级 systemd 是否可用
check_systemd_user() {
    if ! systemctl --user status >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# 检查 linger 是否已启用（未登录时保持用户服务运行）
check_linger() {
    local user
    user=$(whoami)
    if [[ -f "/var/lib/systemd/linger/$user" ]]; then
        return 0
    fi
    return 1
}

# 创建 systemd user service 文件
create_systemd_service() {
    mkdir -p "$SYSTEMD_USER_DIR"

    cat > "$SYSTEMD_USER_DIR/$SYSTEMD_SERVICE" << EOF
[Unit]
Description=Mihomo Proxy Client (User)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MIHOMO_BIN} -d ${MIHOMO_CONFIG_DIR}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

# 日志输出到 journalctl
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mihomo

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    info "systemd 用户服务已创建"
}

# 删除 systemd user service 文件
remove_systemd_service() {
    if [[ -f "$SYSTEMD_USER_DIR/$SYSTEMD_SERVICE" ]]; then
        systemctl --user stop mihomo 2>/dev/null || true
        systemctl --user disable mihomo 2>/dev/null || true
        rm -f "$SYSTEMD_USER_DIR/$SYSTEMD_SERVICE"
        systemctl --user daemon-reload
    fi
}

# 检查服务是否在运行
is_running() {
    if check_systemd_user; then
        systemctl --user is-active mihomo >/dev/null 2>&1
    else
        # fallback: 检查进程
        pgrep -f "mihomo -d $MIHOMO_CONFIG_DIR" >/dev/null 2>&1
    fi
}

# ============================================================
# install - 下载 mihomo 二进制 + 创建 systemd 服务
# ============================================================
do_install() {
    title "安装 mihomo 到用户环境"

    # 检查用户级 systemd
    if ! check_systemd_user; then
        error "用户级 systemd 不可用"
        echo -e "  可能的原因："
        echo -e "  1. 系统未使用 systemd（如 WSL1、Docker 容器）"
        echo -e "  2. 需要通过 SSH 登录而非 su 切换用户"
        echo -e "  请确保 XDG_RUNTIME_DIR 已设置: echo \$XDG_RUNTIME_DIR"
        exit 1
    fi

    # 创建目录
    mkdir -p "$HOME/.local/bin" "$MIHOMO_CONFIG_DIR" "$MIHOMO_HOME"

    # 检查是否已安装
    if [[ -x "$MIHOMO_BIN" ]]; then
        local ver
        ver=$("$MIHOMO_BIN" -v 2>/dev/null | head -1 || echo "unknown")
        warn "mihomo 已安装: $ver"
        read -rp "是否重新安装？(y/N): " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || { info "跳过安装"; return 0; }
    fi

    local arch
    arch=$(detect_arch)
    info "系统架构: $arch"

    # 获取最新版本号
    info "获取最新版本..."
    local latest_version
    latest_version=$(curl -fsSL --connect-timeout 10 "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/' || echo "")

    if [[ -z "$latest_version" ]]; then
        for proxy in "${GITHUB_PROXY_LIST[@]}"; do
            latest_version=$(curl -fsSL --connect-timeout 10 "${proxy}https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" 2>/dev/null \
                | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/' || echo "")
            [[ -n "$latest_version" ]] && break
        done
    fi

    if [[ -z "$latest_version" ]]; then
        error "无法获取最新版本号，请检查网络"
        exit 1
    fi

    info "最新版本: $latest_version"

    local filename="mihomo-linux-${arch}-compatible-${latest_version}.gz"
    local download_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${filename}"

    local tmp_file
    tmp_file=$(mktemp /tmp/mihomo.XXXXXX.gz)

    if ! try_download "$download_url" "$tmp_file" 120; then
        filename="mihomo-linux-${arch}-${latest_version}.gz"
        download_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest_version}/${filename}"
        if ! try_download "$download_url" "$tmp_file" 120; then
            rm -f "$tmp_file"
            error "下载失败，请检查网络连接"
            exit 1
        fi
    fi

    # 解压安装
    gunzip -f "$tmp_file"
    local bin_file="${tmp_file%.gz}"
    mv "$bin_file" "$MIHOMO_BIN"
    chmod +x "$MIHOMO_BIN"
    rm -f "$tmp_file"

    # 确保 PATH 包含 ~/.local/bin
    if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
        local shell_rc="$HOME/.bashrc"
        [[ -n "${ZSH_VERSION:-}" ]] && shell_rc="$HOME/.zshrc"
        if ! grep -q '.local/bin' "$shell_rc" 2>/dev/null; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$shell_rc"
            info "已将 ~/.local/bin 添加到 PATH（$shell_rc）"
        fi
        export PATH="$HOME/.local/bin:$PATH"
    fi

    local ver
    ver=$("$MIHOMO_BIN" -v 2>/dev/null | head -1 || echo "unknown")
    info "安装完成: $ver"

    # 初始化端口配置
    load_env

    echo ""
    read -rp "HTTP 代理端口 [${HTTP_PORT}]: " input
    HTTP_PORT="${input:-$HTTP_PORT}"
    read -rp "SOCKS5 代理端口 [${SOCKS_PORT}]: " input
    SOCKS_PORT="${input:-$SOCKS_PORT}"
    read -rp "混合代理端口 [${MIXED_PORT}]: " input
    MIXED_PORT="${input:-$MIXED_PORT}"
    read -rp "Dashboard 端口 [${CONTROLLER_PORT}]: " input
    CONTROLLER_PORT="${input:-$CONTROLLER_PORT}"
    read -rp "Dashboard 密钥 [留空自动生成]: " input
    if [[ -n "$input" ]]; then
        SECRET="$input"
    elif [[ -z "$SECRET" ]]; then
        SECRET=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
    fi

    save_env
    info "端口配置已保存"

    # 创建 systemd 用户服务
    create_systemd_service

    # 检查 linger
    if ! check_linger; then
        echo ""
        warn "linger 未启用 — 退出登录后 mihomo 服务会被停止"
        echo -e "  如需退出登录后仍保持运行，请让管理员执行:"
        echo -e "  ${CYAN}sudo loginctl enable-linger $(whoami)${NC}"
        echo ""
    else
        info "linger 已启用，退出登录后服务将持续运行"
    fi

    # 写入 shell 快捷命令
    setup_shell_aliases

    # 下载 GeoIP 和 GeoSite 数据
    download_geodata

    # 下载 Dashboard UI
    download_ui

    echo ""
    info "安装完成！接下来请设置订阅："
    echo -e "  ${CYAN}bash $0 sub <你的订阅链接>${NC}"
}

# ============================================================
# 下载 GeoIP / GeoSite 数据文件
# ============================================================
download_geodata() {
    title "下载 GeoIP / GeoSite 数据"

    local geoip_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"
    local geosite_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
    local country_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"

    for item in "geoip.dat:$geoip_url" "geosite.dat:$geosite_url" "country.mmdb:$country_url"; do
        local name="${item%%:*}"
        local url="${item#*:}"
        local dest="$MIHOMO_CONFIG_DIR/$name"

        if [[ -f "$dest" ]]; then
            info "$name 已存在，跳过"
            continue
        fi

        info "下载 $name ..."
        if ! try_download "$url" "$dest" 120; then
            warn "$name 下载失败，mihomo 启动后会自动尝试下载"
        fi
    done
}

# ============================================================
# 下载 Dashboard UI（metacubexd）
# ============================================================
download_ui() {
    title "下载 Dashboard UI"

    local ui_dir="$MIHOMO_CONFIG_DIR/ui"

    if [[ -d "$ui_dir" ]] && [[ -n "$(ls -A "$ui_dir" 2>/dev/null)" ]]; then
        info "UI 已存在，跳过下载"
        return 0
    fi

    mkdir -p "$ui_dir"

    local ui_url="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
    local tmp_tgz
    tmp_tgz=$(mktemp /tmp/mihomo_ui.XXXXXX.tgz)

    info "下载 metacubexd UI..."
    if ! try_download "$ui_url" "$tmp_tgz" 120; then
        rm -f "$tmp_tgz"
        warn "UI 下载失败，可使用在线面板: https://metacubex.github.io/metacubexd/"
        return 1
    fi

    tar -xzf "$tmp_tgz" -C "$ui_dir"
    rm -f "$tmp_tgz"
    info "Dashboard UI 下载完成: $ui_dir"
}

# ============================================================
# sub - 设置订阅链接并拉取配置
# ============================================================
do_sub() {
    local url
    url=$(normalize_sub_url "$@")
    if [[ -z "$url" ]]; then
        error "请提供订阅链接: bash $0 sub <URL>"
        exit 1
    fi

    if is_suspicious_sub_url "$url"; then
        error "检测到订阅链接可能在 & 处被 shell 截断，请用引号包裹完整链接"
        echo -e "  正确示例：${CYAN}bash $0 sub 'https://example.com/sub?target=clash&insert=true'${NC}"
        exit 1
    fi

    mkdir -p "$MIHOMO_CONFIG_DIR" "$MIHOMO_HOME"
    echo "$url" > "$MIHOMO_SUB_FILE"
    info "订阅链接已保存"

    do_sub_update
}

# ============================================================
# sub-update - 更新订阅配置
# ============================================================
do_sub_update() {
    if [[ ! -f "$MIHOMO_SUB_FILE" ]]; then
        error "未设置订阅链接，请先运行: bash $0 sub <URL>"
        exit 1
    fi

    local url
    url=$(normalize_sub_url "$(cat "$MIHOMO_SUB_FILE")")
    load_env

    if is_suspicious_sub_url "$url"; then
        error "当前保存的订阅链接疑似不完整，请重新设置并使用引号包裹完整链接"
        echo -e "  重新设置：${CYAN}bash $0 sub 'https://example.com/sub?target=clash&insert=true'${NC}"
        exit 1
    fi

    title "更新订阅配置"
    info "下载订阅配置..."

    local tmp_config
    tmp_config=$(mktemp /tmp/mihomo_config.XXXXXX)

    if ! curl -fsSL --connect-timeout 15 --max-time 60 \
         -H "User-Agent: clash.meta" \
         -o "$tmp_config" "$url"; then
        rm -f "$tmp_config"
        error "订阅下载失败，请检查链接和网络"
        exit 1
    fi

    # 检查文件是否为有效 YAML
    if ! head -20 "$tmp_config" | grep -qE '(proxies|proxy-providers|port|mixed-port)'; then
        local decoded
        decoded=$(mktemp /tmp/mihomo_decoded.XXXXXX)
        if base64 -d "$tmp_config" > "$decoded" 2>/dev/null && \
           head -20 "$decoded" | grep -qE '(proxies|proxy-providers|port|mixed-port)'; then
            mv "$decoded" "$tmp_config"
            info "已自动解码 Base64 订阅"
        else
            rm -f "$decoded"
            warn "配置文件格式可能不是标准 Clash YAML，将直接使用"
        fi
    fi

    # 备份旧配置
    if [[ -f "$MIHOMO_CONFIG" ]]; then
        cp "$MIHOMO_CONFIG" "$MIHOMO_CONFIG.bak"
    fi

    mv "$tmp_config" "$MIHOMO_CONFIG"

    # 覆写端口配置
    patch_config

    info "订阅更新完成"

    # 如果正在运行则重启
    if is_running; then
        info "检测到 mihomo 正在运行，自动重启..."
        do_restart
    else
        echo ""
        info "现在可以启动了: bash $0 start"
    fi
}

# ============================================================
# 修补配置文件中的端口等
# ============================================================
patch_config() {
    load_env

    if [[ ! -f "$MIHOMO_CONFIG" ]]; then
        return
    fi

    local tmp
    tmp=$(mktemp)

    local ui_dir="$MIHOMO_CONFIG_DIR/ui"

    awk -v http_port="$HTTP_PORT" \
        -v socks_port="$SOCKS_PORT" \
        -v mixed_port="$MIXED_PORT" \
        -v controller="0.0.0.0:${CONTROLLER_PORT}" \
        -v secret="$SECRET" \
        -v ui_dir="$ui_dir" \
    '
    BEGIN { done_port=0; done_socks=0; done_mixed=0; done_ctrl=0; done_secret=0; done_lan=0; done_ui=0 }

    /^port[[:space:]]*:/ {
        print "port: " http_port
        done_port=1
        next
    }
    /^socks-port[[:space:]]*:/ {
        print "socks-port: " socks_port
        done_socks=1
        next
    }
    /^mixed-port[[:space:]]*:/ {
        print "mixed-port: " mixed_port
        done_mixed=1
        next
    }
    /^external-controller[[:space:]]*:/ {
        print "external-controller: " controller
        done_ctrl=1
        next
    }
    /^secret[[:space:]]*:/ {
        print "secret: " secret
        done_secret=1
        next
    }
    /^allow-lan[[:space:]]*:/ {
        print "allow-lan: false"
        done_lan=1
        next
    }
    /^#?[[:space:]]*external-ui[[:space:]]*:/ {
        print "external-ui: " ui_dir
        done_ui=1
        next
    }

    { print }

    END {
        if (!done_port)   print "port: " http_port
        if (!done_socks)  print "socks-port: " socks_port
        if (!done_mixed)  print "mixed-port: " mixed_port
        if (!done_ctrl)   print "external-controller: " controller
        if (!done_secret && secret != "") print "secret: " secret
        if (!done_lan)    print "allow-lan: false"
        if (!done_ui)     print "external-ui: " ui_dir
    }
    ' "$MIHOMO_CONFIG" > "$tmp"

    mv "$tmp" "$MIHOMO_CONFIG"
}

# ============================================================
# start / stop / restart / enable / disable
# ============================================================
do_start() {
    if [[ ! -x "$MIHOMO_BIN" ]]; then
        error "mihomo 未安装，请先运行: bash $0 install"
        exit 1
    fi

    if [[ ! -f "$MIHOMO_CONFIG" ]]; then
        error "配置文件不存在，请先设置订阅: bash $0 sub <URL>"
        exit 1
    fi

    # 确保 service 文件存在
    if [[ ! -f "$SYSTEMD_USER_DIR/$SYSTEMD_SERVICE" ]]; then
        create_systemd_service
    fi

    load_env
    title "启动 mihomo"

    systemctl --user start mihomo

    sleep 1
    if systemctl --user is-active mihomo >/dev/null 2>&1; then
        local pid
        pid=$(systemctl --user show mihomo --property=MainPID --value 2>/dev/null || echo "?")
        info "启动成功 (PID: $pid)"
        echo ""
        echo -e "  HTTP  代理: ${CYAN}http://127.0.0.1:${HTTP_PORT}${NC}"
        echo -e "  SOCKS 代理: ${CYAN}socks5://127.0.0.1:${SOCKS_PORT}${NC}"
        echo -e "  混合  代理: ${CYAN}http://127.0.0.1:${MIXED_PORT}${NC}"
        echo -e "  Dashboard: ${CYAN}http://0.0.0.0:${CONTROLLER_PORT}/ui${NC}"
        echo -e "  Secret:    ${CYAN}${SECRET}${NC}"
        echo ""
        echo -e "  终端开启代理: ${GREEN}proxy1_on${NC}"
        echo -e "  终端关闭代理: ${GREEN}proxy1_off${NC}"
    else
        error "启动失败，查看日志: journalctl --user -u mihomo -n 30 --no-pager"
        journalctl --user -u mihomo -n 15 --no-pager 2>/dev/null || true
        exit 1
    fi
}

do_stop() {
    title "停止 mihomo"

    if ! is_running; then
        warn "mihomo 未在运行"
        return 0
    fi

    systemctl --user stop mihomo
    info "已停止"
}

do_restart() {
    if [[ ! -f "$SYSTEMD_USER_DIR/$SYSTEMD_SERVICE" ]]; then
        create_systemd_service
    fi

    title "重启 mihomo"
    systemctl --user restart mihomo

    sleep 1
    if systemctl --user is-active mihomo >/dev/null 2>&1; then
        load_env
        local pid
        pid=$(systemctl --user show mihomo --property=MainPID --value 2>/dev/null || echo "?")
        info "重启成功 (PID: $pid)"
    else
        error "重启失败，查看日志: journalctl --user -u mihomo -n 30 --no-pager"
        exit 1
    fi
}

do_enable() {
    title "设置开机自启"

    if [[ ! -f "$SYSTEMD_USER_DIR/$SYSTEMD_SERVICE" ]]; then
        create_systemd_service
    fi

    systemctl --user enable mihomo
    info "已启用开机自启"

    if ! check_linger; then
        warn "linger 未启用 — 仅在用户登录时自启生效"
        echo -e "  如需未登录也自启，请让管理员执行:"
        echo -e "  ${CYAN}sudo loginctl enable-linger $(whoami)${NC}"
    fi
}

do_disable() {
    title "取消开机自启"
    systemctl --user disable mihomo 2>/dev/null || true
    info "已取消开机自启"
}

# ============================================================
# status
# ============================================================
do_status() {
    load_env
    echo ""

    if check_systemd_user; then
        local active
        active=$(systemctl --user is-active mihomo 2>/dev/null || echo "inactive")
        local enabled
        enabled=$(systemctl --user is-enabled mihomo 2>/dev/null || echo "disabled")

        if [[ "$active" == "active" ]]; then
            local pid
            pid=$(systemctl --user show mihomo --property=MainPID --value 2>/dev/null || echo "?")
            local uptime
            uptime=$(systemctl --user show mihomo --property=ActiveEnterTimestamp --value 2>/dev/null || echo "?")
            echo -e "  状态:    ${GREEN}运行中${NC} (PID: $pid)"
            echo -e "  启动于:  $uptime"
        else
            echo -e "  状态:    ${RED}未运行${NC} ($active)"
        fi

        if [[ "$enabled" == "enabled" ]]; then
            echo -e "  自启:    ${GREEN}已启用${NC}"
        else
            echo -e "  自启:    ${YELLOW}未启用${NC} (bash $0 enable)"
        fi

        if check_linger; then
            echo -e "  Linger:  ${GREEN}已启用${NC}"
        else
            echo -e "  Linger:  ${YELLOW}未启用${NC} (需要 sudo loginctl enable-linger $(whoami))"
        fi
    else
        echo -e "  状态:  ${YELLOW}用户级 systemd 不可用${NC}"
    fi

    echo -e "  配置:    $MIHOMO_CONFIG"
    echo -e "  HTTP:    127.0.0.1:${HTTP_PORT}"
    echo -e "  SOCKS:   127.0.0.1:${SOCKS_PORT}"
    echo -e "  混合:    127.0.0.1:${MIXED_PORT}"
    echo -e "  面板:    http://0.0.0.0:${CONTROLLER_PORT}/ui"

    if [[ -f "$MIHOMO_SUB_FILE" ]]; then
        echo -e "  订阅:    已设置"
    else
        echo -e "  订阅:    ${YELLOW}未设置${NC}"
    fi
    echo ""
}

# ============================================================
# log - 通过 journalctl 查看日志
# ============================================================
do_log() {
    local lines="${1:-50}"
    if check_systemd_user; then
        journalctl --user -u mihomo -f -n "$lines"
    else
        error "用户级 systemd 不可用，无法查看日志"
        exit 1
    fi
}

# ============================================================
# uninstall
# ============================================================
do_uninstall() {
    title "卸载 mihomo"

    read -rp "确认卸载？这将删除所有配置和数据 (y/N): " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { info "已取消"; return 0; }

    # 停止并移除 systemd 服务
    remove_systemd_service

    rm -f "$MIHOMO_BIN"
    rm -rf "$MIHOMO_HOME"

    # 清理 shell 配置
    local shell_rc
    shell_rc=$(get_shell_rc)
    remove_mihomo_shell_aliases "$shell_rc"

    info "卸载完成"
}

# ============================================================
# 写入 shell 快捷命令
# ============================================================
setup_shell_aliases() {
    load_env

    local shell_rc
    shell_rc=$(get_shell_rc)

    # 先删除旧的
    remove_mihomo_shell_aliases "$shell_rc"

    cat >> "$shell_rc" << 'ALIASES_EOF'
# >>> mihomo user proxy >>>
proxy1_on() {
    local port
    if [[ -f "$HOME/.mihomo/.env" ]]; then
        source "$HOME/.mihomo/.env"
        port="${MIXED_PORT:-17892}"
    else
        port="17892"
    fi
    export http_proxy="http://127.0.0.1:${port}"
    export https_proxy="http://127.0.0.1:${port}"
    export all_proxy="socks5://127.0.0.1:${port}"
    export HTTP_PROXY="$http_proxy"
    export HTTPS_PROXY="$https_proxy"
    export ALL_PROXY="$all_proxy"
    export no_proxy="localhost,127.0.0.1,::1"
    echo -e "\033[0;32m[proxy1]\033[0m 用户代理已开启 (port: ${port})"
}
proxy1_off() {
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy
    echo -e "\033[0;33m[proxy1]\033[0m 用户代理已关闭"
}
proxy1_status() {
    if [[ -n "${http_proxy:-}" ]]; then
        echo -e "\033[0;32m[proxy1]\033[0m 用户代理已开启: $http_proxy"
    else
        echo -e "\033[0;33m[proxy1]\033[0m 用户代理未开启"
    fi
}
# <<< mihomo user proxy <<<
ALIASES_EOF

    info "已写入 proxy1_on / proxy1_off / proxy1_status 到 $shell_rc"
}

# ============================================================
# help
# ============================================================
do_help() {
    cat << 'EOF'

  mihomo 用户环境管理脚本（无需 root · systemd 用户服务）

  用法: bash mihomo-user-setup.sh <命令> [参数]

  命令:
    install         安装 mihomo（下载二进制、配置端口、创建 systemd 服务）
    sub <URL>       设置订阅链接并拉取配置
    sub-update      更新订阅（重新拉取配置）
    start           启动 mihomo
    stop            停止 mihomo
    restart         重启 mihomo
    enable          设置开机自启
    disable         取消开机自启
    status          查看状态（运行/自启/linger）
    log [N]         查看实时日志（默认最近 50 行）
    uninstall       卸载（删除所有文件和配置）
    help            显示此帮助

  示例:
    bash mihomo-user-setup.sh install
    bash mihomo-user-setup.sh sub "https://example.com/subscribe?token=xxx"
    bash mihomo-user-setup.sh start
    bash mihomo-user-setup.sh enable
    source ~/.bashrc && proxy1_on
    curl -I https://www.google.com

  注意:
    如需退出登录后仍保持运行，需管理员执行一次:
    sudo loginctl enable-linger <你的用户名>

EOF
}

# ============================================================
# 主入口
# ============================================================
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        install)     do_install ;;
        sub)         do_sub "$@" ;;
        sub-update)  do_sub_update ;;
        start)       do_start ;;
        stop)        do_stop ;;
        restart)     do_restart ;;
        enable)      do_enable ;;
        disable)     do_disable ;;
        status)      do_status ;;
        log)         do_log "$@" ;;
        uninstall)   do_uninstall ;;
        help|--help|-h) do_help ;;
        *)
            error "未知命令: $cmd"
            do_help
            exit 1
            ;;
    esac
}

main "$@"
