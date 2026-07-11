#!/bin/bash
# ============================================================================
# Radiance OCI Bot 客户端管理脚本（推荐合并实现）
# 功能：守护进程启动、停止、重启、状态、升级、卸载、日志
# 使用：bash sh_client_bot.sh [start|stop|restart|status|upgrade|uninstall|log]
# 也可：bash sh_client_bot.sh [PORT]           # 等效于守护进程方式启动
# 兼容：bash sh_client_bot.sh [PORT] upgrade   # 给程序内触发升级使用（脱离cgroup）
# 注意：从 Java 程序内触发升级时，会自动“逃离” systemd 的 cgroup，避免被一锅端
# ============================================================================

set -o pipefail

readonly SCRIPT_NAME="sh_client_bot.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly BINARY_NAME="r_client"
readonly CONFIG_FILE="client_config"
readonly LOG_FILE="log_r_client.log"
readonly PID_FILE=".${BINARY_NAME}.pid"
readonly PORT_FILE=".${BINARY_NAME}.port"
readonly UPGRADE_LOG="upgrade.log"
readonly TEMP_UPGRADE_LOG="temp_upgrade.log"
readonly SERVICE_NAME="rbot.service"
readonly SERVICE_ENV_FILE="rbot.env"
readonly SERVICE_ENV_PATH="$SCRIPT_DIR/$SERVICE_ENV_FILE"
readonly UPGRADE_LOCK_FILE=".$BINARY_NAME.upgrading.lock"   # 升级互斥锁

SERVICE_SCOPE=""
SERVICE_DIR=""
SERVICE_PATH=""
SYSTEMCTL_CMD=()
SYSTEMD_AVAILABLE=false

cd "$SCRIPT_DIR" || { echo "无法进入脚本目录: $SCRIPT_DIR" >&2; exit 1; }

# 颜色
readonly COLOR_GREEN="\033[32m"
readonly COLOR_YELLOW="\033[33m"
readonly COLOR_RED="\033[31m"
readonly COLOR_GRAY="\033[90m"
readonly COLOR_RESET="\033[0m"

