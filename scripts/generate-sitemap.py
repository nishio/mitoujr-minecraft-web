#!/usr/bin/env python3
"""Generate sitemap.xml for the static public site."""

from pathlib import Path
from urllib.parse import quote
import os
import sys
import xml.etree.ElementTree as ET


BASE_URL = os.environ.get(
    "BASE_URL",
    "https://nishio.github.io/mitoujr-minecraft-web",
).rstrip("/")


def page_url(path: Path) -> str:
    rel = path.as_posix()
    if rel == "index.html":
        return f"{BASE_URL}/"
    return f"{BASE_URL}/{quote(rel)}"


def html_pages(root: Path) -> list[Path]:
    pages = []
    for path in root.rglob("*.html"):
        if ".git" in path.parts:
            continue
        pages.append(path.relative_to(root))
    return sorted(pages, key=lambda p: (p.as_posix() != "index.html", p.as_posix()))


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    ET.register_namespace("", "http://www.sitemaps.org/schemas/sitemap/0.9")
    urlset = ET.Element("{http://www.sitemaps.org/schemas/sitemap/0.9}urlset")
    for path in html_pages(root):
        url = ET.SubElement(urlset, "{http://www.sitemaps.org/schemas/sitemap/0.9}url")
        ET.SubElement(url, "{http://www.sitemaps.org/schemas/sitemap/0.9}loc").text = page_url(path)

    tree = ET.ElementTree(urlset)
    ET.indent(tree, space="  ")
    sys.stdout.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    tree.write(sys.stdout, encoding="unicode", xml_declaration=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
