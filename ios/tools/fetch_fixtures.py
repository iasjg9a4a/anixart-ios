#!/usr/bin/env python3
"""Скачивает реальные ответы API в tools/fixtures — на них проверяются Codable-модели.

Запуск:  python tools/fetch_fixtures.py
"""

from __future__ import annotations

import json
import pathlib
import urllib.request

BASE = "https://api-s.anixsekai.com/"
HEADERS = {"User-Agent": "Anixart-iOS/1.0 (fixtures)", "Accept": "application/json"}
OUT = pathlib.Path(__file__).parent / "fixtures"

# имя файла -> (метод, путь, тело)
ENDPOINTS = {
    "release.json": ("GET", "release/1", None),
    "profile.json": ("GET", "profile/1", None),
    "filter.json": ("GET", "filter/1", None),
    "discover.json": ("GET", "discover/hub", None),
    "search.json": ("POST", "search/releases/1", {"query": "one piece", "page": 1}),
    "episode_types.json": ("GET", "episode/1", None),
    "episode_sources.json": ("GET", "episode/1/1", None),
    "episodes.json": ("GET", "episode/1/1/8", None),
    "episode_target.json": ("GET", "episode/target/1/8/1", None),
}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (method, path, body) in ENDPOINTS.items():
        data = json.dumps(body).encode() if body is not None else None
        headers = dict(HEADERS)
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
        with urllib.request.urlopen(request, timeout=25) as response:
            raw = response.read()
        (OUT / name).write_bytes(raw)
        print(f"{name:22} {len(raw):>7} байт  <- {method} {path}")


if __name__ == "__main__":
    main()
