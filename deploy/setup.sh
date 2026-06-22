#!/usr/bin/env bash
# ============================================================================
# DecoTV 一体化部署脚本 (Operit chroot 环境)
# 在手机 Operit Ubuntu 终端中直接运行，无需开发机
#
# 用法:
#   bash setup.sh                  # 完整安装 (环境 + 源码 + 构建 + 部署)
#   bash setup.sh --rebuild        # 重新构建并部署 (跳过环境安装)
#   bash setup.sh --build-only     # 仅构建，不部署
#   bash setup.sh --repo <URL>     # 指定仓库地址 (默认: Decohererk/DecoTV)
#   bash setup.sh --branch <name>  # 指定分支 (默认: main)
# ============================================================================
set -euo pipefail

# ---- 配置 ----
INSTALL_DIR="/data/decotv"
BUILD_DIR="/data/decotv-build"
DEFAULT_REPO="https://github.com/Decohererk/DecoTV.git"
DEFAULT_BRANCH="main"
NODE_MAJOR=20

# ---- 参数解析 ----
REPO_URL="$DEFAULT_REPO"
BRANCH="$DEFAULT_BRANCH"
REBUILD=false
BUILD_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild)     REBUILD=true; shift ;;
    --build-only)  BUILD_ONLY=true; shift ;;
    --repo)        REPO_URL="$2"; shift 2 ;;
    --branch)      BRANCH="$2"; shift 2 ;;
    -h|--help)
      echo "用法: bash setup.sh [选项]"
      echo ""
      echo "  --rebuild          重新构建并部署 (跳过环境安装)"
      echo "  --build-only       仅构建，不部署到 $INSTALL_DIR"
      echo "  --repo <URL>       指定 Git 仓库地址"
      echo "  --branch <name>    指定分支 (默认: main)"
      echo "  -h, --help         显示帮助"
      exit 0
      ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---- 颜色输出 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

echo ""
echo "============================================"
echo "  DecoTV 一体化部署 (Operit chroot)"
echo "============================================"
echo "  仓库: $REPO_URL"
echo "  分支: $BRANCH"
echo "  构建目录: $BUILD_DIR"
echo "  安装目录: $INSTALL_DIR"
echo "============================================"
echo ""

# ============================================================================
# 第一步: 安装系统环境
# ============================================================================
install_system_deps() {
  step "1/5 安装系统依赖..."

  # 检查 apt
  command -v apt >/dev/null 2>&1 || error "需要 apt 包管理器，请确认在 Ubuntu chroot 环境中运行"

  apt update -qq

  # 基础工具
  apt install -y -qq curl git ca-certificates gnupg 2>/dev/null || true

  # ---- Node.js ----
  if command -v node >/dev/null 2>&1; then
    local node_ver
    node_ver="$(node -v)"
    if [[ "$(echo "$node_ver" | cut -d. -f1)" == "v$NODE_MAJOR" ]]; then
      info "Node.js $node_ver 已安装"
    else
      warn "当前 Node.js $node_ver，需要 v$NODE_MAJOR，将重新安装..."
      apt remove -y nodejs 2>/dev/null || true
      install_node
    fi
  else
    install_node
  fi

  # ---- pnpm ----
  if ! command -v pnpm >/dev/null 2>&1; then
    info "安装 pnpm..."
    corepack enable 2>/dev/null || npm install -g pnpm
  fi
  info "pnpm $(pnpm -v) 已就绪"

  # ---- FFmpeg ----
  if ! command -v ffmpeg >/dev/null 2>&1; then
    info "安装 FFmpeg..."
    apt install -y -qq ffmpeg 2>/dev/null || warn "FFmpeg 安装失败，视频下载转存功能不可用"
  else
    info "FFmpeg 已安装"
  fi

  # ---- curl (健康检查用) ----
  command -v curl >/dev/null 2>&1 || apt install -y -qq curl 2>/dev/null || true
}

install_node() {
  info "安装 Node.js $NODE_MAJOR..."

  # 方案 A: NodeSource
  local nodesource_ok=false
  mkdir -p /etc/apt/keyrings 2>/dev/null || true
  if curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key 2>/dev/null | \
     gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null; then
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list
    apt update -qq 2>/dev/null || true
    if apt install -y -qq nodejs 2>/dev/null; then
      nodesource_ok=true
    fi
  fi

  # 方案 B: nvm 回退
  if [[ "$nodesource_ok" == false ]]; then
    warn "NodeSource 安装失败，使用 nvm..."
    if [[ ! -d "$HOME/.nvm" ]]; then
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    fi
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"
    nvm install "$NODE_MAJOR"
    nvm use "$NODE_MAJOR"
    # 确保 nvm 的 node 在 PATH 中持久可用
    if ! command -v node >/dev/null 2>&1; then
      local nvm_node_path
      nvm_node_path="$(dirname "$(which node)")"
      echo "export PATH=\"$nvm_node_path:\$PATH\"" >> "$HOME/.bashrc"
      export PATH="$nvm_node_path:$PATH"
    fi
  fi

  info "Node.js $(node -v) 安装完成"
}

