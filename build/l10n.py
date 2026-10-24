#!/usr/bin/env python3
"""Языки приложения: build/l10n.py <папка Resources>.
Русский — исходный язык, его строки прямо в коде. Английский — словарь app/l10n/en.py,
из него получается en.lproj/Localizable.strings. ru.lproj пустой: так macOS знает, что русский есть.
С --check <папка .stringsdata> — проверка, что у каждой русской строки из кода есть перевод."""

import json
import pathlib
import re
import runpy
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EN = runpy.run_path(str(ROOT / "app" / "l10n" / "en.py"))["EN"]


def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def write(resources):
    for lang, table in (("en", EN), ("ru", {})):
        d = pathlib.Path(resources) / f"{lang}.lproj"
        d.mkdir(parents=True, exist_ok=True)
        lines = [f"{quote(k)} = {quote(v)};" for k, v in sorted(table.items())]
        (d / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-16")


def check(folder):
    missing = set()
    for f in pathlib.Path(folder).glob("*.stringsdata"):
        for table in json.loads(f.read_text())["tables"].values():
            for e in table:
                if re.search("[А-Яа-яЁё]", e["key"]) and e["key"] not in EN:
                    missing.add(e["key"])
    for k in sorted(missing):
        print("нет перевода:", k)
    return not missing


if __name__ == "__main__":
    if sys.argv[1] == "--check":
        sys.exit(0 if check(sys.argv[2]) else 1)
    write(sys.argv[1])
