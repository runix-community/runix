#!/usr/bin/env python3
"""Writes the installer's translatable text as a catalog template.

Usage: extract-strings.py SRC_DIR [EXISTING.json] > catalog.json

Collects the English text of every tr("..."), N_("...") and
i18n::format("...") in SRC_DIR. With an existing catalog, keeps its
translations and drops strings the installer no longer has.
"""
import json
import pathlib
import re
import sys

CALL = re.compile(r'\b(?:tr|N_|format)\(\s*((?:"(?:[^"\\]|\\.)*"\s*)+)')
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')


def unescape(text):
    escapes = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}
    return re.sub(r"\\(.)", lambda match: escapes.get(match.group(1), match.group(0)), text)


def strings(source):
    found = []
    for path in sorted(pathlib.Path(source).glob("*.[ch]pp")):
        text = path.read_text(encoding="utf-8")
        for call in CALL.finditer(text):
            english = "".join(unescape(part) for part in LITERAL.findall(call.group(1)))
            if english.strip() and english not in found:
                found.append(english)
    return found


def main():
    source = sys.argv[1]
    existing = {"language": "", "strings": {}}
    if len(sys.argv) > 2:
        existing = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
    old = existing.get("strings", {})
    catalog = {
        "language": existing.get("language", ""),
        "strings": {english: old.get(english, "") for english in strings(source)},
    }
    json.dump(catalog, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


main()
