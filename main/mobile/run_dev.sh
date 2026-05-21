#!/bin/bash
# Mac 本地开发：USB 连接平板后运行此脚本
# 用法: ./run_dev.sh
# 临时改 API: API_BASE_URL=http://1.2.3.4:8001 ./run_dev.sh

set -euo pipefail

cd "$(dirname "$0")"

# ↓ 改成你的云服务器公网 IP（不要末尾斜杠）
API_BASE_URL="${API_BASE_URL:-http://39.106.211.238:8001}"

echo "[run_dev] API_BASE_URL=$API_BASE_URL"
echo "[run_dev] Checking devices..."
flutter devices

echo "[run_dev] pub get..."
flutter pub get

echo "[run_dev] Starting flutter run (press r=hot reload, R=restart, q=quit)..."
exec flutter run --dart-define=API_BASE_URL="$API_BASE_URL"
