#!/usr/bin/env python3
"""Проверка контракта API Anixart, который использует iOS-клиент.

Скрипт делает те же запросы, что и приложение, и проверяет, что в ответе есть
все поля, которые ожидают Codable-модели из Anixart/Models/Models.swift.

Запуск:  python api_probe.py
Только Python 3.8+, внешних зависимостей нет.
"""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request

BASE = "https://api-s.anixsekai.com/"
HEADERS = {
    "User-Agent": "Anixart-iOS/1.0 (contract check)",
    "Accept": "application/json",
}

OK = "\033[92mOK\033[0m"
FAIL = "\033[91mFAIL\033[0m"

results: list[tuple[bool, str, str]] = []


def call(path: str, method: str = "GET", body: dict | None = None) -> tuple[int, object]:
    data = json.dumps(body).encode() if body is not None else None
    headers = dict(HEADERS)
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            raw = response.read().decode("utf-8", "replace")
            return response.status, raw
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")
    except Exception as error:  # noqa: BLE001 - сеть бывает любой
        return 0, str(error)


def check(name: str, path: str, required: dict, method: str = "GET", body: dict | None = None) -> None:
    """required: {путь_до_поля: ожидаемый python-тип} — путь через точку, [] — элемент списка."""
    status, raw = call(path, method, body)
    if not isinstance(raw, str) or status != 200:
        results.append((False, name, f"HTTP {status}: {str(raw)[:120]}"))
        return

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as error:
        results.append((False, name, f"не JSON: {error}"))
        return

    missing = []
    for dotted, expected in required.items():
        current = payload
        for part in dotted.split("."):
            if part == "[]":
                if not isinstance(current, list) or not current:
                    current = None
                    break
                current = current[0]
                continue
            if not isinstance(current, dict) or part not in current:
                current = None
                break
            current = current[part]
        if current is None:
            missing.append(f"{dotted} отсутствует")
        elif expected is not None and not isinstance(current, expected):
            missing.append(f"{dotted}: ожидался {expected.__name__}, пришёл {type(current).__name__}")

    if missing:
        results.append((False, name, "; ".join(missing)))
    else:
        results.append((True, name, f"{len(raw)} байт"))


def main() -> int:
    check("release/{id}", "release/1", {
        "code": int,
        "release.id": int,
        "release.title_ru": None,
        "release.image": None,
        "release.grade": None,
        "release.episodes_total": None,
        "release.genres": None,
    })

    check("profile/{id}", "profile/1", {
        "code": int,
        "profile.id": int,
        "profile.login": None,
        "profile.avatar": None,
    })

    check("filter/{page}", "filter/1", {
        "code": int,
        "content.[].id": int,
        "total_count": int,
        "total_page_count": int,
        "current_page": int,
    })

    check("discover/hub", "discover/hub", {
        "code": int,
        "watching.[].id": int,
        "discussing": list,
        "collections": list,
    })

    check("search (POST)", "search/releases/1", {
        "code": int,
        "content.[].id": int,
        "total_count": int,
    }, method="POST", body={"query": "one piece", "page": 1})

    check("episode/{releaseId}", "episode/1", {
        "code": int,
        "types.[].id": int,
        "types.[].name": str,
    })

    check("episode/{releaseId}/{typeId}", "episode/1/1", {
        "code": int,
        "sources.[].id": int,
    })

    check("episode/{releaseId}/{typeId}/{sourceId}", "episode/1/1/8", {
        "code": int,
        "episodes.[].position": int,
        "episodes.[].name": None,
    })

    # Ключевая проверка: ссылка на видео выдаётся без авторизации.
    check("episode/target/{releaseId}/{sourceId}/{position}", "episode/target/1/8/1", {
        "code": int,
        "episode.position": int,
        "episode.url": str,
        "episode.iframe": bool,
    })

    # Экраны «Коллекции» и «Комментарии».
    check("collection/hub", "collection/hub", {
        "code": int,
        "weekly.[].id": int,
        "recommended": list,
    })

    check("collection/all/{page}", "collection/all/1", {
        "code": int,
        "content.[].id": int,
        "total_page_count": int,
    })

    check("release/comment/all/{id}/{page}", "release/comment/all/1/1", {
        "code": int,
        "content.[].id": int,
        "content.[].message": None,
        "content.[].profile.id": int,
    })

    # Заведомо защищённые запросы: должны вернуть 401, а не что-то ещё.
    status, raw = call("profile/info")
    guarded = status == 200 and '"code":401' in str(raw)
    results.append((guarded, "profile/info без токена → 401", str(raw)[:80]))
    if guarded:
        results[-1] = (True, "profile/info без токена → 401", "как и ожидалось")

    width = max(len(name) for _, name, _ in results) + 2
    failed = 0
    for ok, name, detail in results:
        if not ok:
            failed += 1
        print(f"{OK if ok else FAIL}  {name.ljust(width)} {detail}")

    print()
    if failed:
        print(f"Проблем: {failed}. Контракт изменился — правьте Models.swift/APIClient.swift.")
        return 1
    print("Все проверки прошли: модели iOS-клиента соответствуют живому API.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
