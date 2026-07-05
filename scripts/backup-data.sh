#!/usr/bin/env bash
#
# backup-data.sh — 备份 Open Notebook 数据到 my_data/ 目录
# 用法: sudo ./scripts/backup-data.sh
# 之后: sudo git add my_data/ && sudo git commit -m "backup data" && sudo git push
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="$PROJECT_DIR/my_data"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.local.yml"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERR]${NC}   $*"; }

mkdir -p "$BACKUP_DIR"

log_info "停服务以保证数据一致性..."
docker compose -f "$COMPOSE_FILE" down
log_ok "服务已停止"

log_info "备份 surreal_data/..."
rm -rf "$BACKUP_DIR/surreal_data"
cp -r "$PROJECT_DIR/surreal_data" "$BACKUP_DIR/surreal_data"
log_ok "surreal_data 备份完成 ($(du -sh "$BACKUP_DIR/surreal_data" | cut -f1))"

log_info "备份 notebook_data/..."
rm -rf "$BACKUP_DIR/notebook_data"
cp -r "$PROJECT_DIR/notebook_data" "$BACKUP_DIR/notebook_data"
log_ok "notebook_data 备份完成 ($(du -sh "$BACKUP_DIR/notebook_data" | cut -f1))"

log_info "恢复服务..."
docker compose -f "$COMPOSE_FILE" up -d
log_ok "服务已恢复"

echo ""
log_ok "✅ 备份完成！数据在 $BACKUP_DIR"
echo ""
echo "  推送至 GitHub:"
echo "    cd $PROJECT_DIR"
echo "    git add my_data/"
echo "    git commit -m \"backup: $(date +%Y-%m-%d) 数据备份\""
echo "    git push"
echo ""
