#!/bin/bash
# deploy.sh - AI Feynman 后端一键部署（Python API + 健康检查）
# WebSocket 反代需在 nginx 配置 `/lecture/live` Upgrade 头；长耗时 LLM/ASR/OCR
# 建议 proxy_read_timeout >= 300s。讲题回放结构化数据默认落 SQLite；
# 如后续落文件，路径由 REPLAY_STORAGE_DIR 控制。
#
# Flutter Android 客户端在本地/CI 构建，不在此脚本内编译。
# 用法: bash /root/new-project/deploy.sh

set -euo pipefail

PROJECT_ROOT="/root/new-project"
BACKEND_DIR="$PROJECT_ROOT/main"
APP_MODULE="app.main:app"
HOST="127.0.0.1"
PORT="8001"
HEALTH_URL="http://127.0.0.1:${PORT}/health"
LOG_FILE="$BACKEND_DIR/logs/uvicorn.log"

START_TS=$(date +%s)
echo "[deploy] started at $(date '+%Y-%m-%d %H:%M:%S')"

echo "[1/2] restarting backend on port $PORT ..."
cd "$BACKEND_DIR"
mkdir -p logs

if pkill -f "uvicorn $APP_MODULE --host $HOST --port $PORT" 2>/dev/null; then
  echo "       old uvicorn killed, waiting 1s ..."
  sleep 1
else
  echo "       no running uvicorn on $PORT (first deploy?)"
fi

nohup uvicorn "$APP_MODULE" --host "$HOST" --port "$PORT" \
  >> "$LOG_FILE" 2>&1 &
NEW_PID=$!
disown || true
echo "       new uvicorn pid=$NEW_PID, logs -> $LOG_FILE"

echo "[2/2] health check $HEALTH_URL ..."
sleep 2
for i in 1 2 3 4 5 6; do
  if curl -fsS --max-time 2 "$HEALTH_URL" > /dev/null; then
    ELAPSED=$(( $(date +%s) - START_TS ))
    echo "[deploy] SUCCESS in ${ELAPSED}s -- $HEALTH_URL OK"
    exit 0
  fi
  echo "       retry $i/6 ..."
  sleep 1
done

echo "[deploy] FAILED -- $HEALTH_URL not responding within 8s"
echo "         tail -n 30 $LOG_FILE"
exit 1
