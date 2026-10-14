#!/usr/bin/env python3
"""Export the website mark to the Mac iconset and README banners."""

import shutil
import subprocess
import re
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Resources/AppIcon"
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
         (256, 1), (256, 2), (512, 1), (512, 2)]


def main():
    renderer = shutil.which("rsvg-convert")
    if not renderer:
        raise SystemExit("Install librsvg (rsvg-convert) to render the SVG icon.")

    # The circle, eye spacing, colours and tilt match .brand-mark on swarmhub.org.
    # The Mac icon adds a cream tile and transparent outer padding.
    logo = (ASSETS / "SwarmHub-logo.svg").read_text()
    ET.fromstring(logo)
    inner = logo[logo.index(">") + 1:logo.rindex("</svg>")].strip()
    icon = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <title>SwarmHub app icon</title>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="#f7f7f2"/>
  <svg x="184" y="184" width="656" height="656" viewBox="0 0 30 30">
    {inner}
  </svg>
</svg>
'''
    ET.fromstring(icon)
    for name in ["SwarmHub-icon.svg", "SwarmHub-icon-small.svg"]:
        (ASSETS / name).write_text(icon)

    iconset = ASSETS / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    for points, scale in SIZES:
        pixels = points * scale
        suffix = "@2x" if scale == 2 else ""
        destination = iconset / f"icon_{points}x{points}{suffix}.png"
        subprocess.run([renderer, "--width", str(pixels), "--height", str(pixels),
                        "--output", str(destination), str(ASSETS / "SwarmHub-icon.svg")], check=True)
    shutil.copyfile(iconset / "icon_512x512@2x.png", ASSETS / "preview-1024.png")

    for relative in ["docs/readme/hero.svg", "docs/readme/hero-mobile.svg",
                     "Apps/iOS/assets/readme-hero.svg", "Apps/iOS/assets/readme-hero-mobile.svg"]:
        path = ROOT / relative
        banner = path.read_text()
        tree = ET.fromstring(banner)
        namespace = "{http://www.w3.org/2000/svg}"
        embedded = next((node for node in tree.iter(f"{namespace}svg")
                         if node.attrib.get("viewBox") == "0 0 1024 1024"
                         and all(key in node.attrib for key in ["x", "y", "width", "height"])), None)
        if embedded is None:
            raise SystemExit(f"No embedded icon in {path}")
        # Preserve the existing banner layout and copy; replace only its icon.
        start = re.search(r'<svg\b[^>]*viewBox="0 0 1024 1024"[^>]*>', banner).start()
        # The new icon contains a nested SVG, so account for it on later runs.
        old = banner[start:]
        depth = 0
        for match in re.finditer(r"<svg\b|</svg>", old):
            depth += -1 if match.group() == "</svg>" else 1
            if depth == 0:
                end = start + match.end()
                break
        placement = " ".join(f'{key}="{embedded.attrib[key]}"' for key in ["x", "y", "width", "height"])
        replacement = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" {placement}>' + icon[icon.index(">") + 1:icon.rindex("</svg>")] + "</svg>"
        banner = banner[:start] + replacement + banner[end:]
        banner = banner.replace("the project's white, blue, orange, and green SwarmHub bot marks", "the website's round two-eye SwarmHub logo")
        banner = banner.replace("the project's colorful SwarmHub bot marks below the headline", "the website's round two-eye SwarmHub logo below the headline")
        ET.fromstring(banner)
        path.write_text(banner)

    # iOS applies its own icon mask; use the same artwork on an opaque canvas.
    ios_icon = ROOT / "Apps/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon.png"
    subprocess.run([renderer, "--width", "1024", "--height", "1024",
                    "--background-color", "#f7f7f2", "--output", str(ios_icon),
                    str(ASSETS / "SwarmHub-icon.svg")], check=True)

    iconutil = shutil.which("iconutil")
    if iconutil:
        subprocess.run([iconutil, "--convert", "icns", str(iconset),
                        "--output", str(ASSETS / "SwarmHub.icns")], check=True)
    print("Exported the approved website logo to all Mac icon sizes, the iOS app icon and all four README banners.")


if __name__ == "__main__":
    main()
