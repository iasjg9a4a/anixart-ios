#!/usr/bin/env bash
# Проверка компиляции «ядра» клиента (модели + API-клиент) без Xcode и без iOS SDK.
# Работает на macOS и на Linux (WSL/Docker/CI) — нужен только swiftc 5.9+.
#
#   ./tools/core_check.sh
#
# SwiftUI/WebKit/Security здесь не проверяются: для них нужен macOS и Xcode.
set -euo pipefail

cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/TokenStoreStub.swift" <<'SWIFT'
import Foundation

// Заглушка Keychain-хранилища: на Linux модуля Security нет.
final class TokenStore {
    static let shared = TokenStore()
    private(set) var token: String?
    private init() {}
    func save(_ value: String) { token = value }
    func clear() { token = nil }
}
SWIFT

echo "==> swiftc --version"
swiftc --version

echo "==> модели"
swiftc -typecheck Anixart/Models/Models.swift

echo "==> API-клиент"
cat "$TMP/TokenStoreStub.swift" Anixart/Models/Models.swift Anixart/Core/RetryPolicy.swift Anixart/Core/APIClient.swift > "$TMP/core.swift"
swiftc -typecheck "$TMP/core.swift"

echo "==> сборка проверки моделей"
swiftc -o "$TMP/modelcheck" Anixart/Models/Models.swift tools/ModelCheck/main.swift

if [ -d tools/fixtures ]; then
  echo "==> прогон на реальных ответах API"
  "$TMP/modelcheck" tools/fixtures
else
  echo "!! нет tools/fixtures — выполните: python3 tools/fetch_fixtures.py"
fi

echo "OK"
