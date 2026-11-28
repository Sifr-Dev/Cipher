#!/usr/bin/env python3
"""Generate the "Apps built on Cipher" index from apps/manifest.json.

The table is written between BEGIN/END markers in README.md so it cannot drift
from the manifest. Run after adding an app to the manifest:

    python3 tools/gen_app_index.py
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "apps" / "manifest.json"
README = ROOT / "README.md"
BEGIN = "<!-- BEGIN GENERATED APP INDEX -->"
END = "<!-- END GENERATED APP INDEX -->"


def render(data):
    lines = [
        BEGIN,
        "| App | Purpose | Status | Repository | Cipher |",
        "| --- | --- | --- | --- | --- |",
    ]
    for app in data["apps"]:
        lines.append(
            f"| [{app['name']}]({app['repo']}) | {app['purpose']} | "
            f"{app['status']} | {app['repo']} | {app['cipher_version']} |"
        )
    lines.append(END)
    return "\n".join(lines)


def main():
    data = json.loads(MANIFEST.read_text())
    block = render(data)
    text = README.read_text()
    if BEGIN not in text or END not in text:
        print("README.md is missing the generated index markers", file=sys.stderr)
        return 1
    start = text.index(BEGIN)
    end = text.index(END) + len(END)
    new = text[:start] + block + text[end:]
    if new != text:
        README.write_text(new)
        print("updated README app index")
    else:
        print("app index already current")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())