#!/usr/bin/env python3
"""Typecheck Anixart iOS sources on Linux via Compiler Explorer, using a fake SwiftUI module.

Локальный swiftc на этой машине падает (0xC0000142), поэтому используем godbolt.

    python check.py all           # все экраны разом
    python check.py home search   # только указанные экраны
    python check.py stub          # только заглушка (sanity check самой заглушки)

Отчёт печатает ошибки с номерами строк ИСХОДНЫХ файлов, а не собранного блоба.
"""

import json
import pathlib
import re
import sys
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
IOS = HERE.parent.parent                     # .../anixart/ios
APP = "Anixart/"

# Порядок важен: сначала то, от чего зависят остальные.
CORE = sorted(
    [p for p in pathlib.Path(HERE.parent.parent, "Anixart").rglob("*.swift")],
    key=lambda p: (0 if "Models" in p.name else 1 if "Core" in str(p) else 2, str(p)),
)
SKIP_STUBS = {
    # AVFoundation/AVKit/PiP заглушками не моделируются — эти файлы проверяет только xcodebuild.
    "Features/Player/NativePlayerView.swift",
    "Features/Player/PlayerView.swift",
    "Features/Downloads/DownloadManager.swift",
}
CORE = [str(p.relative_to(HERE.parent.parent)) for p in CORE
        if not any(p.name == s.split("/")[-1] for s in SKIP_STUBS)]

SCREENS = {
    "all": [],   # CORE теперь собирается по glob: все файлы приложения
}

# Контрольные поломки: проверяем, что стенд реально ловит ошибки НАШЕГО кода.
# Подмены не меняют число строк, поэтому маппинг строк остаётся верным.
MUTATIONS = [
    ("Components/Components.swift", "RemoteImage(urlString: release.image)", "RemoteImage(urlStrng: release.image)",
     "опечатка в лейбле аргумента"),
    ("Release/ReleaseView.swift", ".fullScreenCover(item: $model.playback)", ".fullScreenCover(item: $model.playbackX)",
     "опечатка в имени свойства"),
    ("Components/Components.swift", "Text(release.gradeText)", "Text(release.gradeTxt)",
     "опечатка в члене модели"),
]

# Модули, которых на Linux нет: вырезаем импорты, типы даёт заглушка.
DROP_IMPORT = re.compile(r"^\s*import\s+(SwiftUI|Combine|WebKit|AVKit|AVFoundation|Security|UIKit)\s*$")

CE_URL = "https://godbolt.org/api/compiler/swift642/compile"
HEADERS = {
    "Accept": "application/json",
    "Content-Type": "application/json",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
}

DIAG = re.compile(r"^(?:<source>|source|example|output\.[a-z]+)?:?(\d+):(\d+):\s*(error|warning|note):\s*(.*)$")


def read_app_file(rel: str) -> str:
    """Вырезает импорты недоступных на Linux модулей, СОХРАНЯЯ нумерацию строк."""
    lines = (IOS / rel).read_text(encoding="utf-8").splitlines()
    return "\n".join("" if DROP_IMPORT.match(l) else l for l in lines)


def build(files):
    """Собирает блоб и карту «строка блоба -> (файл, строка файла)»."""
    parts = [(None, (HERE / "StubKit.swift").read_text(encoding="utf-8"))]
    for rel in files:
        parts.append((rel, read_app_file(rel)))

    out, spans = [], []
    line = 1
    for rel, text in parts:
        n = text.count("\n") + 1
        spans.append((line, line + n - 1, rel))
        out.append(text)
        line += n + 1                     # +1 на пустую строку-разделитель
    return "\n\n".join(out), spans


def locate(spans, blob_line):
    for start, end, rel in spans:
        if start <= blob_line <= end:
            return rel, blob_line - start + 1
    return None, blob_line


def compile_ce(source):
    payload = json.dumps({
        "source": source,
        "options": {"userArguments": "-typecheck -parse-as-library", "filters": {"execute": False}},
        "lang": "swift",
    }).encode("utf-8")
    req = urllib.request.Request(CE_URL, data=payload, headers=HEADERS, method="POST")
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read().decode("utf-8"))


def run(name, files):
    source, spans = build(files)
    return run_source(name, source, spans)


def run_source(name, source, spans):
    outdir = HERE / "build"
    outdir.mkdir(exist_ok=True)
    (outdir / f"{name}.swift").write_text(source, encoding="utf-8")

    print(f"\n===== {name}: {len(source)} байт =====")
    try:
        result = compile_ce(source)
    except Exception as exc:                       # noqa: BLE001
        print(f"  CE request failed: {exc}")
        return None

    if result.get("code") == 0:
        print("  OK — ошибок нет")
        return 0

    groups = {}
    for item in result.get("stderr", []):
        text = item.get("text", "").rstrip()
        if not text:
            continue
        m = DIAG.match(text)
        if m:
            blob_line = int(m.group(1))
            rel, src_line = locate(spans, blob_line)
            where = f"{rel}:{src_line}" if rel else f"<stub>:{src_line}"
            groups.setdefault((m.group(3), where), []).append(m.group(4))
        else:
            groups.setdefault(("raw", text), []).append("")

    errors = {k: v for k, v in groups.items() if k[0] == "error"}
    warnings = {k: v for k, v in groups.items() if k[0] == "warning"}
    others = {k: v for k, v in groups.items() if k[0] not in ("error", "warning")}

    for (kind, where), msgs in errors.items():
        for msg in msgs:
            print(f"  ERROR {where}: {msg}")
    for (kind, where), msgs in warnings.items():
        for msg in msgs[:3]:
            print(f"  warn  {where}: {msg}")
    for (kind, where), msgs in others.items():
        print(f"  other {kind}: {where} {msgs}")
    print(f"  -> ошибок: {len(errors)}, предупреждений: {len(warnings)}")
    return len(errors)


def mutate():
    """Контроль качества стенда: намеренно ломаем НАШ код — стенд обязан это поймать."""
    source, spans = build(CORE)
    for rel, old, new, what in MUTATIONS:
        if old not in source:
            print(f"\n  SKIP {rel}: фрагмент не найден: {old}")
            continue
        print(f"\n--- мутация {rel} ({what}): {old!r} -> {new!r}")
        run_source("mutant", source.replace(old, new, 1), spans)


def main(argv):
    if not argv or argv[0] == "all":
        names = list(SCREENS)
    elif argv[0] == "mutate":
        mutate()
        return
    elif argv[0] == "stub":
        run("stub_only", [])
        return
    else:
        print(f"неизвестный аргумент: {argv[0]}")
        print("использование: check.py [all|mutate|stub]")
        sys.exit(2)

    for name in names:
        failed = run(name, CORE + SCREENS[name])
        if failed:
            sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
