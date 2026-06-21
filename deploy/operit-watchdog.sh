#!/usr/bin/env bash
# ============================================================================
# Operit Workflow: DecoTV 开机自启 + 保活
#
# 在 Operit 中创建两个 Workflow 来使用此脚本:
#
# Workflow 1 - 开机自启:
#   触发器: Intent (android.intent.action.BOOT_COMPLETED)
#   动作:   执行此脚本 (autostart 模式)
#
# Workflow 2 - 定时保活:
#   触发器: 定时 (每 30 分钟)
#   动作:   执行此脚本 (watchdog 模式)
# ============================================================================
set -euo pipefail

APP_DIR="/data/decotv"
MANAGE_SCRIPT="$APP_DIR/decotv.sh"
LOG_TAG="DecoTV-Watchdog"

log() { echo "[$LOG_TAG] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# ---- 开机自启 ----
autostart() {
  log "收到开机广播，启动 DecoTV..."

  # 等待网络就绪
  local waited=0
  while ! curl -sf http://127.0.0.1:3000 -o /dev/null 2>/dev/null && [[ $waited -lt 60 ]]; do
    # 网络可能还没就绪，等待
    if ! ip route | grep -q default 2>/dev/null; then
      sleep 5
      waited=$((waited + 5))
      continue
    fi
    break
  done

  # 启动服务
  bash "$MANAGE_SCRIPT" start
  log "开机自启完成"
}

# ---- 定时保活 ----
watchdog() {
  # 检查进程是否存活
  if ! bash "$MANAGE_SCRIPT" health &>/dev/null; then
    log "DecoTV 未运行或无响应，尝试重启..."
    bash "$MANAGE_SCRIPT" restart
    log "保活重启完成"
  else
    log "DecoTV 运行正常"
  fi
}

# ---- 主入口 ----
case "${1:-watchdog}" in
  autostart) autostart ;;
  watchdog)  watchdog  ;;
  *)
    echo "用法: $0 {autostart|watchdog}"
    echo ""
    echo "  autostart  开机自启模式 (由 BOOT_COMPLETED Intent 触发)"
    echo "  watchdog   定时保活模式 (由定时器触发)"
    ;;
esac
