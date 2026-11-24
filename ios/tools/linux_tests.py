#!/usr/bin/env python3
"""Прогон юнит-тестов Anixart iOS на Compiler Explorer (Swift 6.4.2, Linux x86-64).

Замена `xcodebuild test` на машине без macOS. Каждый suite собирается в один
Swift-файл (мини-XCTest-шим + Linux-заглушки платформ + реальные исходники проекта +
реальный тестовый файл + сгенерированный runner), отправляется в Compiler Explorer
и **исполняется** там (`filters.execute` + `executorRequest`), так что ассерты
действительно выполняются. Всё, что не нужно для Linux, вырезается/подменяется так,
как описано в `ios/tools/LinuxTestRunner.md`.

Запуск (из каталога `ios/`):

    python tools/linux_tests.py                       # все 8 suite / 68 тестов
    python tools/linux_tests.py --only PlaybackTests  # один класс
    python tools/linux_tests.py --only PlaybackTests,StorageTests
    python tools/linux_tests.py --typecheck           # только компиляция, без запуска
    python tools/linux_tests.py --json report.json    # плюс per-test отчёт в JSON
    python tools/linux_tests.py --dump                # собрать блобы локально (отладка)

Требуется Python 3.8+ и сеть до godbolt.org; Swift/Xcode на машине не нужны.
Код возврата: 0 — все выбранные suite'ы без FAIL и без ошибок компиляции, 1 — иначе.

Внимание: Compiler Explorer — публичный сервис без SLA. Скрипт ходит в него
последовательно (см. `--delay`) и повторяет запрос при 429/5xx; без сети уровень
считается непройденным, а не «зелёным».
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

# --------------------------------------------------------------------------- #
# Пути и константы
# --------------------------------------------------------------------------- #

HERE = pathlib.Path(__file__).resolve().parent   # <repo>/ios/tools
IOS = HERE.parent                                 # <repo>/ios
SRC = IOS / "Anixart"
TEST_DIR = IOS / "AnixartTests"

CE_URL = "https://godbolt.org/api/compiler/swift642/compile"
CE_COMPILER = "swift642"                          # Swift 6.4.2, Linux x86-64
CE_HOST = "godbolt.org"
HEADERS = {
    "Accept": "application/json",
    "Content-Type": "application/json",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Anixart-iOS-local-tests",
}


def _utf8_console() -> None:
    """Windows-консоль может быть в cp1251: не падать на кириллице/стрелках."""
    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name, None)
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except (ValueError, OSError):
                pass


# --------------------------------------------------------------------------- #
# Платформенные заглушки: на Linux нет Darwin/UIKit/Combine/Security
# --------------------------------------------------------------------------- #

PRELUDE = r'''
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - mini-XCTest runtime (Linux replacement for the XCTest module)

final class AssertionCollector {
    static var failures: [String] = []
    static func note(_ text: String, file: StaticString, line: UInt) {
        failures.append("\(file):\(line): \(text)")
    }
}

class XCTestCase {
    func setUp() {}
    func tearDown() {}
}

func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    AssertionCollector.note("XCTFail: \(message)", file: file, line: line)
}

func XCTAssertEqual<T: Equatable>(_ expression1: @autoclosure () throws -> T?,
                                  _ expression2: @autoclosure () throws -> T?,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try expression1()
        let b = try expression2()
        if a != b {
            AssertionCollector.note("XCTAssertEqual failed: \(String(describing: a)) != \(String(describing: b)) \(message())", file: file, line: line)
        }
    } catch {
        AssertionCollector.note("XCTAssertEqual threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertNotEqual<T: Equatable>(_ expression1: @autoclosure () throws -> T?,
                                     _ expression2: @autoclosure () throws -> T?,
                                     _ message: @autoclosure () -> String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try expression1()
        let b = try expression2()
        if a == b {
            AssertionCollector.note("XCTAssertNotEqual failed: both \(String(describing: a)) \(message())", file: file, line: line)
        }
    } catch {
        AssertionCollector.note("XCTAssertNotEqual threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertEqual<T: FloatingPoint>(_ expression1: @autoclosure () throws -> T,
                                      _ expression2: @autoclosure () throws -> T,
                                      accuracy: T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    do {
        let a = try expression1()
        let b = try expression2()
        if abs(a - b) > accuracy {
            AssertionCollector.note("XCTAssertEqual(accuracy) failed: \(a) != \(b) +- \(accuracy) \(message())", file: file, line: line)
        }
    } catch {
        AssertionCollector.note("XCTAssertEqual(accuracy) threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertNil(_ expression: @autoclosure () throws -> Any?,
                  _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        if let value = try expression() {
            AssertionCollector.note("XCTAssertNil failed: \(value) \(message())", file: file, line: line)
        }
    } catch {
        AssertionCollector.note("XCTAssertNil threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertNotNil(_ expression: @autoclosure () throws -> Any?,
                     _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() == nil {
            AssertionCollector.note("XCTAssertNotNil failed \(message())", file: file, line: line)
        }
    } catch {
        AssertionCollector.note("XCTAssertNotNil threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool,
                   _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !expression() {
            AssertionCollector.note("XCTAssertTrue failed \(message())", file: file, line: line)
        }
    } catch {
        AssertionCollector.note("XCTAssertTrue threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool,
                    _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() {
            AssertionCollector.note("XCTAssertFalse failed \(message())", file: file, line: line)
        }
    } catch {
        AssertionCollector.note("XCTAssertFalse threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T,
                         _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try expression()
    } catch {
        AssertionCollector.note("XCTAssertNoThrow failed: threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
                             _ message: @autoclosure () -> String = "",
                             file: StaticString = #filePath, line: UInt = #line,
                             _ errorHandler: (Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        AssertionCollector.note("XCTAssertThrowsError failed: no error thrown \(message())", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

func XCTAssertGreaterThan<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                         _ expression2: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !(expression1() > expression2()) {
            AssertionCollector.note("XCTAssertGreaterThan failed \(message())", file: file, line: line)
        }
    } catch {
        AssertionCollector.note("XCTAssertGreaterThan threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertGreaterThanOrEqual<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                                _ expression2: @autoclosure () throws -> T,
                                                _ message: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !(expression1() >= expression2()) {
            AssertionCollector.note("XCTAssertGreaterThanOrEqual failed \(message())", file: file, line: line)
        }
    } catch {
        AssertionCollector.note("XCTAssertGreaterThanOrEqual threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertLessThan<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                      _ expression2: @autoclosure () throws -> T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !(expression1() < expression2()) {
            AssertionCollector.note("XCTAssertLessThan failed \(message())", file: file, line: line)
        }
    } catch {
        AssertionCollector.note("XCTAssertLessThan threw \(error) \(message())", file: file, line: line)
    }
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ expression1: @autoclosure () throws -> T,
                                             _ expression2: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !(expression1() <= expression2()) {
            AssertionCollector.note("XCTAssertLessThanOrEqual failed \(message())", file: file, line: line)
        }
    } catch {
        AssertionCollector.note("XCTAssertLessThanOrEqual threw \(error) \(message())", file: file, line: line)
    }
}

struct UnwrapFailure: Error {}
func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?,
                  _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try expression() else {
        AssertionCollector.note("XCTUnwrap failed: \(message())", file: file, line: line)
        throw UnwrapFailure()
    }
    return value
}

// MARK: - Combine shim (Linux has no Combine module)
// Only the surface the project uses from Foundation-only files.

protocol ObservableObject: AnyObject {}

@propertyWrapper
struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    var projectedValue: Published<Value> { self }
}

// MARK: - Security/Keychain shim (Linux has no Security module)
// In-memory replacement with the same surface APIClient/tests use.

final class TokenStore {
    static let shared = TokenStore()
    private(set) var token: String?
    private init() {}
    func save(_ value: String) { token = value }
    func clear() { token = nil }
}

// MARK: - NSUserActivity shim (Linux has no NSUserActivity)

final class NSUserActivity {
    var webpageURL: URL?
    init(webpageURL: URL? = nil) { self.webpageURL = webpageURL }
}
'''

RUNNER_TEMPLATE = r'''
// MARK: - Linux runner (generated)

var ceTotal = 0
var cePassed = 0
var ceFailed = 0
var ceCurrent = ""

func ceBegin(_ name: String) -> Int {
    ceCurrent = name
    ceTotal += 1
    return AssertionCollector.failures.count
}

func ceEnd(_ before: Int) {
    let added = AssertionCollector.failures.count - before
    if added == 0 {
        cePassed += 1
        print("PASS \(ceCurrent)")
    } else {
        ceFailed += 1
        print("FAIL \(ceCurrent) [\(added) failed assertions]")
    }
}

func ceRun(_ name: String, _ body: () throws -> Void) {
    let before = ceBegin(name)
    do { try body() } catch { AssertionCollector.note("THREW \(name): \(error)", file: #filePath, line: 0) }
    ceEnd(before)
}

func ceRunAsync(_ name: String, _ body: () async throws -> Void) async {
    let before = ceBegin(name)
    do { try await body() } catch { AssertionCollector.note("THREW \(name): \(error)", file: #filePath, line: 0) }
    ceEnd(before)
}

let ceSuite = __CLASS__()
__CALLS__
print("CE-SUMMARY suite=__SUITE__ total=\(ceTotal) passed=\(cePassed) failed=\(ceFailed)")
if ceFailed == 0 && AssertionCollector.failures.isEmpty {
    print("CE-RESULT: ALL PASSED")
} else {
    print("CE-RESULT: FAILURES")
    for failure in AssertionCollector.failures { print("CE-FAIL: \(failure)") }
}
'''

# --------------------------------------------------------------------------- #
# Преобразования исходников
# --------------------------------------------------------------------------- #

PLATFORM_IMPORTS = {
    "XCTest", "SwiftUI", "UIKit", "Combine", "Security",
    "AVFoundation", "AVKit", "WebKit",
}
IMPORT_RE = re.compile(r"^\s*(?:@testable\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)\s*$")


class BuildError(Exception):
    """Блоб не собирается (маркер не найден, нет файла, нет фикстур...)."""


def strip_platform_imports(text: str) -> str:
    """Убирает импорты модулей, которых нет на Linux, и `@testable import Anixart`."""
    out = []
    for line in text.splitlines():
        m = IMPORT_RE.match(line)
        if m and (m.group(1) in PLATFORM_IMPORTS or m.group(1) == "Anixart"):
            continue
        out.append(line)
    return "\n".join(out)


def cut_at(text: str, marker: str) -> str:
    idx = text.find(marker)
    if idx < 0:
        raise BuildError(f"marker not found: {marker!r}")
    return text[:idx]


def transform_video_quality(text: str) -> str:
    # VideoQualityMenu — SwiftUI View; логика селектора выше — Foundation-only.
    return cut_at(text, "// MARK: - Меню")


def transform_offline_integration(text: str) -> str:
    # OfflineDataBadge — SwiftUI View; сам OfflineIntegration — Foundation-only.
    return cut_at(text, "// MARK: - Индикатор")


def transform_image_cache(text: str) -> str:
    # CachedAsyncImage — SwiftUI/UIKit View; actor выше — Foundation-only.
    return cut_at(text, "/// Замена `AsyncImage`")


def transform_infra_test_file(text: str) -> str:
    # В InfrastructureTests.swift ещё и StorageTests, которому нужны другие исходники.
    return cut_at(text, "// MARK: - Дисковый кэш и прогресс просмотра")


def transform_storage_test_file(text: str) -> str:
    marker = "// MARK: - Дисковый кэш и прогресс просмотра"
    idx = text.find(marker)
    if idx < 0:
        raise BuildError("storage marker not found")
    return text[idx:]


def transform_fixtures_test_file(text: str) -> str:
    old = "        try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent(name))"
    new = "        Data(try EmbeddedFixtures.text(name).utf8)"
    if old not in text:
        raise BuildError("fixtures loader line not found")
    return text.replace(old, new, 1)


def build_fixture_block() -> str:
    """Вшивает ios/tools/fixtures/*.json как raw-Swift-строки (байт в байт)."""
    fixtures_dir = IOS / "tools" / "fixtures"
    names = sorted(p.name for p in fixtures_dir.glob("*.json"))
    if not names:
        raise BuildError(f"no fixtures found in {fixtures_dir}")
    parts = [
        "// MARK: - Embedded fixtures (ios/tools/fixtures, verbatim)",
        "enum EmbeddedFixtures {",
        "    static let texts: [String: String] = [",
    ]
    for name in names:
        raw = (fixtures_dir / name).read_text(encoding="utf-8-sig")
        if '"""' in raw:
            raise BuildError(f"fixture {name} contains a triple quote; raw literal unsafe")
        # страховка: строка, которая закрыла бы raw-литерал
        raw = raw.replace('"""#', '"""\\#')
        parts.append(f'        "{name}": #"""')
        parts.append(raw.rstrip("\n"))
        parts.append('"""#,')
    parts += [
        "    ]",
        "    enum FixtureError: Error { case missing(String) }",
        "    static func text(_ name: String) throws -> String {",
        "        guard let value = texts[name] else { throw FixtureError.missing(name) }",
        "        return value",
        "    }",
        "}",
    ]
    return "\n".join(parts)


# --------------------------------------------------------------------------- #
# Suite'ы: что именно компилируется в одном блобе
# --------------------------------------------------------------------------- #

SUITES = {
    "ReleaseVideoTests": {
        "test_file": "ReleaseVideoTests.swift",
        "sources": [
            "Features/Player/PlaybackTarget.swift",
            "Features/Release/ReleaseVideoModels.swift",
        ],
    },
    "ModelsDecodingTests": {
        "test_file": "ModelsDecodingTests.swift",
        "sources": ["Models/Models.swift"],
        "test_transform": transform_fixtures_test_file,
        "fixtures": True,
    },
    "PlaybackTests": {
        "test_file": "PlaybackTests.swift",
        "sources": [
            "Models/Models.swift",
            "Features/Player/PlaybackTarget.swift",
            "Features/Player/PlaybackResolver.swift",
        ],
    },
    "ProviderResolverTests": {
        "test_file": "ProviderResolverTests.swift",
        "sources": [
            "Features/Player/PlaybackTarget.swift",
            "Features/Player/VideoQuality.swift",
            "Features/Player/RutubeResolver.swift",
            "Features/Player/AniLibriaResolver.swift",
            "Features/Player/AnixPlayerResolver.swift",
            "Features/Player/SibnetResolver.swift",
        ],
        "source_transforms": {"Features/Player/VideoQuality.swift": [transform_video_quality]},
    },
    "SibnetResolverTests": {
        "test_file": "SibnetResolverTests.swift",
        "sources": [
            "Features/Player/PlaybackTarget.swift",
            "Features/Player/SibnetResolver.swift",
        ],
    },
    "FallbackTests": {
        "test_file": "FallbackTests.swift",
        "sources": [
            "Models/Models.swift",
            "Core/APIClient.swift",
            "Core/RetryPolicy.swift",
            "Features/Player/PlaybackTarget.swift",
            "Features/Player/PlaybackCandidate.swift",
            "Features/Player/PlaybackResolver.swift",
            "Features/Player/SourceFallbackService.swift",
        ],
    },
    "InfrastructureTests": {
        "test_file": "InfrastructureTests.swift",
        "test_transform": transform_infra_test_file,
        "sources": [
            "Models/Models.swift",
            "Core/APIClient.swift",
            "Core/RetryPolicy.swift",
            "App/DeepLinkRouter.swift",
        ],
    },
    "StorageTests": {
        "test_file": "InfrastructureTests.swift",
        "test_transform": transform_storage_test_file,
        "sources": [
            "Models/Models.swift",
            "Core/APIClient.swift",
            "Core/RetryPolicy.swift",
            "Core/OfflineCache.swift",
            "Core/OfflineIntegration.swift",
            "Core/ImageCache.swift",
            "Features/Player/PlaybackProgress.swift",
        ],
        "source_transforms": {
            "Core/OfflineIntegration.swift": [transform_offline_integration],
            "Core/ImageCache.swift": [transform_image_cache],
        },
    },
    "APIClientTests": {
        "test_file": "APIClientTests.swift",
        "sources": [
            "Models/Models.swift",
            "Core/APIClient.swift",
            "Core/RetryPolicy.swift",
        ],
    },
}

SUITE_ORDER = list(SUITES)
EXPECTED_TESTS = 77          # 9 блобов, 8 файлов тестов (InfrastructureTests делится)


# --------------------------------------------------------------------------- #
# Сборка блоба
# --------------------------------------------------------------------------- #

def read_source(rel: str) -> str:
    path = SRC / rel
    if not path.is_file():
        raise BuildError(f"source not found: Anixart/{rel}")
    return path.read_text(encoding="utf-8-sig")


def build_suite(name: str):
    """Возвращает (blob, spans, class_name, [test_methods]) для одного suite."""
    cfg = SUITES[name]
    parts = []  # [(label, text)]

    parts.append(("<platform-shim>", PRELUDE))

    for rel in cfg["sources"]:
        text = read_source(rel)
        for transform in cfg.get("source_transforms", {}).get(rel, []):
            text = transform(text)
        text = strip_platform_imports(text)
        parts.append((f"Anixart/{rel}", text))

    if cfg.get("fixtures"):
        parts.append(("<fixtures>", build_fixture_block()))

    test_path = TEST_DIR / cfg["test_file"]
    if not test_path.is_file():
        raise BuildError(f"test file not found: AnixartTests/{cfg['test_file']}")
    test_text = test_path.read_text(encoding="utf-8-sig")
    transform = cfg.get("test_transform")
    if transform:
        test_text = transform(test_text)
    test_text = strip_platform_imports(test_text)
    parts.append((f"AnixartTests/{cfg['test_file']}", test_text))

    # Класс и тестовые методы берём из реального тестового файла.
    classes = re.findall(r"class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase", test_text)
    if len(classes) != 1:
        raise BuildError(f"{name}: expected exactly one XCTestCase class, got {classes}")
    klass = classes[0]

    methods = re.findall(
        r"func\s+(test[A-Za-z0-9_]*)\s*\(\s*\)\s*(async\s+)?(?:throws\s*)?\{",
        test_text,
    )
    if not methods:
        raise BuildError(f"{name}: no test methods found")

    calls = []
    for method, is_async in methods:
        if is_async:
            calls.append(
                f'await ceRunAsync("{method}") {{ () async throws -> Void in\n'
                f"    ceSuite.setUp()\n    defer {{ ceSuite.tearDown() }}\n"
                f"    try await ceSuite.{method}()\n}}"
            )
        else:
            calls.append(
                f'ceRun("{method}") {{\n'
                f"    ceSuite.setUp()\n    defer {{ ceSuite.tearDown() }}\n"
                f"    try ceSuite.{method}()\n}}"
            )

    runner = (RUNNER_TEMPLATE
              .replace("__CLASS__", klass)
              .replace("__CALLS__", "\n".join(calls))
              .replace("__SUITE__", name))
    parts.append(("<runner>", runner))

    blob, spans, line = [], [], 1
    for label, text in parts:
        n = text.count("\n") + 1
        spans.append((line, line + n - 1, label))
        blob.append(text)
        line += n + 1
    return "\n\n".join(blob), spans, klass, [m for m, _ in methods]


def locate(spans, blob_line: int):
    for start, end, label in spans:
        if start <= blob_line <= end:
            return label, blob_line - start + 1
    return None, blob_line


# --------------------------------------------------------------------------- #
# Compiler Explorer: POST + execute, повторы при лимитах
# --------------------------------------------------------------------------- #

DIAG_RE = re.compile(
    r"^(?:<source>|source|example|output\.[a-z]+)?:?(\d+):(\d+):\s*(error|warning|note):\s*(.*)$"
)
RETRYABLE_HTTP = {408, 425, 429, 500, 502, 503, 504}


class CEError(Exception):
    """CE недоступен или ответил ошибкой, которую не удалось обойти повтором."""


def post(source: str, execute: bool = True, timeout: float = 300.0,
         retries: int = 3, backoff: float = 4.0):
    """POST блоба в CE. execute=True — собрать и запустить, False — только компиляция."""
    options = {
        "userArguments": "",
        "filters": {"execute": execute},
    }
    if execute:
        options["compilerOptions"] = {"executorRequest": True}
    payload = json.dumps({
        "source": source,
        "options": options,
        "lang": "swift",
    }).encode("utf-8")

    last_error = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(CE_URL, data=payload, headers=HEADERS, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8", "replace")
            try:
                return json.loads(raw)
            except json.JSONDecodeError as exc:
                last_error = f"non-JSON response from CE ({len(raw)} bytes): {raw[:200]!r}"
                if attempt >= retries:
                    raise CEError(last_error) from exc
        except urllib.error.HTTPError as exc:
            body = exc.read()[:300]
            last_error = f"CE HTTP {exc.code}: {body!r}"
            if exc.code in RETRYABLE_HTTP and attempt < retries:
                wait = backoff * (2 ** attempt)
                retry_after = (exc.headers or {}).get("Retry-After") if exc.headers else None
                if retry_after and str(retry_after).strip().isdigit():
                    wait = max(wait, min(float(retry_after), 60.0))
                print(f"  CE HTTP {exc.code}; повтор через {wait:.0f} с "
                      f"(попытка {attempt + 1}/{retries})")
                time.sleep(wait)
                continue
            raise CEError(last_error) from exc
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as exc:
            last_error = f"CE request failed: {exc}"
            if attempt < retries:
                wait = backoff * (2 ** attempt)
                print(f"  {last_error}; повтор через {wait:.0f} с "
                      f"(попытка {attempt + 1}/{retries})")
                time.sleep(wait)
                continue
            raise CEError(last_error) from exc
        else:
            # JSON decode error без исключения: повторяем как сетевую проблему
            if attempt < retries:
                wait = backoff * (2 ** attempt)
                print(f"  {last_error}; повтор через {wait:.0f} с (попытка {attempt + 1}/{retries})")
                time.sleep(wait)
                continue
            raise CEError(last_error or "CE returned an empty response")
    raise CEError(last_error or "CE request failed")


def _text_items(seq) -> list:
    out = []
    if not isinstance(seq, list):
        return out
    for item in seq:
        if isinstance(item, dict):
            text = item.get("text")
            if isinstance(text, str):
                out.append(text)
        elif isinstance(item, str):
            out.append(item)
    return out


def collect_diagnostics(result, spans):
    """Разбирает stderr CE и переводит строки блоба обратно в файлы проекта."""
    errors, other = [], []
    for text in _text_items(result.get("stderr")):
        text = text.rstrip()
        if not text:
            continue
        m = DIAG_RE.match(text)
        if m:
            kind = m.group(3)
            where_label, src_line = locate(spans, int(m.group(1)))
            entry = f"{kind} {where_label or '<blob>'}:{src_line}: {m.group(4)}"
            if kind == "error":
                errors.append(entry)
            elif kind in ("warning", "note"):
                other.append(entry)
        elif re.match(r"^\s*(\d+\s*\|.*|\|.*|`- .*|\[\S+\]: <.*)$", text):
            # продолжение диагностики компилятора (фрагмент исходника/ссылка) — не отдельная строка
            continue
        else:
            other.append("raw: " + text)
    return errors, other


def run_suite(name: str, typecheck: bool = False, timeout: float = 300.0,
              retries: int = 3) -> dict:
    """Собирает блоб, отправляет в CE, печатает PASS/FAIL, возвращает запись отчёта."""
    source, spans, klass, methods = build_suite(name)
    mode = "typecheck" if typecheck else "compile+execute"
    blob_size = f"{len(source):,}".replace(",", " ")
    print(f"[{name}] {mode}: блоб {blob_size} символов, класс {klass}, "
          f"тестов {len(methods)}")
    started = time.monotonic()
    try:
        result = post(source, execute=not typecheck, timeout=timeout, retries=retries)
    except CEError as exc:
        print(f"  CE ERROR: {exc}")
        return {"suite": name, "klass": klass, "tests": len(methods),
                "mode": mode, "blob": len(source), "error": str(exc)}

    elapsed = time.monotonic() - started
    errors, other = collect_diagnostics(result, spans)
    build = result.get("buildResult") or {}
    code = result.get("code")
    did_execute = bool(result.get("didExecute"))
    timed_out = bool(result.get("timedOut"))
    print(f"  http-ok code={code} build={build.get('code')} didExecute={did_execute} "
          f"timedOut={timed_out} compile_errors={len(errors)} ({elapsed:.1f} с)")
    for entry in errors:
        print("  " + entry)
    if not errors:
        for entry in other[:6]:
            print("  (diag) " + entry)

    base = {
        "suite": name, "klass": klass, "tests": len(methods), "mode": mode,
        "blob": len(source), "elapsed_s": round(elapsed, 2),
        "code": code, "build": build.get("code"),
        "didExecute": did_execute, "timedOut": timed_out,
        "compile_errors": errors,
    }

    if typecheck:
        base["passed"] = len(methods) if not errors and code == 0 else 0
        base["failed"] = 0 if not errors and code == 0 else 1
        if errors:
            print(f"  TYPECHECK FAILED: {len(errors)} compile error(s)")
        else:
            print("  TYPECHECK OK (компилируется без ошибок)")
        return base

    stdout = _text_items(result.get("stdout"))
    per_test, failures, summary = [], [], None
    for line in stdout:
        clean = line.rstrip("\n")
        if clean.startswith("PASS "):
            per_test.append(("PASS", clean[5:]))
        elif clean.startswith("FAIL "):
            per_test.append(("FAIL", clean[5:].split(" [")[0]))
        elif clean.startswith("CE-SUMMARY"):
            summary = clean
        elif clean.startswith("CE-FAIL: "):
            failures.append(clean[9:])
        elif clean.startswith("THREW "):
            per_test.append(("THREW", clean[6:].split(":")[0]))

    for status, test in per_test:
        print(f"  {status} {test}")
    if summary:
        print("  " + summary)

    mapped = []
    for failure in failures:
        m = re.match(r"^(.*?):(\d+): (.*)$", failure)
        mapped.append(failure)
        if m:
            label, line_no = locate(spans, int(m.group(2)))
            mapped[-1] = f"{label or '<blob>'}:{line_no}: {m.group(3)}"
    for entry in mapped:
        print("  CE-FAIL " + entry)

    passed = sum(1 for status, _ in per_test if status == "PASS")
    failed = sum(1 for status, _ in per_test if status != "PASS")
    if not per_test and not errors:
        # Исполнение не состоялось (нет stdout) — это не «PASS».
        print("  NO TEST OUTPUT: исполнение на CE не состоялось")
        base["error"] = "no test output (execution did not happen)"
        base["passed"] = 0
        base["failed"] = len(methods)
        return base
    if did_execute is False and not errors:
        print("  WARNING: CE не подтвердил исполнение (didExecute=false)")

    print(f"  => {name}: {passed}/{len(methods)} passed, {failed} failed")
    base.update({
        "passed": passed,
        "failed": failed,
        "per_test": per_test,
        "failures": mapped,
        "summary": summary,
        "raw_stdout": stdout,
    })
    if timed_out:
        # Частичный вывод после таймаута не считается прогоном.
        print("  CE TIMEOUT: исполнение прервано по таймауту")
        base["error"] = "CE execution timed out"
    elif passed + failed != len(methods):
        print(f"  INCOMPLETE: отчитались {passed + failed} из {len(methods)} тестов")
        base["incomplete"] = True
    return base


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def write_json_report(path_str: str, payload: dict) -> None:
    """Пишет JSON-отчёт (UTF-8, LF); при необходимости создаёт каталог."""
    path = pathlib.Path(path_str)
    if path.parent and str(path.parent) not in ("", "."):
        path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(f"отчёт: {path}")


def resolve_suites(selectors: list) -> list:
    if not selectors:
        return list(SUITE_ORDER)
    wanted = []
    for raw in selectors:
        for part in str(raw).split(","):
            part = part.strip()
            if not part:
                continue
            match = next((n for n in SUITE_ORDER if n.lower() == part.lower()), None)
            if match is None:
                raise SystemExit(
                    f"неизвестный suite/класс: {part!r}\n"
                    f"известные: {', '.join(SUITE_ORDER)}"
                )
            if match not in wanted:
                wanted.append(match)
    if not wanted:
        raise SystemExit("не выбрано ни одного suite")
    return wanted


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="linux_tests.py",
        description="Прогон юнит-тестов Anixart iOS на Compiler Explorer (Swift 6.4.2 Linux).",
    )
    parser.add_argument(
        "--only", action="append", default=[], metavar="КЛАСС",
        help="только указанный suite/класс (можно несколько раз или через запятую)",
    )
    parser.add_argument(
        "--typecheck", action="store_true",
        help="только компиляция (filters.execute=false), без запуска тестов",
    )
    parser.add_argument(
        "--json", metavar="ФАЙЛ",
        help="сохранить per-test отчёт в JSON (например, report.json)",
    )
    parser.add_argument(
        "--dump", action="store_true",
        help="собрать блобы локально в ./blob_<suite>.swift и не отправлять в CE",
    )
    parser.add_argument(
        "--delay", type=float, default=1.0, metavar="СЕК",
        help="пауза между запросами к CE (по умолчанию 1.0 с; 0 — без паузы)",
    )
    parser.add_argument(
        "--timeout", type=float, default=300.0, metavar="СЕК",
        help="таймаут одного запроса к CE (по умолчанию 300 с)",
    )
    parser.add_argument(
        "--retries", type=int, default=3, metavar="N",
        help="повторов при 429/5xx/сетевой ошибке (по умолчанию 3)",
    )
    parser.add_argument(
        "--list", action="store_true", help="напечатать список suite'ов и выйти",
    )
    # Позиционные имена оставлены для совместимости с `python ce_linux_tests.py PlaybackTests`.
    parser.add_argument("suites", nargs="*", metavar="СУITE", help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    _utf8_console()
    args = parse_args(argv)

    if args.list:
        for name in SUITE_ORDER:
            cfg = SUITES[name]
            print(f"{name}: {cfg['test_file']} + {len(cfg['sources'])} source(s)")
        print(f"всего suite'ов: {len(SUITE_ORDER)}, тестов на полном прогоне: {EXPECTED_TESTS}")
        return 0

    selectors = list(args.only) + list(args.suites)
    names = resolve_suites(selectors)

    print("Стенд: Compiler Explorer, Swift 6.4.2 (Linux x86-64) — без macOS и без XCTest")
    print(f"CE: POST {CE_URL}")
    print(f"Режим: {'typecheck (компиляция)' if args.typecheck else 'compile+execute (тесты исполняются)'}; "
          f"suite'ов: {len(names)}; пауза между запросами: {args.delay:g} с")
    print("")

    if args.dump:
        for name in names:
            try:
                source, _, klass, methods = build_suite(name)
            except BuildError as exc:
                print(f"[{name}] BUILD ERROR: {exc}")
                return 1
            out = pathlib.Path(f"blob_{name}.swift")
            out.write_text(source, encoding="utf-8")
            print(f"wrote {out} ({len(source)} символов, {len(methods)} тестов, класс {klass})")
        return 0

    report, started_all = [], time.monotonic()
    for index, name in enumerate(names, 1):
        if index > 1 and args.delay > 0:
            time.sleep(args.delay)
        print(f"----- [{index}/{len(names)}] {name} -----")
        try:
            entry = run_suite(name, typecheck=args.typecheck,
                              timeout=args.timeout, retries=args.retries)
        except BuildError as exc:
            print(f"  BUILD ERROR: {exc}")
            entry = {"suite": name, "error": f"build error: {exc}", "tests": 0,
                     "passed": 0, "failed": 0, "compile_errors": []}
        except Exception as exc:  # noqa: BLE001 - не падаем на одном suite, идём дальше
            print(f"  SUITE {name} crashed locally: {exc!r}")
            entry = {"suite": name, "error": repr(exc), "tests": 0,
                     "passed": 0, "failed": 0, "compile_errors": []}
        report.append(entry)
        print("")

    total_elapsed = time.monotonic() - started_all

    # ----- сводка ----- #
    print("===== FINAL =====")
    bad = 0
    if args.typecheck:
        for entry in report:
            if "error" in entry:
                print(f"{entry['suite']}: ERROR {entry['error']}")
                bad += 1
                continue
            errors = entry.get("compile_errors") or []
            status = "OK" if not errors and entry.get("code") == 0 else "FAIL"
            if status == "FAIL":
                bad += 1
            print(f"{entry['suite']}: typecheck {status}, "
                  f"compile_errors={len(errors)}, blob={entry.get('blob', 0)}")
        print(f"TYPECHECK: {bad} проблем(ы) в {len(report)} блоб(ах), {total_elapsed:.1f} с")
        ok = bad == 0
        payload = {
            "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "compiler": CE_COMPILER, "ce_url": CE_URL, "mode": "typecheck",
            "suites": report, "problems": bad, "ok": ok,
        }
        if args.json:
            write_json_report(args.json, payload)
        return 0 if ok else 1

    total_tests = total_passed = total_failed = total_compile_errors = 0
    for entry in report:
        if "error" in entry:
            print(f"{entry['suite']}: ERROR {entry['error']}")
            bad += 1
            continue
        errors = entry.get("compile_errors") or []
        total_compile_errors += len(errors)
        total_tests += entry.get("tests", 0)
        total_passed += entry.get("passed", 0)
        total_failed += entry.get("failed", 0)
        suite_bad = (entry.get("failed", 0) > 0 or bool(errors)
                     or entry.get("incomplete", False))
        if suite_bad:
            bad += 1
        print(f"{entry['suite']}: {entry.get('passed', 0)}/{entry.get('tests', 0)} passed, "
              f"{entry.get('failed', 0)} failed, compile_errors={len(errors)}")
    print(f"TOTAL: {total_passed}/{total_tests} passed, {total_failed} failed, "
          f"compile_errors={total_compile_errors}, {total_elapsed:.1f} с")
    if names == SUITE_ORDER and total_tests != EXPECTED_TESTS:
        print(f"WARNING: в полном прогоне {total_tests} тестов вместо ожидаемых "
              f"{EXPECTED_TESTS} — проверьте состав suite'ов/тестовых файлов")

    ok = bad == 0 and total_passed == total_tests and total_compile_errors == 0
    if ok:
        print("CE-RESULT: ALL PASSED")
    else:
        print(f"CE-RESULT: FAILURES ({bad} problem suite(s))")

    payload = {
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "compiler": CE_COMPILER,
        "ce_url": CE_URL,
        "mode": "compile+execute",
        "delay_s": args.delay,
        "suites": report,
        "totals": {
            "tests": total_tests,
            "passed": total_passed,
            "failed": total_failed,
            "compile_errors": total_compile_errors,
            "suites": len(report),
            "elapsed_s": round(total_elapsed, 2),
        },
        "ok": ok,
    }
    if args.json:
        write_json_report(args.json, payload)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
