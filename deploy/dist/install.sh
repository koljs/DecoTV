#!/usr/bin/env bash
# ============================================================================
# DecoTV 手机端安装脚本
# 在 Operit chroot Ubuntu 终端中运行
#
# 前置: 已将 decotv-deploy.tar.gz 解压到当前目录
#   cd /root && tar -xzf /sdcard/Download/decotv-deploy.tar.gz
#   bash install.sh
# ============================================================================
set -euo pipefail

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

INSTALL_DIR="/data/decotv"
SERVICE_NAME="decotv"
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "============================================"
echo "  DecoTV 手机端部署 (Operit chroot)"
echo "============================================"
echo ""

# ---- 1. 检查运行环境 ----
step "1/6 检查运行环境..."

if [[ -f /proc/version ]] && grep -qi "android" /proc/version 2>/dev/null; then
  info "检测到 Android 环境"
elif [[ -f /system/bin/toybox ]] || [[ -f /system/bin/sh ]]; then
  info "检测到 Android 环境"
else
  warn "未检测到 Android 环境，脚本仍会继续执行"
fi

# 检查是否在 chroot/proot 中
if [[ -f /.operit_chroot ]] || command -v apt >/dev/null 2>&1; then
  info "检测到 chroot/Ubuntu 环境"
else
  warn "未检测到 Ubuntu 环境，请确认在 Operit chroot 终端中运行"
fi

# ---- 2. 安装系统依赖 ----
step "2/6 安装系统依赖 (Node.js 20 + FFmpeg)..."

# 检查是否已有 Node.js
NEED_NODE=false
if ! command -v node >/dev/null 2>&1; then
  NEED_NODE=true
elif [[ "$(node -v | cut -d. -f1)" != "v20" ]]; then
  warn "当前 Node.js 版本: $(node -v)，项目推荐 v20"
  NEED_NODE=true
else
  info "Node.js $(node -v) 已安装"
fi

