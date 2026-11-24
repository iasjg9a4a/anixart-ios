#!/usr/bin/env python3
"""Публикует текущее состояние репозитория в отдельный «CI-репозиторий» одним коммитом.

Зачем: GitHub Actions на публичном репозитории бесплатны (включая macOS-раннеры),
а основной репозиторий может оставаться приватным. Скрипт переносит **только текущий
срез кода** (без истории коммитов), чтобы в публичный репозиторий не попали старые
упоминания аккаунтов и прочий мусор из истории.

Использование (из корня репозитория):

    python tools/mirror_to_ci.py --remote https://github.com/<user>/anixart-ios-ci.git
    python tools/mirror_to_ci.py --remote git@github.com:<user>/anixart-ios-ci.git --branch main

Требует настроенного git-доступа к целевому репозиторию (PAT/SSH).
"""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def run(args: list[str], cwd: pathlib.Path, secret: str = "") -> str:
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode != 0:
        # Токен (если передали через MIRROR_TOKEN) не должен попасть в логи.
        def mask(text: str) -> str:
            return text.replace(secret, "***") if secret else text

        sys.stderr.write(f"$ {' '.join(mask(a) for a in args)}\n{mask(result.stdout)}\n{mask(result.stderr)}\n")
        raise SystemExit(result.returncode)
    return result.stdout


def tracked_files() -> list[str]:
    out = run(["git", "ls-files"], ROOT)
    return [line.strip() for line in out.splitlines() if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--remote", required=True, help="git-URL CI-репозитория")
    parser.add_argument("--branch", default="main", help="ветка для публикации (по умолчанию main)")
    parser.add_argument("--message", default="Mirror for CI", help="сообщение коммита")
    parser.add_argument("--keep", action="store_true", help="оставить временный каталог для отладки")
    args = parser.parse_args()

    token = os.environ.get("MIRROR_TOKEN", "")
    remote = args.remote
    if token:
        # https://host/owner/repo.git -> https://x-access-token:***@host/owner/repo.git
        prefix, _, rest = remote.partition("://")
        if prefix != "https":
            sys.stderr.write("MIRROR_TOKEN поддерживается только для https-remote\n")
            return 2
        remote = f"https://x-access-token:{token}@{rest}"

    files = tracked_files()
    if not files:
        sys.stderr.write("git ls-files пуст — запущен не в том каталоге?\n")
        return 2

    tmp = pathlib.Path(tempfile.mkdtemp(prefix="anixart-ci-"))
    try:
        for rel in files:
            src = ROOT / rel
            if not src.is_file():
                continue
            dst = tmp / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

        run(["git", "init", "-q", "-b", args.branch], tmp)
        run(["git", "config", "user.name", "anixart-ci"], tmp)
        run(["git", "config", "user.email", "ci@localhost"], tmp)
        run(["git", "add", "-A"], tmp)
        run(["git", "commit", "-q", "-m", args.message], tmp)
        # -c credential.helper= отключает системный менеджер, чтобы токен из URL
        # не осел в хранилище учётных данных Windows.
        run(["git", "remote", "add", "origin", remote], tmp, secret=token)
        run(["git", "-c", "credential.helper=", "push", "-q", "--force", "origin", args.branch], tmp, secret=token)

        print(f"Опубликовано {len(files)} файлов в {args.remote} (ветка {args.branch})")
        return 0
    finally:
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"Временный каталог: {tmp}")


if __name__ == "__main__":
    raise SystemExit(main())
