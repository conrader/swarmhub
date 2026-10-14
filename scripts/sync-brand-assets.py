#!/usr/bin/env python3
"""Export the complete SwarmHub logo to README banners and app assets."""
from pathlib import Path
import argparse
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
CANONICAL = ROOT / 'Resources/AppIcon/SwarmHub-icon.svg'
SOURCE = CANONICAL.read_text()


def embedded(prefix='brand-'):
    source = SOURCE
    for name in re.findall(r'\bid="([^"]+)"', SOURCE):
        source = source.replace(f'id="{name}"', f'id="{prefix}{name}"')
        source = source.replace(f'url(#{name})', f'url(#{prefix}{name})')
    return re.sub(r'<svg\b[^>]*>', '', source, count=1).rsplit('</svg>', 1)[0]


def sync_banner(path):
    text = path.read_text()
    pattern = r'(<svg\b[^>]*viewBox="0 0 1024 1024"[^>]*>).*?</svg>'
    text, count = re.subn(pattern, lambda match: match[1] + embedded() + '</svg>', text, flags=re.S)
    if count != 1:
        raise ValueError(f'Expected one full logo slot in {path}')
    path.write_text('\n'.join(line.rstrip() for line in text.splitlines()) + '\n')


def render(source, destination, size, opaque=False):
    destination.parent.mkdir(parents=True, exist_ok=True)
    command = ['rsvg-convert', '--width', str(size), '--height', str(size)]
    if opaque:
        command += ['--background-color', '#16171B']
    subprocess.run(command + ['--output', str(destination), str(source)], check=True)


def sync():
    # The compatibility filename must retain the complete composition too.
    CANONICAL.with_name('SwarmHub-icon-small.svg').write_text(SOURCE)
    CANONICAL.with_name('SwarmHub-logo.svg').write_text(SOURCE)
    for name in ['docs/readme/hero.svg', 'docs/readme/hero-mobile.svg',
                 'Apps/iOS/assets/readme-hero.svg', 'Apps/iOS/assets/readme-hero-mobile.svg']:
        sync_banner(ROOT / name)
    for points in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            suffix = '@2x' if scale == 2 else ''
            render(CANONICAL, CANONICAL.parent / 'AppIcon.iconset' / f'icon_{points}x{points}{suffix}.png', points * scale)
    render(CANONICAL, CANONICAL.parent / 'preview-1024.png', 1024)
    resources = ROOT / 'Apps/iOS/Resources/Assets.xcassets'
    render(CANONICAL, resources / 'AppIcon.appiconset/Icon.png', 1024, opaque=True)
    brand = resources / 'SwarmHubBrand.imageset'
    render(CANONICAL, brand / 'Logo.png', 512)
    (brand / 'Contents.json').write_text('{"images":[{"filename":"Logo.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}\n')


if __name__ == '__main__':
    argparse.ArgumentParser(description=__doc__).parse_args()
    sync()
    print('Updated README banners and app assets with the complete four-agent logo.')