print_green()  { echo -e "${COLOR_GREEN}$1${COLOR_RESET}"; }
print_yellow() { echo -e "${COLOR_YELLOW}$1${COLOR_RESET}"; }
print_red()    { echo -e "${COLOR_RED}$1${COLOR_RESET}"; }
print_gray()   { echo -e "${COLOR_GRAY}$1${COLOR_RESET}"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------
# systemd 相关
# ------------------------------------------------------------
detect_systemd_support() {
    if [ "$SYSTEMD_AVAILABLE" = true ]; then return 0; fi
    if ! command_exists systemctl; then return 1; fi

    if [ "$(id -u)" -eq 0 ]; then
        SERVICE_SCOPE="system"
        SERVICE_DIR="/etc/systemd/system"
        SYSTEMCTL_CMD=(systemctl)
    else
        SERVICE_SCOPE="user"
        SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        SYSTEMCTL_CMD=(systemctl --user)
    fi
    SERVICE_PATH="$SERVICE_DIR/$SERVICE_NAME"

    if ! "${SYSTEMCTL_CMD[@]}" --no-legend list-unit-files >/dev/null 2>&1; then
        return 1
    fi
    SYSTEMD_AVAILABLE=true
    return 0
}

systemd_unit_exists() { detect_systemd_support || return 1; [ -f "$SERVICE_PATH" ] || "${SYSTEMCTL_CMD[@]}" status "$SERVICE_NAME" >/dev/null 2>&1; }
systemd_is_active()  { detect_systemd_support || return 1; "${SYSTEMCTL_CMD[@]}" is-active "$SERVICE_NAME" >/dev/null 2>&1; }
systemd_main_pid()   {
    detect_systemd_support || return 1
    local pid
    pid=$("${SYSTEMCTL_CMD[@]}" show "$SERVICE_NAME" --property=MainPID --value 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" != "0" ] && echo "$pid"
}

ensure_service_unit() {
    detect_systemd_support || return 1
    mkdir -p "$SERVICE_DIR" >/dev/null 2>&1 || return 1

    local tmp_file install_target service_user service_group
    tmp_file=$(mktemp) || return 1
    install_target="default.target"
    service_user=$(id -un)
    service_group=$(id -gn)
    [ "$SERVICE_SCOPE" = "system" ] && install_target="multi-user.target"

    cat >"$tmp_file" <<EOF
[Unit]
Description=Radiance OCI Bot Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/$BINARY_NAME --configPath=$SCRIPT_DIR/$CONFIG_FILE \$EXTRA_ARGS
Restart=always
RestartSec=10
EnvironmentFile=-$SERVICE_ENV_PATH
StandardOutput=journal
StandardError=journal
EOF

    if [ "$SERVICE_SCOPE" = "system" ]; then
        cat >>"$tmp_file" <<EOF
User=$service_user
Group=$service_group
EOF
    fi

    cat >>"$tmp_file" <<EOF

[Install]
WantedBy=$install_target
EOF

    if [ ! -f "$SERVICE_PATH" ] || ! cmp -s "$tmp_file" "$SERVICE_PATH" >/dev/null 2>&1; then
        mv "$tmp_file" "$SERVICE_PATH" >/dev/null 2>&1 || { rm -f "$tmp_file"; return 1; }
    else
        rm -f "$tmp_file"
    fi
    return 0
}

update_service_env() {
    local port=$1 extra_args=""
    [ -n "$port" ] && extra_args="--server.port=$port"
    local tmp_file; tmp_file=$(mktemp) || return 1
    cat >"$tmp_file" <<EOF
EXTRA_ARGS="$extra_args"
EOF
    if [ ! -f "$SERVICE_ENV_PATH" ] || ! cmp -s "$tmp_file" "$SERVICE_ENV_PATH" >/dev/null 2>&1; then
        mv "$tmp_file" "$SERVICE_ENV_PATH" >/dev/null 2>&1 || { rm -f "$tmp_file"; return 1; }
    else
        rm -f "$tmp_file"
    fi
    return 0
}

reload_systemd_daemon() { detect_systemd_support || return 1; "${SYSTEMCTL_CMD[@]}" daemon-reload >/dev/null 2>&1; }
enable_systemd_service() { detect_systemd_support || return 1; "${SYSTEMCTL_CMD[@]}" is-enabled "$SERVICE_NAME" >/dev/null 2>&1 || "${SYSTEMCTL_CMD[@]}" enable "$SERVICE_NAME" >/dev/null 2>&1; }

# Restart=always 下首次 is-active 可能是 crash-loop 瞬时窗口，观察 2s 后 PID/NRestarts 未变才算真就绪
verify_systemd_stable() {
    local pid1 restarts1 pid2 restarts2
    pid1=$(systemd_main_pid 2>/dev/null || true)
    restarts1=$("${SYSTEMCTL_CMD[@]}" show "$SERVICE_NAME" --property=NRestarts --value 2>/dev/null)
    sleep 2
    "${SYSTEMCTL_CMD[@]}" is-failed "$SERVICE_NAME" >/dev/null 2>&1 && return 1
    systemd_is_active || return 1
    pid2=$(systemd_main_pid 2>/dev/null || true)
    restarts2=$("${SYSTEMCTL_CMD[@]}" show "$SERVICE_NAME" --property=NRestarts --value 2>/dev/null)
    [ -n "$pid1" ] && [ -n "$pid2" ] && [ "$pid1" != "$pid2" ] && return 1
    [ "$restarts1" != "$restarts2" ] && return 1
    return 0
}

wait_for_systemd_start() {
    detect_systemd_support || return 1
    local timeout=${1:-30} elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        "${SYSTEMCTL_CMD[@]}" is-failed "$SERVICE_NAME" >/dev/null 2>&1 && return 1
        if systemd_is_active; then
            verify_systemd_stable && return 0
            return 1
        fi
        sleep 1; elapsed=$((elapsed + 1))
    done
    return 1
}

start_systemd_service() {
    local port=$1
    detect_systemd_support || return 1

    ensure_service_unit      || { print_gray "• systemd 服务单元创建失败，将使用后台方式启动。"; return 1; }
    update_service_env "$port" || { print_gray "• systemd 服务参数写入失败，将使用后台方式启动。"; return 1; }
    reload_systemd_daemon    || { print_gray "• systemd 重新加载失败，将使用后台方式启动。"; return 1; }
    enable_systemd_service >/dev/null 2>&1 || true

    if ! "${SYSTEMCTL_CMD[@]}" restart "$SERVICE_NAME" >/dev/null 2>&1; then
        print_red "✗ systemd 启动失败。"; return 2
    fi
    wait_for_systemd_start 30 || { print_red "✗ systemd 服务未能在预期时间内启动。"; return 2; }
    return 0
}

stop_systemd_service() {
    systemd_unit_exists || return 1
    "${SYSTEMCTL_CMD[@]}" stop "$SERVICE_NAME" >/dev/null 2>&1 || return 1
    for _ in $(seq 1 15); do
        systemd_is_active || return 0
        sleep 1
    done
    return 1
}

# ------------------------------------------------------------
# 打印帮助
# ------------------------------------------------------------
print_usage() {
    echo
    print_green "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_green "         Radiance OCI Bot 使用说明（守护进程管理）"
    print_green "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    print_green "  常用命令："
    print_green "    bash $SCRIPT_NAME              - 启动客户端（默认端口9527，守护进程）"
    print_green "    bash $SCRIPT_NAME 8888         - 启动客户端（指定端口8888，守护进程）"
    print_green "    bash $SCRIPT_NAME start        - 启动客户端"
    print_green "    bash $SCRIPT_NAME stop         - 停止客户端"
    print_green "    bash $SCRIPT_NAME restart      - 重启客户端"
    print_green "    bash $SCRIPT_NAME status       - 查看运行状态"
    echo
    print_green "  维护命令："
    print_green "    bash $SCRIPT_NAME upgrade      - 升级至最新版本（自动判断守护进程状态）"
    print_green "    bash $SCRIPT_NAME uninstall    - 卸载客户端并清理文件"
    print_green "    bash $SCRIPT_NAME log          - 查看运行日志（Ctrl+C退出）"
    echo
    print_green "  支持服务："
    print_green "    https://t.me/radiance_helper_bot /help 获取更多帮助"
    echo
    print_yellow "  使用本脚本代表您已阅读并同意项目协议。"
    print_green "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

# ------------------------------------------------------------
# 通用工具
# ------------------------------------------------------------
download_file() {
    local url=$1 output=$2
    if command_exists wget; then
        wget -q --no-check-certificate -O "$output" "$url"
        return $?
    fi
    if command_exists curl; then
        curl -fsSL --insecure -o "$output" "$url"
        return $?
    fi
    print_red "✗ 未找到可用的下载工具（需要 wget 或 curl）"
    return 1
}

prepare_logs() { touch "$LOG_FILE"; : > "$TEMP_UPGRADE_LOG"; }

wait_for_startup() {
    local expected_pid=$1 timeout=${2:-30} elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        ps -p "$expected_pid" >/dev/null 2>&1 && { echo "$expected_pid"; return 0; }
        local running_pid; running_pid=$(pgrep -f "$BINARY_NAME" | head -1)
        [ -n "$running_pid" ] && ps -p "$running_pid" >/dev/null 2>&1 && { echo "$running_pid"; return 0; }
        sleep 1; elapsed=$((elapsed + 1))
    done
    return 1
}

print_startup_failure_reason() {
    if [ -s "$TEMP_UPGRADE_LOG" ]; then
        print_red "  近期启动输出 (temp_upgrade.log):"
        tail -n 20 "$TEMP_UPGRADE_LOG" | sed 's/^/    /'
    elif [ -s "$LOG_FILE" ]; then
        print_red "  近期日志 (log_r_client.log):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /'
    else
        print_red "  未找到可用日志，请检查配置或系统限制。"
    fi
}

find_listening_port() {
    local pid=$1
    [ -z "$pid" ] && return 0
    # PID 必须是正整数，否则下面的 awk 模式可能意外匹配到其它进程
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
    # 仅接受本服务进程。pid=1 (systemd) 会误命中 socket-activated sshd 的 22 端口
    local proc_name
    proc_name=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')
    [ "$proc_name" = "$BINARY_NAME" ] || return 0
    local port=""

    # 优先用 ss —— 精确匹配 pid=<PID>,（词边界用逗号保证不误命中其他 PID）
    if command_exists ss; then
        port=$(ss -tlnp 2>/dev/null | tail -n +2 \
            | awk -v pat="pid=${pid}," '$0 ~ pat {print $4; exit}' \
            | sed -E 's/.*:([0-9]+)$/\1/')
        # 二次验证：确认端口确实属于该 PID
        if [ -n "$port" ] && command_exists lsof; then
            lsof -nP -p "$pid" -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q . || port=""
        fi
    fi

    # 失败再用 lsof（精确按 PID 查，不存在误匹配）
    if [ -z "$port" ] && command_exists lsof; then
        port=$(lsof -nP -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null \
            | awk 'NR>1 {sub(/.*:/,"",$9); print $9; exit}')
    fi

    # 最后兜底 netstat
    if [ -z "$port" ] && command_exists netstat; then
        port=$(netstat -tlnp 2>/dev/null \
            | awk -v pat="/${pid}\$" '$0 ~ pat {sub(/.*:/,"",$4); print $4; exit}')
    fi

    echo "$port"
}

extract_port_from_cmdline() {
    local pid=$1
    [ -z "$pid" ] && return 0
    ps -p "$pid" -o args= 2>/dev/null | grep -o '\-\-server\.port=[0-9]*' | grep -o '[0-9]*$'
}

get_managed_pid() { [ -f "$PID_FILE" ] || return 1; local p; p=$(cat "$PID_FILE" 2>/dev/null); [ -n "$p" ] && ps -p "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }; rm -f "$PID_FILE"; return 1; }

get_pid() {
    local pid
    if systemd_unit_exists && systemd_is_active; then
        pid=$(systemd_main_pid 2>/dev/null) && { echo "$pid"; return 0; }
    fi
    pid=$(get_managed_pid) && { echo "$pid"; return 0; }
    pid=$(pgrep -f "$BINARY_NAME" | head -1)
    [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1 && { echo "$pid"; return 0; }
    return 1
}

is_running() { local pid; pid=$(get_pid); [ -n "$pid" ]; }
save_pid()   { local pid=$1; [ -n "$pid" ] && echo "$pid" > "$PID_FILE"; }
save_port()  { local port=$1; [ -n "$port" ] && echo "$port" > "$PORT_FILE"; }
load_saved_port() { [ -f "$PORT_FILE" ] && cat "$PORT_FILE"; }
remove_pid() { rm -f "$PID_FILE"; }
remove_port(){ rm -f "$PORT_FILE"; }

graceful_kill() {
    local pid=$1; [ -z "$pid" ] && return 0
    kill -15 "$pid" 2>/dev/null || return 0
    for _ in $(seq 1 10); do sleep 1; ps -p "$pid" >/dev/null 2>&1 || return 0; done
    kill -9 "$pid" 2>/dev/null
}

# 等待端口释放（防止 TIME_WAIT 导致新进程 Address in use）
wait_port_free() {
    local port=$1 timeout=${2:-30} elapsed=0
    [ -z "$port" ] && return 0
    while [ $elapsed -lt "$timeout" ]; do
        # lsof 优先（macOS + Linux 通用），再 ss，最后 netstat
        if command_exists lsof; then
            lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q . || return 0
        elif command_exists ss; then
            ss -tln 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}' || return 0
        elif command_exists netstat; then
            netstat -tln 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END {exit !found}' || return 0
        else
            return 0
        fi
        sleep 1; elapsed=$((elapsed + 1))
    done
    print_yellow "⚠ 端口 $port 在 ${timeout}s 内未释放，继续尝试启动..."
}

# 检测目标端口是否被当前服务之外的进程占用
# 返回 0 = 端口可用（无人监听或仅本服务占用），返回 1 = 被外部进程占用
check_port_conflict() {
    local port=$1
    [ -z "$port" ] && return 0

    local listener_pid=""
    if command_exists ss; then
        listener_pid=$(ss -tlnp "( sport = :${port} )" 2>/dev/null | tail -n +2 \
            | sed -n 's/.*pid=\([0-9]*\),.*/\1/p' | head -1)
    elif command_exists lsof; then
        listener_pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
    elif command_exists netstat; then
        listener_pid=$(netstat -tlnp 2>/dev/null \
            | awk -v p=":${port}\$" '$4 ~ p {sub(/.*\//,"",$7); print $7; exit}')
    fi

    [ -z "$listener_pid" ] && return 0  # 没人监听，可用

    # 检查占用者是否是当前服务自身（r_client 进程）
    local listener_cmd
    listener_cmd=$(ps -p "$listener_pid" -o comm= 2>/dev/null)
    if [ "$listener_cmd" = "$BINARY_NAME" ]; then
        return 0  # 是自己，允许
    fi

    # 被外部进程占用
    print_red "✗ 端口 $port 已被外部进程占用: PID=$listener_pid ($listener_cmd)"
    print_red "  请检查是否有其他服务（如 nginx）监听了同一端口"
    return 1
}

# 统一端口解析：所有 start/restart/upgrade 都只走这个函数
# 参数 $1: Java 传入的可信内部端口（可选）
# 输出到 stdout: 最终端口
# 同时打印端口来源日志
resolve_runtime_port() {
    local java_port=$1 source="" result=""

    # 优先级 1: Java 传入的可信内部端口
    if [ -n "$java_port" ] && [[ "$java_port" =~ ^[0-9]+$ ]]; then
        source="Java 传入"; result="$java_port"
    fi

    # 优先级 2: 当前服务 PID 的实际监听端口
    if [ -z "$result" ]; then
        local cur_pid cur_port
        cur_pid=$(get_pid)
        if [ -n "$cur_pid" ]; then
            cur_port=$(extract_port_from_cmdline "$cur_pid")
            if [ -n "$cur_port" ]; then
                source="进程命令行 --server.port"; result="$cur_port"
            else
                cur_port=$(find_listening_port "$cur_pid")
                if [ -n "$cur_port" ]; then
                    source="进程监听探测"; result="$cur_port"
                fi
            fi
        fi
    fi

    # 优先级 3: .r_client.port 文件
    if [ -z "$result" ]; then
        local saved_port
        saved_port=$(load_saved_port)
        if [ -n "$saved_port" ]; then
            source=".r_client.port 文件"; result="$saved_port"
        fi
    fi

    # 优先级 4: 默认端口
    if [ -z "$result" ]; then
        source="默认值"; result="9527"
    fi

    # 日志写 stderr，stdout 只输出纯端口号
    print_gray "  端口解析: $result (来源: $source)" >&2
    echo "$result"
}

# 等待服务真正就绪：优先 HTTP 健康检查，无 curl/wget 退化到 is_running
# 参数: $1=端口 $2=超时秒数(默认60)
# 返回 0=就绪 1=超时未就绪
wait_healthy() {
    local port=$1 timeout=${2:-60} elapsed=0
    local health_url="https://127.0.0.1:${port}/radiance-bot-client/roc/api/client/health"
    local has_http_tool=false

    # 检测可用的 HTTP 工具
    if command_exists curl; then
        has_http_tool=true
    elif command_exists wget; then
        has_http_tool=true
    fi

    while [ $elapsed -lt "$timeout" ]; do
        sleep 3; elapsed=$((elapsed + 3))
        if [ "$has_http_tool" = true ]; then
            # 优先 curl，没有就 wget
            if command_exists curl; then
                curl -skf -o /dev/null -m 5 "$health_url" 2>/dev/null && return 0
            else
                wget --no-check-certificate -q --spider --timeout=5 "$health_url" 2>/dev/null && return 0
            fi
        else
            # 没有 HTTP 工具，退化到检查进程是否存活
            is_running && return 0
        fi
        # 进程已经不在了就不用继续等
        is_running || return 1
    done
    return 1
}

# 单实例升级锁：有 flock 用 flock；否则软锁退化
with_upgrade_lock() {
    exec 9>"$UPGRADE_LOCK_FILE" 2>/dev/null || true
    if command_exists flock; then
        flock -n 9 || { print_yellow "► 另一个升级正在进行，跳过本次触发。"; return 1; }
        return 0
    fi
    if [ -f "$UPGRADE_LOCK_FILE" ]; then
        local lock_ts now_ts
        lock_ts=$(cat "$UPGRADE_LOCK_FILE" 2>/dev/null)
        [[ "$lock_ts" =~ ^[0-9]+$ ]] || lock_ts=0
        now_ts=$(date +%s)
        if [ "$((now_ts - lock_ts))" -lt 54 ]; then
            print_yellow "► 另一个升级正在进行，跳过本次触发。"
            return 1
        fi
    fi
    date +%s > "$UPGRADE_LOCK_FILE" || true
    return 0
}

# 升级/后台重启时不跟日志
should_follow_log() { [ "${NO_TAIL:-0}" != "1" ]; }

# ------------------------------------------------------------
# 下载/升级（原子化）
# ------------------------------------------------------------
download_or_upgrade() {
    local force_upgrade=$1
    local ARCH DOWNLOAD_URL

    ARCH=$(uname -m)
    OS=$(uname -s)
    if [[ "$OS" == "Darwin" && "$ARCH" == "arm64" ]]; then
        DOWNLOAD_URL="https://github.com/semicons/java_oci_manage/releases/latest/download/gz_client_bot_mac_aarch.tar.gz"
    elif [[ "$OS" == "Darwin" ]]; then
        print_red "✗ macOS 仅支持 Apple Silicon (arm64)，当前架构: $ARCH"
        exit 1
    elif [[ "$ARCH" == "aarch64" ]]; then
        DOWNLOAD_URL="https://github.com/semicons/java_oci_manage/releases/latest/download/gz_client_bot_aarch.tar.gz"
    elif [[ "$ARCH" == "x86_64" ]]; then
        local cpu_flags required_flags supports_advanced
        cpu_flags=$(lscpu | grep -i -m1 flags | awk '{for (i=2; i<=NF; i++) print $i}')
        required_flags="avx avx2 sse4_2"
        supports_advanced=true
        for flag in $required_flags; do
            if [[ "$cpu_flags" != *"$flag"* ]]; then supports_advanced=false; break; fi
        done
        if [ "$supports_advanced" = true ]; then
            DOWNLOAD_URL="https://github.com/semicons/java_oci_manage/releases/latest/download/gz_client_bot_x86.tar.gz"
        else
            DOWNLOAD_URL="https://github.com/semicons/java_oci_manage/releases/latest/download/gz_client_bot_x86_compatible.tar.gz"
        fi
    else
        print_red "✗ 不支持的架构: $OS $ARCH"
        exit 1
    fi

    if [ -x "$BINARY_NAME" ] && [ "$force_upgrade" != true ]; then
        # 已有可执行文件且非强制升级：不动作
        [ -f "gz_client_bot.tar.gz" ] && rm -f gz_client_bot.tar.gz
        return 0
    fi

    print_yellow "► 正在下载最新客户端..."
    local tmpdir tarball
    tmpdir=$(mktemp -d) || { print_red "✗ 创建临时目录失败"; exit 1; }
    tarball="$tmpdir/pkg.tar.gz"

    if ! download_file "$DOWNLOAD_URL" "$tarball"; then
        print_red "✗ 下载失败，请检查网络连接或下载工具。"
        rm -rf "$tmpdir"; exit 1
    fi

    print_yellow "► 正在解压（原子化）..."
    if ! tar -xzf "$tarball" -C "$tmpdir" --exclude="$CONFIG_FILE" >/dev/null 2>&1; then
        print_red "✗ 解压失败"; rm -rf "$tmpdir"; exit 1
    fi

    # 校验新二进制
    if [ ! -f "$tmpdir/$BINARY_NAME" ]; then
        print_red "✗ 包内缺少 $BINARY_NAME"; rm -rf "$tmpdir"; exit 1
    fi

    # 配置文件：如果当前目录不存在才覆盖
    if tar -tf "$tarball" | grep -qx "$CONFIG_FILE"; then
        if [ ! -f "$SCRIPT_DIR/$CONFIG_FILE" ]; then
            tar -xzf "$tarball" -C "$tmpdir" "$CONFIG_FILE" >/dev/null 2>&1 || true
            [ -f "$tmpdir/$CONFIG_FILE" ] && cp -f "$tmpdir/$CONFIG_FILE" "$SCRIPT_DIR/$CONFIG_FILE"
        fi
    fi

    # 覆盖二进制（原子替换）
    chmod +x "$tmpdir/$BINARY_NAME" || true
    mv -f "$tmpdir/$BINARY_NAME" "$SCRIPT_DIR/$BINARY_NAME" || { print_red "✗ 覆盖二进制失败"; rm -rf "$tmpdir"; exit 1; }
    chmod +x "$SCRIPT_DIR/$BINARY_NAME" "$SCRIPT_DIR/$SCRIPT_NAME" || true

    rm -rf "$tmpdir"
    print_green "✓ 下载/升级完成"
}

# ------------------------------------------------------------
# 启动/停止/状态
# ------------------------------------------------------------
start_client() {
    local port_arg=$1 effective_port="" desired_port_flag=false
    local stored_port="" download_done=false systemd_supported=false systemd_active=false
    local start_mode="manual" managed_pid unmanaged_pid pid result

    detect_systemd_support && systemd_supported=true && systemd_is_active && systemd_active=true

    if [ -n "$port_arg" ]; then effective_port="$port_arg"; desired_port_flag=true; fi

    if [ "$systemd_active" = true ]; then
        pid=$(systemd_main_pid 2>/dev/null || true)
        if [ -n "$pid" ]; then
            stored_port=$(extract_port_from_cmdline "$pid")
            [ -z "$stored_port" ] && stored_port=$(find_listening_port "$pid")
        fi
    else
        managed_pid=$(get_managed_pid)
        if [ -n "$managed_pid" ]; then
            stored_port=$(extract_port_from_cmdline "$managed_pid")
            [ -z "$stored_port" ] && stored_port=$(find_listening_port "$managed_pid")
        fi
    fi
    if [ -z "$effective_port" ] && [ -n "$stored_port" ]; then effective_port="$stored_port"; desired_port_flag=true; fi
    if [ -z "$effective_port" ]; then stored_port=$(load_saved_port); [ -n "$stored_port" ] && effective_port="$stored_port" && desired_port_flag=true; fi

    # 端口冲突预检：写入 rbot.env 前确认端口未被外部进程占用
    # local check_port="${effective_port:-9527}"
    # if ! check_port_conflict "$check_port"; then
    #     print_red "✗ 启动中止：端口 $check_port 被外部进程占用，不会写入 rbot.env"
    #     return 1
    # fi

    if [ ! -x "$BINARY_NAME" ]; then
        print_yellow "► 检测到本地缺少客户端文件，正在预先下载..."
        download_or_upgrade true
        download_done=true
    fi
    [ "$download_done" = false ] && download_or_upgrade false

    # 无论 systemd 是否活跃，都先清理非 systemd 管理的残留进程（避免端口占用）
    managed_pid=$(get_managed_pid)
    local systemd_pid=""
    [ "$systemd_active" = true ] && systemd_pid=$(systemd_main_pid 2>/dev/null || true)
    if [ -n "$managed_pid" ] && [ "$managed_pid" != "$systemd_pid" ]; then
        print_yellow "► 检测到客户端已在运行（PID: $managed_pid），准备重新启动..."
        graceful_kill "$managed_pid"; remove_pid
    fi
    unmanaged_pid=$(pgrep -f "$BINARY_NAME" | head -1)
    if [ -n "$unmanaged_pid" ] && [ "$unmanaged_pid" != "$systemd_pid" ] && ps -p "$unmanaged_pid" >/dev/null 2>&1; then
        print_yellow "⚠ 检测到客户端以前台或未知方式运行，将先停止后重启..."
        graceful_kill "$unmanaged_pid"
    fi
    if [ "$systemd_active" = false ]; then remove_port; fi

    # 清理旧 jar
    if [ -f "r_client.jar" ]; then pgrep -f r_client.jar | while read -r p; do kill -9 "$p" 2>/dev/null; done; rm -f r_client.jar; fi

    prepare_logs

    # 先尝试 systemd
    if [ "$systemd_supported" = true ]; then
        start_systemd_service "$effective_port"
        result=$?
        if [ $result -eq 0 ]; then
            start_mode="systemd"
        elif [ $result -eq 2 ]; then
            print_startup_failure_reason
            return 1
        fi
    fi

    if [ "$start_mode" = "systemd" ]; then
        pid=$(systemd_main_pid 2>/dev/null || true)
        if [ -n "$effective_port" ]; then
            save_port "$effective_port"
        elif [ -n "$pid" ]; then
            local detected_port; detected_port=$(find_listening_port "$pid")
            [ -n "$detected_port" ] && effective_port="$detected_port" && save_port "$effective_port"
        fi
        print_green "✓ 客户端已通过 systemd 启动"
        [ -n "$pid" ] && print_green "  PID: $pid"
        [ -n "$effective_port" ] && print_green "  监听端口: $effective_port"
        if should_follow_log; then follow_log_stream; fi
        return 0
    fi

    # 后台守护方式
    print_yellow "► 正在以后台守护方式启动客户端..."
    if [ "$desired_port_flag" = true ]; then
        nohup ./"$BINARY_NAME" --server.port="$effective_port" --configPath="$CONFIG_FILE" >"$TEMP_UPGRADE_LOG" 2>&1 < /dev/null &
    else
        nohup ./"$BINARY_NAME" --configPath="$CONFIG_FILE" >"$TEMP_UPGRADE_LOG" 2>&1 < /dev/null &
    fi
    local pid_raw=$!
    if [ -z "$pid_raw" ]; then
        print_red "✗ 未能获取进程PID，请检查系统限制。"; print_startup_failure_reason; remove_pid; return 1
    fi

    local actual_pid
    if ! actual_pid=$(wait_for_startup "$pid_raw" 30); then
        print_red "✗ 客户端启动失败。"; print_startup_failure_reason; remove_pid; return 1
    fi
    save_pid "$actual_pid"
    if [ "$desired_port_flag" = true ]; then
        save_port "$effective_port"
    else
        local detected_port; detected_port=$(find_listening_port "$actual_pid")
        [ -n "$detected_port" ] && effective_port="$detected_port" && save_port "$effective_port"
    fi

    if is_running; then
        print_green "✓ 客户端以后台模式启动成功"
        print_green "  PID: $actual_pid"
        [ -n "$effective_port" ] && print_green "  监听端口: $effective_port"
        if should_follow_log; then follow_log_stream; fi
        return 0
    fi

    print_red "✗ 客户端启动失败。"; print_startup_failure_reason; remove_pid; return 1
}

stop_client() {
    if systemd_unit_exists && systemd_is_active; then
        print_yellow "► 正在停止 systemd 服务..."
        if stop_systemd_service; then
            remove_pid; remove_port; print_green "✓ 客户端已停止。"; return 0
        else
            print_red "✗ systemd 服务停止失败，请使用 systemctl 查看详情。"; return 1
        fi
    fi

    local pid; pid=$(get_pid)
    if [ -z "$pid" ]; then
        print_yellow "⚠ 客户端未运行。"; remove_pid; remove_port; return 0
    fi

    print_yellow "► 正在停止客户端（PID: $pid）..."
    graceful_kill "$pid"
    pgrep -f "$BINARY_NAME" | while read -r p; do kill -9 "$p" 2>/dev/null; done
    remove_pid; remove_port; print_green "✓ 客户端已停止。"
}

restart_client() {
    local port_arg=$1
    local effective_port
    effective_port=$(resolve_runtime_port "$port_arg")
    if ! check_port_conflict "$effective_port"; then
        print_red "✗ 重启中止：端口 $effective_port 被外部进程占用"; return 1
    fi
    print_yellow "► 正在重启客户端（端口: $effective_port）..."
    stop_client
    wait_port_free "$effective_port"
    start_client "$effective_port"
}

show_status() {
    local pid port uptime mem managed_pid
    local guard_label="后台守护 (nohup)" guard_printer="print_green"
    if systemd_unit_exists; then
        guard_label="systemd 服务 (inactive)"; guard_printer="print_gray"
        systemd_is_active && { guard_label="systemd 服务 (active)"; guard_printer="print_green"; }
    fi

    echo
    print_green "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_green "        Radiance OCI Bot 守护进程状态"
    print_green "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    pid=$(get_pid); managed_pid=$(get_managed_pid)
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
        uptime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs)
        mem=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{printf "%.2f MB", $1/1024}')
        port=$(find_listening_port "$pid")
        [ -z "$port" ] && port=$(extract_port_from_cmdline "$pid")
        [ -z "$port" ] && port=$(load_saved_port)

        print_green "  状态: ✓ 运行中"
        $guard_printer "  守护方式: $guard_label"
        print_green "  PID: $pid"
        print_green "  运行时长: ${uptime:-未知}"
        print_green "  内存占用: ${mem:-未知}"
        [ -n "$port" ] && print_green "  监听端口: $port" || print_gray "  监听端口: 未检测到（可能未打开或权限不足）"
    else
        print_red "  状态: ✗ 未运行"
        $guard_printer "  守护方式: $guard_label"
    fi

    echo
    print_green "  配置文件: $CONFIG_FILE"
    print_green "  日志文件: $LOG_FILE"
    print_green "  PID 文件: $PID_FILE"
    print_green "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

# ------------------------------------------------------------
# 升级（单实例 + 脱离 cgroup + 不 tail）
# ------------------------------------------------------------
upgrade_client() {
    local explicit_port="$1"
    local was_running=false runtime_port

    if ! with_upgrade_lock; then
        print_yellow "► 已有升级在进行，跳过。"; return 0
    fi

    # 统一解析可信内部端口（Java 传入 > 进程实际监听 > 命令行参数 > port 文件 > 默认 9527）
    runtime_port=$(resolve_runtime_port "$explicit_port")

    # 端口冲突预检：如果目标端口被非本服务进程占用，直接拒绝升级
    if ! check_port_conflict "$runtime_port"; then
        print_red "✗ 升级中止：目标端口 $runtime_port 被外部进程占用，不执行升级以避免服务死亡"
        rm -f "$UPGRADE_LOCK_FILE"
        return 1
    fi

    if is_running; then
        was_running=true
        print_yellow "► 正在停止当前守护进程以便升级..."
        stop_client
        wait_port_free "$runtime_port"
    fi

    download_or_upgrade true

    if [ "$was_running" = true ]; then
        print_yellow "► 正在重启守护进程（端口: $runtime_port）..."
        NO_TAIL=1 start_client "$runtime_port"

        if wait_healthy "$runtime_port" 60; then
            print_green "✓ 升级完成并已重启（端口: $runtime_port）"
        else
            print_red "✗ 升级完成但服务未能就绪，请手动检查（journalctl -u rbot.service -n 50）"
        fi
    else
        print_green "✓ 升级完成，使用 bash $SCRIPT_NAME start 启动客户端。"
    fi
    rm -f "$TEMP_UPGRADE_LOG" "$UPGRADE_LOCK_FILE"
}

# ------------------------------------------------------------
# 卸载/日志
# ------------------------------------------------------------
uninstall_client() {
    echo
    print_yellow "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_yellow "        Radiance OCI Bot 卸载确认"
    print_yellow "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    print_red "  将删除以下文件与目录："
    echo "    - $BINARY_NAME"
    echo "    - $CONFIG_FILE"
    echo "    - $LOG_FILE"
    echo "    - $SERVICE_NAME (systemd 服务)"
    echo "    - $SERVICE_ENV_FILE (systemd 环境)"
    echo "    - $PID_FILE"
    echo "    - $PORT_FILE"
    echo "    - $UPGRADE_LOG / $TEMP_UPGRADE_LOG"
    echo "    - gz_client_bot.tar.gz"
    echo "    - debug-*.log"
    echo "    - .task/"
    echo "    - data/ (SSL 证书)"
    echo
    read -r -p "  输入 YES 继续卸载（大写）: " confirm
    [ "$confirm" != "YES" ] && { print_green "✓ 已取消卸载。"; return 0; }

    print_yellow "► 正在停止守护进程..."; stop_client

    if systemd_unit_exists; then
        print_yellow "► 正在移除 systemd 服务..."
        if detect_systemd_support; then
            "${SYSTEMCTL_CMD[@]}" disable "$SERVICE_NAME" >/dev/null 2>&1 || true
            [ -n "$SERVICE_PATH" ] && rm -f "$SERVICE_PATH" >/dev/null 2>&1 || true
            reload_systemd_daemon >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$SERVICE_ENV_PATH"

    print_yellow "► 正在清理文件..."
    rm -f "$BINARY_NAME" "$CONFIG_FILE" "$LOG_FILE" "$PID_FILE" "$PORT_FILE"
    rm -f "$UPGRADE_LOG" "$TEMP_UPGRADE_LOG" "gz_client_bot.tar.gz"
    rm -f debug-*.log 2>/dev/null || true
    rm -rf .task/
    rm -rf data/
    rm -f "$UPGRADE_LOCK_FILE" 2>/dev/null || true

    print_green "✓ 卸载完成。"
    print_yellow "► 如需删除脚本本身，请手动执行: rm -f $SCRIPT_NAME"
    echo
}

follow_log_stream() {
    [ -f "$LOG_FILE" ] || touch "$LOG_FILE"
    print_green "► 正在查看日志（Ctrl+C 退出）..."
    print_gray "• 默认显示最近 50 行，避免首次登录凭据被日志尾部截断。"
    echo
    tail -n 50 -f "$LOG_FILE"
}

tail_log() { follow_log_stream; }

# ------------------------------------------------------------
# 入口
# ------------------------------------------------------------
main() {
    local command=$1 arg=$2

    # 兼容旧版本调用方式：bash sh_client_bot.sh <port> upgrade
    # 关键：从 systemd cgroup“逃生”，否则被 stop/restart 一锅端；并确保单实例升级。
    if [[ "$command" =~ ^[0-9]+$ ]] && [[ "$arg" == "upgrade" ]]; then
        if ! with_upgrade_lock; then
            echo "已有升级在进行，忽略本次触发"; return
        fi
        if detect_systemd_support && command_exists systemd-run; then
            local unit
            unit="rbot-upgrade-$(date +%s)"
            if [ "$SERVICE_SCOPE" = "user" ]; then
                systemd-run --user --collect --unit="$unit" bash -lc "cd '$SCRIPT_DIR' && NO_TAIL=1 bash '$0' upgrade '$command'" >/dev/null 2>&1
            else
                systemd-run --collect --unit="$unit" bash -lc "cd '$SCRIPT_DIR' && NO_TAIL=1 bash '$0' upgrade '$command'" >/dev/null 2>&1
            fi
        else
            if command_exists setsid; then
                ( setsid bash "$0" upgrade "$command" </dev/null >/dev/null 2>&1 & )
            else
                ( bash "$0" upgrade "$command" </dev/null >/dev/null 2>&1 & )
            fi
        fi
        echo "升级已在后台启动"
        return
    fi

    case "$command" in
        start)    start_client "$arg" ;;
        stop)     stop_client ;;
        restart)  restart_client "$arg" ;;
        status)   show_status ;;
        upgrade)  upgrade_client "$arg" ;;   # 支持 upgrade [port]
        uninstall) uninstall_client ;;
        tail|log) tail_log ;;
        help|-h|--help) print_usage ;;
        "")
            print_usage
            start_client ""   # 默认守护启动（自动取 9527 或历史端口）
            ;;
        *)
            if [[ "$command" =~ ^[0-9]+$ ]]; then
                print_usage
                start_client "$command"
            else
                print_red "✗ 未知命令: $command"
                print_usage
                exit 1
            fi
            ;;
    esac
}

main "$@"