# ============================================================================
# 第二步: 获取源码
# ============================================================================
fetch_source() {
  step "2/5 获取源码..."

  if [[ -d "$BUILD_DIR/.git" ]]; then
    info "已有源码仓库，拉取最新..."
    cd "$BUILD_DIR"
    git fetch origin "$BRANCH" --depth 1 2>/dev/null || true
    git checkout "$BRANCH" 2>/dev/null || true
    git reset --hard "origin/$BRANCH" 2>/dev/null || warn "Git 更新失败，使用本地代码继续"
  else
    info "克隆仓库 ($BRANCH 分支)..."
    rm -rf "$BUILD_DIR"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$BUILD_DIR"
    cd "$BUILD_DIR"
  fi

  info "源码就绪: $(git log --oneline -1 2>/dev/null || echo 'unknown')"
}

# ============================================================================
# 第三步: 构建
# ============================================================================
do_build() {
  step "3/5 构建 standalone 产物..."

  cd "$BUILD_DIR"

  # 安装项目依赖
  info "安装项目依赖..."
  pnpm install --frozen-lockfile 2>/dev/null || pnpm install

  # 构建 (standalone 模式)
  info "执行 next build (STANDALONE=true)..."
  STANDALONE=true pnpm build

  # 验证构建产物
  local standalone_dir="$BUILD_DIR/.next/standalone"
  [[ -d "$standalone_dir" ]] || error "standalone 产物不存在，构建可能失败"
  [[ -f "$standalone_dir/server.js" ]] || error "server.js 不存在，构建可能失败"

  info "构建完成"
}

# ============================================================================
# 第四步: 组装部署目录
# ============================================================================
assemble_package() {
  step "4/5 组装部署包..."

  local standalone_dir="$BUILD_DIR/.next/standalone"
  local pkg_dir="$BUILD_DIR/deploy/dist/decotv"

  rm -rf "$pkg_dir"
  mkdir -p "$pkg_dir"

  # standalone 核心
  cp -r "$standalone_dir/." "$pkg_dir/"

  # .next/static
  mkdir -p "$pkg_dir/.next/static"
  cp -r "$BUILD_DIR/.next/static/." "$pkg_dir/.next/static/"

  # 覆盖 public
  rm -rf "$pkg_dir/public"
  cp -r "$BUILD_DIR/public" "$pkg_dir/public"

  # 覆盖 scripts
  rm -rf "$pkg_dir/scripts"
  cp -r "$BUILD_DIR/scripts" "$pkg_dir/scripts"

  # start.js
  cp "$BUILD_DIR/start.js" "$pkg_dir/start.js"

  # 清理 standalone 冗余文件
  rm -rf "$pkg_dir/src" \
         "$pkg_dir/docs" \
         "$pkg_dir/__tests__" \
         "$pkg_dir/.husky" \
         "$pkg_dir/.vscode" \
         "$pkg_dir/.github" \
         "$pkg_dir/deploy" \
         "$pkg_dir/SECURITY.md" \
         "$pkg_dir/LICENSE" \
         "$pkg_dir/CHANGELOG"

  # 服务管理脚本
  if [[ -f "$BUILD_DIR/deploy/decotv.sh" ]]; then
    cp "$BUILD_DIR/deploy/decotv.sh" "$pkg_dir/decotv.sh"
  else
    # 如果仓库中没有 deploy/decotv.sh，生成一个精简版
    generate_decotv_sh "$pkg_DIR/decotv.sh"
  fi
  chmod +x "$pkg_dir/decotv.sh"

  # 保活脚本
  if [[ -f "$BUILD_DIR/deploy/operit-watchdog.sh" ]]; then
    cp "$BUILD_DIR/deploy/operit-watchdog.sh" "$pkg_dir/operit-watchdog.sh"
    chmod +x "$pkg_dir/operit-watchdog.sh"
  fi

  # 默认 .env.local
  if [[ ! -f "$pkg_dir/.env.local" ]]; then
    cat > "$pkg_dir/.env.local" << 'ENVEOF'
# DecoTV 手机端部署配置
# 修改后需重启服务: decotv.sh restart

# 存储方式 (手机推荐 localstorage)
NEXT_PUBLIC_STORAGE_TYPE=localstorage

# 认证模式: password | public
# public = 免登录，适合个人使用
NEXT_PUBLIC_AUTH_MODE=public

# 管理员密码
ADMIN_PASSWORD=decotv

# 搜索结果加载方式: infinite | pagination
NEXT_PUBLIC_SEARCH_RESULT_LOAD_MODE=infinite

# FFmpeg 路径 (chroot Ubuntu 环境下 apt 安装后直接可用)
FFMPEG_PATH=ffmpeg
FFPROBE_PATH=ffprobe
FFMPEG_DOWNLOAD_DIR=/data/decotv/.cache/ffmpeg-downloads

# 广告过滤
ENABLE_AD_FILTER=true
ENVEOF
  fi

  # 计算大小
  local size
  size="$(du -sh "$pkg_dir" | cut -f1)"
  local file_count
  file_count="$(find "$pkg_dir" -type f | wc -l)"
  info "部署包就绪: $size ($file_count 个文件)"
}

