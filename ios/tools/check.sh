#!/usr/bin/env bash
# Сборка и проверка проекта на macOS одной командой.
#   ./tools/check.sh            — собрать для симулятора
#   ./tools/check.sh device      — собрать для устройства (нужна подпись в Xcode)
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Нет xcodegen. Установите: brew install xcodegen" >&2
  exit 1
fi

echo "==> xcodegen"
xcodegen generate

echo "==> контракт API"
python3 tools/api_probe.py || echo "ВНИМАНИЕ: API изменился, смотрите вывод выше"

if [[ "${1:-simulator}" == "device" ]]; then
  echo "==> xcodebuild (device)"
  xcodebuild -project Anixart.xcodeproj -scheme Anixart -destination 'generic/platform=iOS' build
else
  echo "==> xcodebuild (simulator)"
  xcodebuild -project Anixart.xcodeproj -scheme Anixart \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
fi

echo "OK"
