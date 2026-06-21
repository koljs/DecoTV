#!/usr/bin/env bash
# ============================================================================
# DecoTV 构建打包脚本
# 在开发机（Linux/macOS）上运行，生成 decotv-deploy.tar.gz 传输到手机
#
# 用法:
#   ./deploy/build.sh              # 构建并打包
#   ./deploy/build.sh --skip-build # 跳过构建，仅重新打包
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/deploy/dist"
ARCHIVE_NAME="decotv-deploy.tar.gz"

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SKIP_BUILD=false
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=true

cd "$PROJECT_ROOT"

# ---- 1. 检查依赖 ----
info "检查构建依赖..."
command -v node >/dev/null 2>&1 || error "需要 Node.js (v20+)"
command -v pnpm >/dev/null 2>&1 || error "需要 pnpm (npm i -g pnpm)"
node -v | grep -qE '^v(2[0-9]|[3-9])' || warn "建议使用 Node.js 20+，当前: $(node -v)"

# ---- 2. 安装依赖 ----
if [[ "$SKIP_BUILD" == false ]]; then
  info "安装项目依赖..."
  pnpm install --frozen-lockfile 2>/dev/null || pnpm install

  # ---- 3. 构建 (standalone 模式) ----
  info "构建 standalone 产物 (STANDALONE=true)..."
  STANDALONE=true pnpm build
else
  warn "跳过构建步骤 (--skip-build)"
fi

# ---- 4. 检查构建产物 ----
STANDALONE_DIR="$PROJECT_ROOT/.next/standalone"
[[ -d "$STANDALONE_DIR" ]] || error "standalone 产物不存在: $STANDALONE_DIR"
[[ -f "$STANDALONE_DIR/server.js" ]] || error "server.js 不存在，构建可能失败"

info "构建产物检查通过"

# ---- 5. 组装部署目录 ----
info "组装部署包..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/decotv"

# standalone 核心
cp -r "$STANDALONE_DIR/." "$OUTPUT_DIR/decotv/"

# .next/static (standalone 不包含此目录)
mkdir -p "$OUTPUT_DIR/decotv/.next/static"
cp -r "$PROJECT_ROOT/.next/static/." "$OUTPUT_DIR/decotv/.next/static/"

# 覆盖 public 资源 (standalone 内的 public 可能不完整)
rm -rf "$OUTPUT_DIR/decotv/public"
cp -r "$PROJECT_ROOT/public" "$OUTPUT_DIR/decotv/public"

# 覆盖 scripts 目录 (start.js 依赖 generate-manifest.js)
rm -rf "$OUTPUT_DIR/decotv/scripts"
cp -r "$PROJECT_ROOT/scripts" "$OUTPUT_DIR/decotv/scripts"

# start.js 入口
cp "$PROJECT_ROOT/start.js" "$OUTPUT_DIR/decotv/start.js"

# 清理 standalone 产物中的冗余嵌套目录 (Next.js standalone 会复制整个项目结构)
rm -rf "$OUTPUT_DIR/decotv/src" \
       "$OUTPUT_DIR/decotv/docs" \
       "$OUTPUT_DIR/decotv/__tests__" \
       "$OUTPUT_DIR/decotv/.husky" \
       "$OUTPUT_DIR/decotv/.vscode" \
       "$OUTPUT_DIR/decotv/.github" \
       "$OUTPUT_DIR/decotv/deploy" \
       "$OUTPUT_DIR/decotv/SECURITY.md" \
       "$OUTPUT_DIR/decotv/LICENSE" \
       "$OUTPUT_DIR/decotv/CHANGELOG"

# 部署脚本
cp "$SCRIPT_DIR/install.sh" "$OUTPUT_DIR/install.sh"
cp "$SCRIPT_DIR/decotv.sh" "$OUTPUT_DIR/decotv.sh"
chmod +x "$OUTPUT_DIR/install.sh" "$OUTPUT_DIR/decotv.sh"

# 生成默认 .env.local (手机端可编辑)
cat > "$OUTPUT_DIR/decotv/.env.local" << 'ENVEOF'
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

# 豆瓣代理 (手机直连可能需要代理)
# NEXT_PUBLIC_DOUBAN_PROXY_TYPE=server
# NEXT_PUBLIC_DOUBAN_IMAGE_PROXY_TYPE=server
ENVEOF

# ---- 6. 打包 ----
info "压缩部署包..."
cd "$OUTPUT_DIR"
tar -czf "$ARCHIVE_NAME" decotv/ install.sh decotv.sh

# 计算大小
SIZE=$(du -sh "$ARCHIVE_NAME" | cut -f1)
FILE_COUNT=$(find decotv -type f | wc -l)

info "============================================"
info "构建完成!"
info "  输出: $OUTPUT_DIR/$ARCHIVE_NAME"
info "  大小: $SIZE"
info "  文件数: $FILE_COUNT"
info ""
info "传输到手机:"
info "  adb push $OUTPUT_DIR/$ARCHIVE_NAME /sdcard/Download/"
info ""
info "然后在 Operit Ubuntu 终端中:"
info "  cd /root && tar -xzf /sdcard/Download/decotv-deploy.tar.gz"
info "  bash install.sh"
info "============================================"