# ============================================================================
# 第五步: 部署到安装目录
# ============================================================================
do_deploy() {
  step "5/5 部署到 $INSTALL_DIR..."

  local pkg_dir="$BUILD_DIR/deploy/dist/decotv"

  # 停止已有服务
  if [[ -f "$INSTALL_DIR/decotv.sh" ]]; then
    info "停止已有 DecoTV 服务..."
    bash "$INSTALL_DIR/decotv.sh" stop 2>/dev/null || true
  fi

  # 创建安装目录
  mkdir -p "$INSTALL_DIR"

  # 同步文件 (保留 .env.local, .cache, 日志, PID)
  info "同步应用文件..."
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude '.env.local' \
      --exclude '.cache' \
      --exclude 'decotv.log' \
      --exclude 'decotv.pid' \
      "$pkg_dir/" "$INSTALL_DIR/"
  else
    # 无 rsync 时手动处理
    find "$INSTALL_DIR" -mindepth 1 \
      ! -name '.env.local' \
      ! -name '.cache' \
      ! -name 'decotv.log' \
      ! -name 'decotv.pid' \
      -exec rm -rf {} + 2>/dev/null || true
    cp -rf "$pkg_dir/." "$INSTALL_DIR/"
  fi

  # 保留已有配置
  if [[ ! -f "$INSTALL_DIR/.env.local" ]] && [[ -f "$pkg_dir/.env.local" ]]; then
    cp "$pkg_dir/.env.local" "$INSTALL_DIR/.env.local"
    info "已生成默认配置文件"
  else
    info "保留已有 .env.local 配置"
  fi

  # 创建缓存目录
  mkdir -p "$INSTALL_DIR/.cache/ffmpeg-downloads"

  # 修复 standalone 路径
  if [[ -f "$INSTALL_DIR/server.js" ]]; then
    if grep -q '"/app"' "$INSTALL_DIR/server.js" 2>/dev/null || \
       grep -q "'/app'" "$INSTALL_DIR/server.js" 2>/dev/null; then
      sed -i "s|/app|$INSTALL_DIR|g" "$INSTALL_DIR/server.js"
      info "已修复 server.js 路径引用"
    fi
  fi

  # 确保 decotv.sh 可执行
  chmod +x "$INSTALL_DIR/decotv.sh" 2>/dev/null || true
  chmod +x "$INSTALL_DIR/operit-watchdog.sh" 2>/dev/null || true

  info "部署完成"
}

# ============================================================================
# 主流程
# ============================================================================
main() {
  if [[ "$REBUILD" == true ]]; then
    # 仅重新构建 + 部署，跳过环境安装和 git clone
    do_build
    assemble_package
    do_deploy
  else
    # 完整安装流程
    install_system_deps
    fetch_source
    do_build
    assemble_package
    if [[ "$BUILD_ONLY" == false ]]; then
      do_deploy
    else
      info "仅构建模式，跳过部署"
      info "构建产物位于: $BUILD_DIR/deploy/dist/decotv/"
    fi
  fi

  # ---- 完成提示 ----
  echo ""
  echo -e "${GREEN}============================================"
  echo "  DecoTV 部署完成!"
  echo -e "============================================${NC}"
  echo ""
  echo "安装目录: $INSTALL_DIR"
  echo "配置文件: $INSTALL_DIR/.env.local"
  echo ""

  if [[ "$BUILD_ONLY" == false ]]; then
    echo -e "${CYAN}启动服务:${NC}"
    echo "  $INSTALL_DIR/decotv.sh start"
    echo ""
    echo -e "${CYAN}访问地址:${NC}"
    echo "  本机:   http://127.0.0.1:3000"
    echo "  局域网: http://<手机IP>:3000"
    echo ""
    echo -e "${CYAN}开机自启 + 保活:${NC}"
    echo "  在 Operit 中创建 Workflow:"
    echo "  1. 开机自启: Intent(BOOT_COMPLETED) → bash $INSTALL_DIR/operit-watchdog.sh autostart"
    echo "  2. 定时保活: 每30分钟 → bash $INSTALL_DIR/operit-watchdog.sh watchdog"
    echo ""
    echo -e "${CYAN}更新到最新版:${NC}"
    echo "  bash $INSTALL_DIR/operit-watchdog.sh  # 不适用"
    echo "  cd $BUILD_DIR && bash setup.sh --rebuild"
    echo ""
    echo -e "${YELLOW}提示: 构建目录 $BUILD_DIR 保留以便后续更新${NC}"
    echo -e "${YELLOW}如需释放空间: rm -rf $BUILD_DIR/node_modules $BUILD_DIR/.next${NC}"
  fi
}

main
