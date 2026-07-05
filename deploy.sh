#!/usr/bin/env bash
#
# deploy.sh — Open Notebook 一键编译 + 部署脚本
#
# 用法:
#   ./deploy.sh              # 单容器模式（默认，推荐）
#   ./deploy.sh --compose    # docker compose 双容器模式
#   ./deploy.sh --stop       # 停止并清理所有容器
#   ./deploy.sh --help       # 显示帮助
#
# 前置条件: Docker Engine 24+ 且已启动

set -euo pipefail

# ── 配色 ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ── 路径常量 ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="${IMAGE_NAME:-open-notebook}"
IMAGE_TAG="${IMAGE_TAG:-local}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
CONTAINER_NAME="${CONTAINER_NAME:-open-notebook}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-open-notebook}"
ENV_FILE="${ENV_FILE:-.env}"

# ── 工具函数 ──────────────────────────────────────────────
log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERR]${NC}   $*"; }
banner()    { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}\n${BOLD}$*${NC}\n${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"; }

# ── 预检 ──────────────────────────────────────────────────
check_prereqs() {
    banner "🔍 环境预检"

    # Docker
    if ! command -v docker &>/dev/null; then
        log_err "未找到 Docker，请先安装: https://docs.docker.com/engine/install/"
        exit 1
    fi
    local docker_ver
    docker_ver=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
    log_ok "Docker v${docker_ver}"

    if ! docker info &>/dev/null; then
        log_err "Docker 未运行或无权限，请启动 Docker 后重试"
        exit 1
    fi
    log_ok "Docker 守护进程运行中"

    # Docker Compose
    if docker compose version &>/dev/null; then
        log_ok "docker compose 插件可用"
    elif command -v docker-compose &>/dev/null; then
        log_warn "使用传统 docker-compose（建议升级到 docker compose 插件）"
    fi

    # 磁盘空间 (需要至少 5GB)
    local avail_gb
    avail_gb=$(df -BG . 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}' || echo "0")
    if [[ "$avail_gb" -lt 5 ]]; then
        log_warn "可用磁盘空间约 ${avail_gb}GB，建议至少 5GB"
    else
        log_ok "磁盘可用空间: ~${avail_gb}GB"
    fi

    # openssl (用于生成密钥)
    command -v openssl &>/dev/null || log_warn "未找到 openssl，将使用固定密钥"
}

# ── 环境文件 ──────────────────────────────────────────────
setup_env() {
    banner "📝 配置环境"

    if [[ -f "$ENV_FILE" ]]; then
        log_ok ".env 已存在，跳过创建"
        # 检查 ENCRYPTION_KEY 是否仍是默认值
        if grep -q "change-me-to-a-secret-string" "$ENV_FILE" 2>/dev/null; then
            log_warn "检测到默认 ENCRYPTION_KEY，自动替换为随机密钥..."
            local new_key
            new_key=$(openssl rand -hex 32 2>/dev/null || echo "auto-generated-$(date +%s)-$(hostname)")
            sed -i "s/change-me-to-a-secret-string/${new_key}/" "$ENV_FILE"
            log_ok "ENCRYPTION_KEY 已更新"
        fi
    else
        log_info "从 .env.example 创建 .env..."
        cp .env.example "$ENV_FILE"

        # 生成随机加密密钥
        local random_key
        random_key=$(openssl rand -hex 32 2>/dev/null || echo "auto-generated-$(date +%s)-$(hostname)")
        sed -i "s/change-me-to-a-secret-string/${random_key}/" "$ENV_FILE"
        log_ok ".env 已创建，ENCRYPTION_KEY 已自动生成"
    fi

    # 确保数据目录存在
    mkdir -p notebook_data surreal_data
    log_ok "数据目录已准备: notebook_data/ surreal_data/"
}

# ── 构建镜像 ──────────────────────────────────────────────
build_image() {
    local dockerfile="${1:-Dockerfile.single}"

    banner "🔨 编译 Docker 镜像 (${dockerfile})"

    log_info "开始构建 ${FULL_IMAGE}..."
    log_info "这可能需要 5-15 分钟（首次构建需要下载基础镜像和依赖）"

    docker build \
        -f "$dockerfile" \
        -t "$FULL_IMAGE" \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        "$SCRIPT_DIR"

    log_ok "镜像构建完成: ${FULL_IMAGE}"

    # 显示镜像大小
    local img_size
    img_size=$(docker image inspect "$FULL_IMAGE" --format '{{.Size}}' 2>/dev/null || echo "0")
    local img_size_mb=$((img_size / 1024 / 1024))
    log_info "镜像大小: ~${img_size_mb}MB"
}

# ── 单容器部署 ────────────────────────────────────────────
deploy_single() {
    banner "🚀 单容器部署"

    # 如果已有旧容器，先清理
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_info "停止并移除已有容器: ${CONTAINER_NAME}"
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm "$CONTAINER_NAME" 2>/dev/null || true
    fi

    log_info "启动容器..."

    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p "${WEB_PORT:-8502}:8502" \
        -p "${API_PORT:-5055}:5055" \
        -v "${SCRIPT_DIR}/notebook_data:/app/data" \
        --env-file "$ENV_FILE" \
        "$FULL_IMAGE"

    log_ok "容器已启动: ${CONTAINER_NAME}"

    # 等待服务就绪
    echo ""
    log_info "等待服务启动..."
    local max_wait=120
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if curl -sf http://localhost:${API_PORT:-5055}/health &>/dev/null; then
            log_ok "API 服务就绪 ✓"
            break
        fi
        sleep 3
        waited=$((waited + 3))
        echo -n "."
    done
    echo ""

    if [[ $waited -ge $max_wait ]]; then
        log_warn "API 未在 ${max_wait}s 内就绪，可查看日志: docker logs ${CONTAINER_NAME}"
    fi

    show_info
}

# ── Compose 部署 ──────────────────────────────────────────
deploy_compose() {
    banner "🚀 Docker Compose 部署"

    # 创建本地 compose 覆盖文件，使用本地镜像
    cat > docker-compose.local.yml <<COMPOSE
# Auto-generated by deploy.sh — 使用本地编译的镜像
services:
  surrealdb:
    image: surrealdb/surrealdb:v2
    command: start --log info --user \${SURREAL_USER:-root} --pass \${SURREAL_PASSWORD:-root} rocksdb:/mydata/mydatabase.db
    user: root
    ports:
      - "8000:8000"
    volumes:
      - ./surreal_data:/mydata
    environment:
      - SURREAL_EXPERIMENTAL_GRAPHQL=true
    restart: always

  open_notebook:
    image: ${FULL_IMAGE}
    ports:
      - "\${WEB_PORT:-8502}:8502"
      - "\${API_PORT:-5055}:5055"
    env_file:
      - ${ENV_FILE}
    environment:
      - SURREAL_URL=ws://surrealdb:8000/rpc
      - SURREAL_USER=\${SURREAL_USER:-root}
      - SURREAL_PASSWORD=\${SURREAL_PASSWORD:-root}
      - SURREAL_NAMESPACE=open_notebook
      - SURREAL_DATABASE=open_notebook
    volumes:
      - ./notebook_data:/app/data
    depends_on:
      - surrealdb
    restart: always
COMPOSE

    # 停止旧项目
    docker compose -p "$COMPOSE_PROJECT" -f docker-compose.local.yml down 2>/dev/null || true

    log_info "启动所有服务..."
    docker compose -p "$COMPOSE_PROJECT" -f docker-compose.local.yml up -d

    log_ok "Compose 服务已启动"

    # 等待
    log_info "等待 API 就绪..."
    local max_wait=120
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if curl -sf http://localhost:${API_PORT:-5055}/health &>/dev/null; then
            log_ok "API 服务就绪 ✓"
            break
        fi
        sleep 3
        waited=$((waited + 3))
        echo -n "."
    done
    echo ""

    show_info
}

# ── 显示信息 ──────────────────────────────────────────────
show_info() {
    banner "✅ 部署完成"

    echo ""
    echo -e "  ${BOLD}Web UI:${NC}     http://localhost:${WEB_PORT:-8502}"
    echo -e "  ${BOLD}API:${NC}       http://localhost:${API_PORT:-5055}"
    echo -e "  ${BOLD}API Docs:${NC}  http://localhost:${API_PORT:-5055}/docs"
    echo ""
    echo -e "  ${BOLD}常用命令:${NC}"
    echo -e "    查看日志:  docker logs -f ${CONTAINER_NAME}"
    echo -e "    停止服务:  ./deploy.sh --stop"
    echo -e "    重启服务:  docker restart ${CONTAINER_NAME}"
    echo -e "    进入容器:  docker exec -it ${CONTAINER_NAME} bash"
    echo ""
}

# ── 停止与清理 ────────────────────────────────────────────
stop_and_clean() {
    banner "🛑 停止服务"

    # 单容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_info "停止容器: ${CONTAINER_NAME}"
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm "$CONTAINER_NAME" 2>/dev/null || true
        log_ok "容器已移除"
    fi

    # Compose
    if [[ -f docker-compose.local.yml ]]; then
        log_info "停止 Compose 服务..."
        docker compose -p "$COMPOSE_PROJECT" -f docker-compose.local.yml down 2>/dev/null || true
    fi

    # 尝试原始 compose 文件
    docker compose -p "$COMPOSE_PROJECT" down 2>/dev/null || true

    log_ok "所有服务已停止"

    echo ""
    echo -e "  ${YELLOW}数据保留在:${NC}"
    echo -e "    notebook_data/  — 用户上传文件、笔记等"
    echo -e "    surreal_data/   — SurrealDB 数据库文件"
    echo ""
    echo -e "  如需完全清理: ${BOLD}rm -rf notebook_data/ surreal_data/${NC}"
}

# ── 帮助 ──────────────────────────────────────────────────
show_help() {
    echo "Open Notebook 一键部署脚本"
    echo ""
    echo "用法: ./deploy.sh [选项]"
    echo ""
    echo "选项:"
    echo "  (无参数)        单容器模式 — 编译并启动一个全功能容器（推荐）"
    echo "  --compose       双容器模式 — 编译标准镜像，使用 docker compose 部署"
    echo "  --build-only    仅编译镜像，不启动"
    echo "  --start         启动已有容器（不重新编译）"
    echo "  --stop          停止并移除容器"
    echo "  --help          显示此帮助"
    echo ""
    echo "环境变量 (可选):"
    echo "  IMAGE_NAME       镜像名称 (默认: open-notebook)"
    echo "  IMAGE_TAG        镜像标签 (默认: local)"
    echo "  CONTAINER_NAME   容器名称 (默认: open-notebook)"
    echo "  WEB_PORT         Web UI 端口 (默认: 8502)"
    echo "  API_PORT         API 端口   (默认: 5055)"
    echo "  ENV_FILE         .env 文件路径 (默认: .env)"
    echo ""
    echo "示例:"
    echo "  ./deploy.sh                           # 一键编译 + 部署"
    echo "  WEB_PORT=3000 ./deploy.sh             # 自定义端口"
    echo "  ./deploy.sh --build-only              # 只编译"
    echo "  ./deploy.sh --compose                 # 双容器模式"
}

# ── 主入口 ────────────────────────────────────────────────
main() {
    local mode="${1:-}"

    case "$mode" in
        --help|-h|help)
            show_help
            exit 0
            ;;
        --stop|stop)
            stop_and_clean
            exit 0
            ;;
        --build-only)
            check_prereqs
            setup_env
            build_image Dockerfile.single
            log_ok "镜像已编译: ${FULL_IMAGE}"
            echo ""
            echo "后续启动: ./deploy.sh --start"
            exit 0
            ;;
        --start)
            check_prereqs
            setup_env
            deploy_single
            exit 0
            ;;
        --compose)
            check_prereqs
            setup_env
            build_image Dockerfile
            deploy_compose
            exit 0
            ;;
        "")
            # 默认: 单容器一键部署
            check_prereqs
            setup_env
            build_image Dockerfile.single
            deploy_single
            exit 0
            ;;
        *)
            log_err "未知选项: $mode"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