if [[ "$NEED_NODE" == true ]]; then
  info "安装 Node.js 20..."
  if command -v apt >/dev/null 2>&1; then
    apt update -qq
    # 尝试通过 NodeSource 安装 Node.js 20
    if ! apt-cache show nodejs 2>/dev/null | grep -q "Version: 20"; then
      info "通过 NodeSource 安装 Node.js 20..."
      apt install -y -qq curl ca-certificates gnupg 2>/dev/null || true
      mkdir -p /etc/apt/keyrings
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true
      echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list 2>/dev/null || true
      apt update -qq 2>/dev/null || true
    fi
    apt install -y -qq nodejs 2>/dev/null || {
      # NodeSource 失败时回退到 nvm
      warn "apt 安装 Node.js 失败，尝试 nvm..."
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
      export NVM_DIR="$HOME/.nvm"
      [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
      nvm install 20
      nvm use 20
    }
  else
    error "需要 apt 包管理器，请确认在 Ubuntu chroot 环境中运行"
  fi
  info "Node.js $(node -v) 安装完成"
fi

# 安装 FFmpeg
if ! command -v ffmpeg >/dev/null 2>&1; then
  info "安装 FFmpeg..."
  apt install -y -qq ffmpeg 2>/dev/null || warn "FFmpeg 安装失败，视频下载转存功能不可用"
else
  info "FFmpeg 已安装: $(ffmpeg -version | head -1)"
fi

# ---- 3. 部署应用文件 ----
step "3/6 部署应用文件到 $INSTALL_DIR..."

# 停止已有服务
if [[ -f "$INSTALL_DIR/decotv.sh" ]]; then
  info "停止已有 DecoTV 服务..."
  bash "$INSTALL_DIR/decotv.sh" stop 2>/dev/null || true
fi

# 创建安装目录
mkdir -p "$INSTALL_DIR"

# 复制文件
if [[ -d "$CURRENT_DIR/decotv" ]]; then
  info "复制应用文件..."
  # 使用 rsync 如果可用，否则 cp
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$CURRENT_DIR/decotv/" "$INSTALL_DIR/"
  else
    # 清理旧文件但保留 .env.local 和 .cache
    find "$INSTALL_DIR" -mindepth 1 \
      ! -name '.env.local' \
      ! -name '.cache' \
      ! -name 'decotv.log' \
      ! -name 'decotv.pid' \
      -exec rm -rf {} + 2>/dev/null || true
    cp -rf "$CURRENT_DIR/decotv/." "$INSTALL_DIR/"
  fi
else
  error "未找到 decotv 目录，请确认已解压部署包"
fi

# 复制管理脚本
cp "$CURRENT_DIR/decotv.sh" "$INSTALL_DIR/decotv.sh"
chmod +x "$INSTALL_DIR/decotv.sh"

# 保留已有配置
if [[ ! -f "$INSTALL_DIR/.env.local" ]]; then
  if [[ -f "$CURRENT_DIR/decotv/.env.local" ]]; then
    cp "$CURRENT_DIR/decotv/.env.local" "$INSTALL_DIR/.env.local"
    info "已复制默认配置文件"
  fi
else
  info "保留已有 .env.local 配置"
fi

# 创建缓存目录
mkdir -p "$INSTALL_DIR/.cache/ffmpeg-downloads"

info "文件部署完成"

# ---- 4. 修复 standalone 路径 ----
step "4/6 修复 standalone 路径引用..."

# Next.js standalone 的 server.js 中硬编码了 /app 路径
# 需要替换为实际安装路径
if [[ -f "$INSTALL_DIR/server.js" ]]; then
  # 检查是否需要替换
  if grep -q '"/app"' "$INSTALL_DIR/server.js" 2>/dev/null || \
     grep -q "'/app'" "$INSTALL_DIR/server.js" 2>/dev/null; then
    sed -i "s|/app|$INSTALL_DIR|g" "$INSTALL_DIR/server.js"
    info "已将 server.js 中的 /app 替换为 $INSTALL_DIR"
  fi
fi

# start.js 中的路径也需要修复
if [[ -f "$INSTALL_DIR/start.js" ]]; then
  if grep -q '__dirname' "$INSTALL_DIR/start.js"; then
    # start.js 使用 __dirname，无需修改
    info "start.js 使用 __dirname，路径自适应"
  fi
fi

# ---- 5. 验证安装 ----
step "5/6 验证安装..."

[[ -f "$INSTALL_DIR/server.js" ]] || error "server.js 缺失"
[[ -f "$INSTALL_DIR/start.js" ]] || error "start.js 缺失"
[[ -d "$INSTALL_DIR/.next" ]] || error ".next 目录缺失"
[[ -d "$INSTALL_DIR/public" ]] || error "public 目录缺失"
[[ -f "$INSTALL_DIR/.env.local" ]] || warn ".env.local 不存在，将使用默认配置"

# 检查 Node.js 能否加载
cd "$INSTALL_DIR"
node -e "require('./server.js')" &>/dev/null &
CHECK_PID=$!
sleep 2
if kill -0 "$CHECK_PID" 2>/dev/null; then
  kill "$CHECK_PID" 2>/dev/null
  info "Node.js 可以正常加载 server.js"
else
  wait "$CHECK_PID" 2>/dev/null || true
  warn "server.js 加载测试未通过，但不影响后续启动（可能缺少环境变量）"
fi

# ---- 6. 安装完成 ----
step "6/6 安装完成!"

echo ""
echo -e "${GREEN}============================================"
echo "  DecoTV 安装成功!"
echo -e "============================================${NC}"
echo ""
echo "安装目录: $INSTALL_DIR"
echo "配置文件: $INSTALL_DIR/.env.local"
echo "日志文件: $INSTALL_DIR/decotv.log"
echo ""
echo -e "${CYAN}常用命令:${NC}"
echo "  启动服务:   $INSTALL_DIR/decotv.sh start"
echo "  停止服务:   $INSTALL_DIR/decotv.sh stop"
echo "  重启服务:   $INSTALL_DIR/decotv.sh restart"
echo "  查看状态:   $INSTALL_DIR/decotv.sh status"
echo "  查看日志:   $INSTALL_DIR/decotv.sh logs"
echo ""
echo -e "${CYAN}访问地址:${NC}"
echo "  本机:   http://127.0.0.1:3000"
echo "  局域网: http://<手机IP>:3000"
echo ""
echo -e "${YELLOW}提示:${NC}"
echo "  1. 编辑 $INSTALL_DIR/.env.local 修改配置"
echo "  2. 在 Operit 中创建 Workflow 实现开机自启"
echo "  3. 添加 PWA 到手机桌面获得最佳体验"
echo ""
