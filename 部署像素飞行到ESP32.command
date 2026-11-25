#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ ! -f bridge.local.json || ! -f app/config.json ]]; then
  python3 host/configure.py
fi

echo "=== 1. 上传 /apps/pixel_flight 文件到 ESP-Mosaico 并逐字节校验 ==="
python3 host/device.py upload

echo "=== 2. 检查被动接收器与注册 Works 入口 ==="
python3 host/device.py recover

echo "部署完成！可在网页点击“连接 ESP-Mosaico”或在设备 Works -> Installed -> 像素飞行 打开。"
