#!/usr/bin/env python3
"""Capture the live Interactive preview in the same states as --sample-screenshots."""
import argparse
from pathlib import Path

from playwright.sync_api import expect, sync_playwright


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--chromium", help="Path to an installed Chromium or Chrome executable")
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=args.chromium)
        page = browser.new_page(viewport={"width": 1440, "height": 1100}, device_scale_factor=1)
        shell = page.locator("#workspace-shell")
        for theme in ("dark", "light"):
            page.goto("https://swarmhub.org/", wait_until="domcontentloaded")
            page.locator(f'[data-workspace-theme="{theme}"]').click()
            expect(shell).to_have_attribute("data-theme", theme)
            for story in ("release", "inbox", "checks", "brief", "team"):
                button = page.locator(f'[data-task="{story}"]')
                button.click()
                expect(button).to_have_attribute("aria-pressed", "true")
                shell.screenshot(path=args.directory / f"{theme}-{story}.png")
            for helper in ("tests", "rename"):
                button = page.locator(f'[data-select-helper="{helper}"]')
                button.click()
                expect(button).to_have_attribute("aria-selected", "true")
                expect(shell.locator("#chat-active-name")).to_contain_text(helper)
                expect(shell.locator(".terminal-pre")).to_be_visible()
                shell.screenshot(path=args.directory / f"{theme}-{helper}.png")
            shell.get_by_role("button", name="Steer via Jarvis").click()
            expect(shell.locator("#chat-active-name")).to_contain_text("Jarvis")
            expect(shell.locator("#mac-feed")).to_contain_text("Opened Jarvis to steer helper “rename”")
            expect(shell.locator("#mac-composer-input")).to_be_focused()
            shell.screenshot(path=args.directory / f"{theme}-steer-rename.png")
            shell.locator("#select-inbox").click()
            expect(shell.locator("#inbox-badge")).to_have_text("2")
            shell.get_by_role("button", name="Always allow in /srv/shop").click()
            shell.get_by_role("button", name="Create bot").click()
            expect(shell.locator("#inbox-badge")).to_have_text("0")
            expect(shell.locator(".action-resolved")).to_have_text([
                "✓ Saved scoped rule · Allowed in /srv/shop", "✓ Payments created · Ask everything enabled"
            ])
            shell.screenshot(path=args.directory / f"{theme}-inbox-resolved.png")
        browser.close()


if __name__ == "__main__":
    main()
