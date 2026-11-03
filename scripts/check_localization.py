#!/usr/bin/env python3
"""Checks Burrow's localization.

English is the source language: user-visible strings in Sources/ are English
and Resources/<lang>.lproj/Localizable.strings translates them. This script
fails when
  - a Swift string literal in Sources/ still contains Polish letters
    (mark a deliberate one with a trailing `// l10n-ignore` comment),
  - a translation file does not parse,
  - a translation's format placeholders differ from its key's,
and, with --strict, when a literal passed to a localizing API has no
translation.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "Burrow"
TABLES = sorted((ROOT / "Resources").glob("*.lproj/Localizable.strings"))
POLISH = re.compile(r"[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]")
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:ll|l|h|hh|q|z|t|j)?[@dDuUxXoOfFeEgGcCsSpaA]")
# Initializers and modifiers whose string-literal argument SwiftUI or
# Foundation look up in Localizable.strings.
LOCALIZING = re.compile(
    r'(?:String\(localized:|Text\(|Button\(|Label\(|Toggle\(|Picker\(|Menu\(|Section\(|'
    r'TextField\(|SecureField\(|GroupBox\(|LabeledContent\(|ProgressView\(|Link\(|'
    r'ContentUnavailableView\(|DisclosureGroup\(|Stepper\(|\.help\(|\.accessibilityLabel\(|'
    r'\.accessibilityHint\(|\.navigationTitle\(|\.alert\(|\.confirmationDialog\(|'
    r'CommandMenu\(|\.badge\()\s*"((?:[^"\\\n]|\\.)*)"'
)


def strip_comment(line: str) -> str:
    """Drops a // comment that is not inside a string literal."""
    in_string = False
    i = 0
    while i < len(line):
        c = line[i]
        if c == "\\" and in_string:
            i += 2
            continue
        if c == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i]
        i += 1
    return line


def placeholders(text: str) -> list[str]:
    found = []
    for match in PLACEHOLDER.finditer(text.replace("%%", "")):
        token = re.sub(r"^%\d+\$", "%", match.group(0))
        found.append(token)
    return sorted(found)


def swift_key(literal: str) -> str:
    """Turns a Swift literal into a pattern of its localization key."""
    out, i, depth = [], 0, 0
    while i < len(literal):
        if literal.startswith("\\(", i) and depth == 0:
            depth, i = 1, i + 2
            while i < len(literal) and depth:
                depth += {"(": 1, ")": -1}.get(literal[i], 0)
                i += 1
            out.append("\x00")
            continue
        if literal[i] == "\\" and i + 1 < len(literal):
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(literal[i + 1], literal[i + 1]))
            i += 2
            continue
        out.append(literal[i])
        i += 1
    return "".join(out)


def normalized(key: str) -> str:
    return PLACEHOLDER.sub("\x00", key.replace("%%", "%"))


def main() -> int:
    strict = "--strict" in sys.argv
    errors, missing = [], []

    tables = {}
    for table in TABLES:
        result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(table)],
                                capture_output=True, text=True)
        if result.returncode != 0:
            errors.append(f"{table.relative_to(ROOT)}: does not parse: {result.stderr.strip()}")
            continue
        entries = json.loads(result.stdout)
        tables[table.parent.name] = entries
        for key, value in entries.items():
            if placeholders(key) != placeholders(value):
                errors.append(f"{table.relative_to(ROOT)}: placeholders differ for {key!r} -> {value!r}")

    # English is the source language, so only translations need every key.
    keys_by_table = {name: {normalized(k) for k in entries} for name, entries in tables.items() if name != "en.lproj"}

    for path in sorted(SOURCES.rglob("*.swift")):
        for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if "l10n-ignore" in raw:
                continue
            line = strip_comment(raw)
            if line.lstrip().startswith(("///", "//", "*")):
                continue
            for literal in LITERAL.findall(line):
                if POLISH.search(literal):
                    errors.append(f"{path.relative_to(ROOT)}:{number}: Polish text in source: \"{literal}\"")
            for literal in LOCALIZING.findall(line):
                key = swift_key(literal)
                if not re.search(r"[A-Za-z]{2}", key):
                    continue
                for name, keys in keys_by_table.items():
                    if key not in keys:
                        missing.append(f"{path.relative_to(ROOT)}:{number}: no {name} translation for \"{literal}\"")

    for line in errors:
        print("error:", line)
    for line in missing:
        print(("error: " if strict else "warning: ") + line)
    count = sum(len(t) for t in tables.values())
    print(f"{count} translations in {len(tables)} tables, {len(errors)} errors, {len(missing)} untranslated literals")
    return 1 if errors or (strict and missing) else 0


if __name__ == "__main__":
    sys.exit(main())
