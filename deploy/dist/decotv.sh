#!/usr/bin/env bash
# ============================================================================
# DecoTV 服务管理脚本
# 在 Operit chroot Ubuntu 终端中使用
#
# 用法:
#   ./decotv.sh start    启动服务
#   ./decotv.sh stop     停止服务
#   ./decotv.sh restart  重启服务
#   ./decotv.sh status   查看状态
#   ./decotv.sh logs     查看日志
#   ./decotv.sh health   健康检查
# ============================================================================
set -euo pipefail

APP_DIR="/data/decotv"
PID_FILE="$APP_DIR/decotv.pid"
LOG_FILE="$APP_DIR/decotv.log"
PORT="${DECOTV_PORT:-3000}"
HOST="${DECOTV_HOST:-127.0.0.1}"
NODE_ENV="${NODE_ENV:-production}"

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# 检查进程是否存活
is_running() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# 获取进程 PID
get_pid() {
  cat "$PID_FILE" 2>/dev/null || echo ""
}

# 等待端口就绪
wait_for_port() {
  local max_wait="${1:-30}"
  local waited=0
  while [[ $waited -lt $max_wait ]]; do
    if curl -sf "http://$HOST:$PORT/login" -o /dev/null 2>/dev/null; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

do_start() {
  if is_running; then
    warn "DecoTV 已在运行 (PID: $(get_pid))"
    return 0
  fi

  # 清理残留 PID 文件
  rm -f "$PID_FILE"

  info "启动 DecoTV..."
  info "  目录: $APP_DIR"
  info "  地址: http://$HOST:$PORT"

  cd "$APP_DIR"

  # 加载 .env.local 中的环境变量
  if [[ -f .env.local ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env.local
    set +a
  fi

  # 设置必要环境变量
  export NODE_ENV="$NODE_ENV"
  export HOSTNAME="$HOST"
  export PORT="$PORT"
  export FFMPEG_DOWNLOAD_DIR="${FFMPEG_DOWNLOAD_DIR:-$APP_DIR/.cache/ffmpeg-downloads}"

  # 后台启动
  nohup node start.js >> "$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"

  info "等待服务就绪 (PID: $pid)..."
  if wait_for_port 30; then
    info "DecoTV 启动成功!"
    info "  本机访问:   http://127.0.0.1:$PORT"
    info "  局域网访问: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<手机IP>'):$PORT"
  else
    error "DecoTV 启动超时，请查看日志: $LOG_FILE"
    tail -20 "$LOG_FILE"
    return 1
  fi
}

do_stop() {
  if ! is_running; then
    warn "DecoTV 未在运行"
    rm -f "$PID_FILE"
    return 0
  fi

  local pid
  pid="$(get_pid)"
  info "停止 DecoTV (PID: $pid)..."

  kill "$pid" 2>/dev/null || true

  # 等待进程退出
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
    sleep 1
    waited=$((waited + 1))
  done

  # 如果还没退出，强制杀死
  if kill -0 "$pid" 2>/dev/null; then
    warn "进程未响应 SIGTERM，发送 SIGKILL..."
    kill -9 "$pid" 2>/dev/null || true
    sleep 1
  fi

  rm -f "$PID_FILE"
  info "DecoTV 已停止"
}

do_restart() {
  info "重启 DecoTV..."
  do_stop
  sleep 1
  do_start
}

do_status() {
  echo ""
  if is_running; then
    local pid
    pid="$(get_pid)"
    echo -e "  状态:  ${GREEN}运行中${NC}"
    echo "  PID:   $pid"
    echo "  端口:  $PORT"
    echo "  目录:  $APP_DIR"

    # 内存占用
    local mem
    mem="$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0fMB", $1/1024}')"
    [[ -n "$mem" ]] && echo "  内存:  $mem"

    # 运行时间
    local uptime
    uptime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    [[ -n "$uptime" ]] && echo "  时长:  $uptime"

    # 健康检查
    if curl -sf "http://$HOST:$PORT/login" -o /dev/null 2>/dev/null; then
      echo -e "  健康:  ${GREEN}正常${NC}"
    else
      echo -e "  健康:  ${RED}无响应${NC}"
    fi
  else
    echo -e "  状态:  ${RED}未运行${NC}"
    [[ -f "$PID_FILE" ]] && echo "  (PID 文件残留，已清理)" && rm -f "$PID_FILE"
  fi
  echo ""
}

do_logs() {
  if [[ ! -f "$LOG_FILE" ]]; then
    warn "日志文件不存在"
    return
  fi

  local lines="${1:-50}"
  echo -e "${CYAN}=== 最近 $lines 行日志 ===${NC}"
  tail -n "$lines" "$LOG_FILE"
}

do_health() {
  info "健康检查..."
  if ! is_running; then
    error "DecoTV 未运行"
    return 1
  fi

  local http_code
  http_code="$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$PORT/login" 2>/dev/null || echo '000')"

  if [[ "$http_code" =~ ^2 ]]; then
    info "服务正常 (HTTP $http_code)"
    return 0
  else
    error "服务异常 (HTTP $http_code)"
    return 1
  fi
}

# ---- 主入口 ----
case "${1:-}" in
  start)   do_start   ;;
  stop)    do_stop    ;;
  restart) do_restart ;;
  status)  do_status  ;;
  logs)    do_logs "${2:-50}" ;;
  health)  do_health  ;;
  *)
    echo "DecoTV 服务管理脚本"
    echo ""
    echo "用法: $0 {start|stop|restart|status|logs|health}"
    echo ""
    echo "  start    启动服务"
    echo "  stop     停止服务"
    echo "  restart  重启服务"
    echo "  status   查看状态"
    echo "  logs     查看日志 (默认50行，可指定行数: logs 100)"
    echo "  health   健康检查"
    echo ""
    echo "环境变量:"
    echo "  DECOTV_PORT  监听端口 (默认: 3000)"
    echo "  DECOTV_HOST  监听地址 (默认: 127.0.0.1)"
    exit 1
    ;;
esac
