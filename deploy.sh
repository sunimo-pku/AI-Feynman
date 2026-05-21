#!/bin/bash
# deploy.sh - new-project 一键部署（前端构建 + 后端重启 + 健康检查）
#
# 用法: bash /root/new-project/deploy.sh

set -euo pipefail

PROJECT_ROOT="/root/new-project"
BACKEND_DIR="$PROJECT_ROOT/main"
FRONTEND_DIR="$PROJECT_ROOT/main/frontend"
APP_MODULE="app.main:app"
HOST="127.0.0.1"
PORT="8001"
HEALTH_URL="http://127.0.0.1:${PORT}/health"
LOG_FILE="$BACKEND_DIR/logs/uvicorn.log"

START_TS=$(date +%s)
echo "[deploy] started at $(date '+%Y-%m-%d %H:%M:%S')"

echo "[1/3] building frontend in $FRONTEND_DIR ..."
cd "$FRONTEND_DIR"
if [ ! -d "node_modules" ]; then
  echo "       node_modules missing, running npm install ..."
  npm install
fi
npm run build
echo "       frontend built -> $FRONTEND_DIR/dist"

echo "[2/3] restarting backend on port $PORT ..."
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

echo "[3/3] health check $HEALTH_URL ..."
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
