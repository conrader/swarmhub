#!/usr/bin/env python3
"""Capture the live Interactive preview in the same states as --sample-screenshots."""
import argparse
import json
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

from preview_sidebar import check_jarvis_branch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--chromium", help="Path to an installed Chromium or Chrome executable")
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    helpers = json.loads((Path(__file__).resolve().parents[1] / "Fixtures/preview-helpers.json").read_text())
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=args.chromium)
        page = browser.new_page(viewport={"width": 1440, "height": 1100}, device_scale_factor=1)
        shell = page.locator("#workspace-shell")
        def sidebar_selection(selected):
            rows = {}
            for name in ("jarvis", "tests", "rename", "patch"):
                kind = "helper" if name in helpers else "bot"
                row = shell.locator(f'[data-select-{kind}="{name}"]')
                expect(row).to_be_in_viewport()
                box = row.bounding_box()
                rows[name] = (tuple(box[k] for k in ("x", "y", "width", "height")),
                              row.get_attribute("aria-selected") == "true")
            check_jarvis_branch(rows, selected)

        for theme in ("dark", "light"):
            page.goto("https://swarmhub.org/", wait_until="domcontentloaded")
            page.locator(f'[data-workspace-theme="{theme}"]').click()
            expect(shell).to_have_attribute("data-theme", theme)
            for story in ("release", "inbox", "checks", "brief", "team"):
                button = page.locator(f'[data-task="{story}"]')
                button.click()
                expect(button).to_have_attribute("aria-pressed", "true")
                shell.screenshot(path=args.directory / f"{theme}-{story}.png")
                if story != "inbox":
                    progress = shell.locator("#demo-progress")
                    expect(progress).to_have_text("Step 1 of 3")
                    for step in (2, 3):
                        shell.locator("#demo-next").click()
                        expect(progress).to_have_text(f"Step {step} of 3")
                        if story == "brief" and step == 3:
                            card = shell.locator(".artifact-card").filter(has_text="Morning brief")
                            for text in ("v0.8.16", "rename", "tests", "2 items"):
                                expect(card).to_contain_text(text)
                        shell.screenshot(path=args.directory / f"{theme}-{story}-step{step}.png")
            for helper, expected in helpers.items():
                button = page.locator(f'[data-select-helper="{helper}"]')
                button.click()
                expect(button).to_have_attribute("aria-selected", "true")
                expect(shell.locator("#chat-active-name")).to_contain_text(helper)
                feed = shell.locator("#mac-feed")
                cards = feed.locator(".panel-card")
                for index, (heading, contents) in enumerate((
                    ("Task", expected["task"]), (f'Steps ({expected["steps"]})', expected["model"]),
                    ("Latest reply", expected["reply"])
                )):
                    expect(cards.nth(index).locator(".panel-card-head strong")).to_have_text(heading)
                    expect(cards.nth(index)).to_contain_text(contents)
                expect(cards.nth(2).locator(".terminal-pre")).to_contain_text(expected["terminal"])
                expect(feed.get_by_role("button", name="Stop helper")).to_have_count(int(expected["canStop"]))
                sidebar_selection(helper)
                shell.screenshot(path=args.directory / f"{theme}-{helper}.png")
            shell.get_by_role("button", name="Steer via Jarvis").click()
            expect(shell.locator("#chat-active-name")).to_contain_text("Jarvis")
            expect(shell.locator("#mac-feed")).to_contain_text("Opened Jarvis to steer helper “rename”")
            expect(shell.locator("#mac-composer-input")).to_be_focused()
            sidebar_selection("jarvis")
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
