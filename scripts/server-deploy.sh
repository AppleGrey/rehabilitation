#!/usr/bin/env bash
# Load tar images and start backend + frontend
# Usage: cd /opt/rehabilitation && bash scripts/server-deploy.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BACKEND_TAR="$ROOT/rehabilitation-backend.tar"
FRONTEND_TAR="$ROOT/rehabilitation-frontend.tar"
COMPOSE_FILE="$ROOT/docker-compose.prod.yml"

if [[ ! -f "$BACKEND_TAR" ]]; then
  echo "错误：未找到 $BACKEND_TAR"
  exit 1
fi

if [[ ! -f "$FRONTEND_TAR" ]]; then
  echo "错误：未找到 $FRONTEND_TAR，请先在本地执行 scripts/docker-build-web-export.ps1"
  exit 1
fi

if [[ ! -f "$ROOT/.env" ]]; then
  echo "错误：未找到 .env，请复制 .env.example 并填入 API Key"
  exit 1
fi

echo ">>> 加载后端镜像..."
docker load -i "$BACKEND_TAR"

echo ">>> 加载前端镜像..."
docker load -i "$FRONTEND_TAR"

echo ">>> 启动服务..."
docker compose -f "$COMPOSE_FILE" up -d

echo ">>> 状态："
docker compose -f "$COMPOSE_FILE" ps

echo ""
echo ">>> 健康检查："
sleep 2
curl -sf "http://127.0.0.1:8080/api/health" && echo " [backend OK]" || echo "[backend FAIL]"
curl -sf -o /dev/null "http://127.0.0.1/" && echo "[frontend OK]" || echo "[frontend FAIL]"

echo ""
echo "访问 Web: http://$(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')/"
