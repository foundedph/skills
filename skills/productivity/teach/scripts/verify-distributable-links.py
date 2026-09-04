#!/usr/bin/env python3
"""
verify-distributable-links.py

Walks a distributable course folder and checks every relative `href` inside
every HTML file resolves on disk. Run before zipping.

Usage:
    python3 scripts/verify-distributable-links.py <distributable-folder>

Exit code is non-zero if any link is broken. Prints a summary at the end.

This catches the two bugs that always slip past the build script:
  - the misnamed-sibling-CSS pitfall (course.css copied as 0001-...css)
  - a glossary or landing page pointing at a path that no longer exists
    after a folder restructure.

Keep this script alongside the teach skill so it ships with every workspace
that distributes courses.
"""
import os
import re
import sys

HREF_RE = re.compile(r'href="([^"]+)"')
SKIP_PREFIXES = ("http://", "https://", "#", "mailto:", "tel:", "data:")


def check(root: str) -> list[str]:
    errors: list[str] = []
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            if not fn.endswith(".html"):
                continue
            p = os.path.join(dirpath, fn)
            with open(p, encoding="utf-8") as fh:
                for i, line in enumerate(fh, 1):
                    for href in HREF_RE.findall(line):
                        if href.startswith(SKIP_PREFIXES):
                            continue
                        target_rel = href.split("#", 1)[0]
                        if not target_rel:
                            continue
                        target = os.path.normpath(
                            os.path.join(os.path.dirname(p), target_rel)
                        )
                        if not os.path.exists(target):
                            errors.append(f"{p}:{i}  {href}  ->  {target}")
    return errors


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = argv[1]
    if not os.path.isdir(root):
        print(f"not a directory: {root}", file=sys.stderr)
        return 2
    errors = check(root)
    html_files = sum(
        1 for _, _, fs in os.walk(root) for f in fs if f.endswith(".html")
    )
    if errors:
        print(f"BROKEN ({len(errors)}):")
        for e in errors:
            print(f"  {e}")
        print(f"\nChecked {html_files} HTML file(s) under {root}.")
        return 1
    print(f"All relative hrefs resolve. ({html_files} HTML file(s) checked.)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))