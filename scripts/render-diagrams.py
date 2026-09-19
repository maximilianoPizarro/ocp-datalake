#!/usr/bin/env python3
"""Render fixed-size HTML architecture diagrams to PNG via Playwright."""

from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
OUT = DOCS / "assets" / "diagrams"

DIAGRAMS = [
    ("_diagram-bridge-enterprise.html", "bridge-enterprise.png"),
    ("_diagram-replace-enterprise.html", "replace-enterprise.png"),
    ("_diagram-architecture.html", "architecture.png"),
    ("_diagram-flows.html", "journey.png"),
    ("_diagram-authpolicy.html", "authpolicy-connectivity-link.png"),
]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1600, "height": 900})
        for html_name, png_name in DIAGRAMS:
            html_path = DOCS / html_name
            out_path = OUT / png_name
            page.goto(html_path.as_uri())
            page.wait_for_timeout(400)
            page.screenshot(path=str(out_path), full_page=False)
            print(f"wrote {out_path.relative_to(ROOT)}")
        browser.close()


if __name__ == "__main__":
    main()
