#!/usr/bin/env python3
"""Draw SwarmHub's app icon, "Crew", and export it to every place it lives.

Crew is three rounded faces close together, the main bot in front, each with the two upright bars for eyes; cream and
olive, with a sage and a clay face behind. This script is the source of the drawing. It writes, under Resources/AppIcon:

  SwarmHub-icon-{light,dark}.svg        the full drawing on the macOS tile (824 px tile on a 1024 px canvas)
  SwarmHub-icon-{light,dark}-32.svg     a simpler drawing on the 32 px grid (no tilt, short eyes on the back faces)
  SwarmHub-icon-{light,dark}-16.svg     the simplest, on the 16 px grid (front face with eyes, two plain faces behind)
  SwarmHub-icon-ios.svg                 the light drawing edge to edge, for iOS (which masks the icon itself)
  SwarmHub-mark.svg                     the three faces alone, the mark that stands beside the name
  AppIcon.icon/                         the Icon Composer icon: one SVG per layer and icon.json, with its dark variant
  Renditions/{default,dark}.png         what macOS draws from AppIcon.icon (only made on a Mac with Xcode)
  AppIcon.iconset, AppIcon-dark.iconset the ten Mac sizes; ThemeIcons/ the two 1024 px images the app sets itself
  SwarmHub-dark.icns                    (only made on a Mac: iconutil)

and the app icon of Apps/iOS-seed, and the icon and the small mark inside the four README banners.

16 and 32 px come from their own drawings. 64 px and larger come from Renditions/ inside the usual margin, so the
icon the app sets while it runs is the picture macOS draws from AppIcon.icon; where Renditions/ is missing or older
than the drawing they come from the full SVG drawing instead, and the script says so.

Needs rsvg-convert (librsvg), or Google Chrome/Chromium together with Pillow. Run: python3 scripts/render-app-icon.py
Two steps need a Mac and nothing else, so they also run alone: `--renditions` (Xcode's ictool) and `--icns` (iconutil).
"""

import base64
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Resources/AppIcon"
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
BANNERS = ["docs/readme/hero.svg", "docs/readme/hero-mobile.svg",
           "Apps/iOS-seed/assets/readme-hero.svg", "Apps/iOS-seed/assets/readme-hero-mobile.svg"]
IOS_ICON = ROOT / "Apps/iOS-seed/Resources/Assets.xcassets/AppIcon.appiconset/Icon.png"
ICTOOL = "Applications/Icon Composer.app/Contents/Executables/ictool"
# The macOS release whose look Renditions/ are drawn in (ictool --design-generation).
DESIGN_GENERATION = "26"

OLIVE, CREAM = "#262821", "#f7f7f2"
# Per appearance: the tile and each face as (top, bottom) of a vertical gradient, and the eyes.
LOOKS = {
    "light": {"tile": ("#fcfbf5", "#eceadf"), "front": ("#3b3d33", "#22241d"), "front-eyes": CREAM,
              "left": ("#a9c4a3", "#86a680"), "right": ("#f0b88c", "#dc9763"), "back-eyes": OLIVE},
    "dark": {"tile": ("#3a3c32", "#1e201a"), "front": ("#fbfaf3", "#e4e1d3"), "front-eyes": OLIVE,
             "left": ("#8fae8a", "#6f9069"), "right": ("#e0a070", "#c47f50"), "back-eyes": OLIVE},
}
# The flat colours of the Icon Composer layers (macOS adds the light and the depth itself).
LAYER_COLOURS = {
    "light": {"tile": ("#fbfaf4", "#e9e6d9"), "front": "#2f3128", "front-eyes": CREAM, "left": "#9fbb99", "right": "#eaa878", "back-eyes": OLIVE},
    "dark": {"tile": ("#4a4d3f", "#22241c"), "front": "#f8f7f0", "front-eyes": OLIVE, "left": "#8fae8a", "right": "#dc9763", "back-eyes": OLIVE},
}
# The small drawings are flat and a little stronger in colour.
SMALL = {
    "light": {"front": "#2b2d25", "left": "#97c08f", "right": "#f0a56e"},
    "dark": {"front": "#f7f6ee", "left": "#8fb888", "right": "#e69a60"},
}
# The faces of the full drawing: name, centre, size, turn in degrees, how far above the centre the eyes sit.
FACES = [("left", 330, 360, 300, -11, 0.13), ("right", 694, 360, 300, 11, 0.13), ("front", 512, 590, 416, 0, 0.06)]
TILE = (100, 100, 824, 185.4)
EYE_TILT = -9


def f(value):
    return f"{value:.2f}".rstrip("0").rstrip(".")


def squircle(x, y, w, h, r):
    """A rounded rectangle with Apple's continuous corner (the constants of UIBezierPath's rounded rectangle)."""
    a, b, c, d, e, g, k = 1.528665, 1.08849296, 0.86840694, 0.63149379, 0.07491139, 0.37282383, 0.16905956
    r = min(r, w / (2 * a), h / (2 * a))
    X, Y = x + w, y + h
    return "".join([
        f"M{f(x + a * r)} {f(y)}L{f(X - a * r)} {f(y)}",
        f"C{f(X - b * r)} {f(y)} {f(X - c * r)} {f(y)} {f(X - d * r)} {f(y + e * r)}",
        f"C{f(X - g * r)} {f(y + k * r)} {f(X - k * r)} {f(y + g * r)} {f(X - e * r)} {f(y + d * r)}",
        f"C{f(X)} {f(y + c * r)} {f(X)} {f(y + b * r)} {f(X)} {f(y + a * r)}L{f(X)} {f(Y - a * r)}",
        f"C{f(X)} {f(Y - b * r)} {f(X)} {f(Y - c * r)} {f(X - e * r)} {f(Y - d * r)}",
        f"C{f(X - k * r)} {f(Y - g * r)} {f(X - g * r)} {f(Y - k * r)} {f(X - d * r)} {f(Y - e * r)}",
        f"C{f(X - c * r)} {f(Y)} {f(X - b * r)} {f(Y)} {f(X - a * r)} {f(Y)}L{f(x + a * r)} {f(Y)}",
        f"C{f(x + b * r)} {f(Y)} {f(x + c * r)} {f(Y)} {f(x + d * r)} {f(Y - e * r)}",
        f"C{f(x + g * r)} {f(Y - k * r)} {f(x + k * r)} {f(Y - g * r)} {f(x + e * r)} {f(Y - d * r)}",
        f"C{f(x)} {f(Y - c * r)} {f(x)} {f(Y - b * r)} {f(x)} {f(Y - a * r)}L{f(x)} {f(y + a * r)}",
        f"C{f(x)} {f(y + b * r)} {f(x)} {f(y + c * r)} {f(x + e * r)} {f(y + d * r)}",
        f"C{f(x + k * r)} {f(y + g * r)} {f(x + g * r)} {f(y + k * r)} {f(x + d * r)} {f(y + e * r)}",
        f"C{f(x + c * r)} {f(y)} {f(x + b * r)} {f(y)} {f(x + a * r)} {f(y)}Z"])


def gradient(name, stops, x2=0, y2=1):
    """A linear gradient; a stop is (offset, colour) or (offset, colour, opacity)."""
    body = "".join('<stop offset="%s" stop-color="%s"%s/>' % (stop[0], stop[1], "" if len(stop) < 3 else ' stop-opacity="%s"' % stop[2])
                   for stop in stops)
    return f'<linearGradient id="{name}" x1="0" y1="0" x2="{x2}" y2="{y2}">{body}</linearGradient>'


def blur(name, deviation):
    return f'<filter id="{name}" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="{deviation}"/></filter>'


def document(title, defs, body):
    text = (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            f'<title>{title}</title>\n<defs>{defs}</defs>\n{body}\n</svg>\n')
    ET.fromstring(text)
    return text


def face_path(cx, cy, size):
    return squircle(cx - size / 2, cy - size / 2, size, size, size * 0.29)


def eyes(cx, cy, size, fill, tilt=EYE_TILT):
    """The two upright bars: an eighth of the face wide, a little tilted."""
    w, h, gap = size * 0.125, size * 0.31, size * 0.17
    return (f'<g transform="rotate({tilt} {f(cx)} {f(cy)})" fill="{fill}">'
            f'<rect x="{f(cx - gap / 2 - w)}" y="{f(cy - h / 2)}" width="{f(w)}" height="{f(h)}" rx="{f(w / 2)}"/>'
            f'<rect x="{f(cx + gap / 2)}" y="{f(cy - h / 2)}" width="{f(w)}" height="{f(h)}" rx="{f(w / 2)}"/></g>')


def tile(look, p):
    """The macOS tile: a soft shadow in the margin, a vertical gradient, a lit upper edge and a shaded lower edge."""
    x, y, size, radius = TILE
    path = squircle(x, y, size, size, radius)
    dark = look == "dark"
    top, bottom = LOOKS[look]["tile"]
    defs = (gradient(p + "tile", [(0, top), (1, bottom)])
            + gradient(p + "tile-edge", [(0, "#ffffff", 0.22 if dark else 0.6), (0.45, "#ffffff", 0)])
            + gradient(p + "tile-foot", [(0.6, "#000000", 0), (1, "#000000", 0.3 if dark else 0.1)])
            + f'<clipPath id="{p}tile-clip"><path d="{path}"/></clipPath>' + blur(p + "tile-shadow", 14))
    body = (f'<path d="{path}" transform="translate(0 10)" fill="#000000" opacity="{0.36 if dark else 0.24}" filter="url(#{p}tile-shadow)"/>'
            f'<path d="{path}" fill="url(#{p}tile)"/>'
            f'<g clip-path="url(#{p}tile-clip)"><path d="{path}" fill="none" stroke="url(#{p}tile-foot)" stroke-width="10"/>'
            f'<path d="{path}" fill="none" stroke="url(#{p}tile-edge)" stroke-width="7"/></g>')
    return defs, body


def drawing(look, p=""):
    """The full drawing. `p` prefixes every id, for a copy placed inside another SVG."""
    dark = look == "dark"
    colours = LOOKS[look]
    defs, body = tile(look, p)
    defs += (gradient(p + "face-edge", [(0, "#ffffff", 0.6 if dark else 0.5), (0.4, "#ffffff", 0)])
             + gradient(p + "face-foot", [(0.55, "#000000", 0), (1, "#000000", 0.16)]) + blur(p + "face-shadow", 16))
    faces = ""
    for name, cx, cy, size, turn, rise in FACES:
        path = face_path(cx, cy, size)
        defs += gradient(p + name, [(0, colours[name][0]), (1, colours[name][1])]) + f'<clipPath id="{p}{name}-clip"><path d="{path}"/></clipPath>'
        eye = colours["front-eyes" if name == "front" else "back-eyes"]
        faces += (f'<g transform="rotate({turn} {f(cx)} {f(cy)})">'
                  f'<path d="{path}" transform="translate(0 14)" fill="#000000" opacity="{0.45 if dark else 0.22}" filter="url(#{p}face-shadow)"/>'
                  f'<path d="{path}" fill="url(#{p}{name})"/>'
                  f'<g clip-path="url(#{p}{name}-clip)"><path d="{path}" fill="none" stroke="url(#{p}face-foot)" stroke-width="12"/>'
                  f'<path d="{path}" fill="none" stroke="url(#{p}face-edge)" stroke-width="8" opacity="0.7"/></g>'
                  + eyes(cx, cy - size * rise, size, eye) + '</g>')
    body += f'<g clip-path="url(#{p}tile-clip)">{faces}</g>'
    return document(f"SwarmHub app icon, {look} appearance", defs, body)


def small(look, pixels):
    """The drawing for 32 or 16 px, laid out on that size's pixel grid: `u` is one pixel."""
    u = 1024 / pixels
    dark = look == "dark"
    colours = LOOKS[look]
    inset = 3 if pixels == 32 else 1
    tile_path = squircle(inset * u, inset * u, 1024 - 2 * inset * u, 1024 - 2 * inset * u, (1024 - 2 * inset * u) * 0.225)
    defs = (gradient("tile", [(0, colours["tile"][0]), (1, colours["tile"][1])]) + f'<clipPath id="tile-clip"><path d="{tile_path}"/></clipPath>')
    # A hairline keeps the cream tile whole on a white window and the olive tile whole on a black one.
    edge = "#ffffff" if dark else "#000000"
    body = (f'<path d="{tile_path}" fill="url(#tile)"/>'
            f'<g clip-path="url(#tile-clip)"><path d="{tile_path}" fill="none" stroke="{edge}" stroke-opacity="{0.16 if dark else 0.14}" stroke-width="{f(u)}"/></g>')

    def box(name, x, y, w, h, radius):
        return f'<path d="{squircle(x * u, y * u, w * u, h * u, radius * u)}" fill="{SMALL[look][name]}"/>'

    def bars(x1, x2, y, w, h, fill):
        return "".join(f'<rect x="{f(x * u)}" y="{f(y * u)}" width="{f(w * u)}" height="{f(h * u)}" rx="{f(w * u / 2)}" fill="{fill}"/>' for x in (x1, x2))

    if pixels == 32:
        body += (box("left", 5, 5, 10.5, 11, 3.1) + box("right", 16.5, 5, 10.5, 11, 3.1)
                 + bars(9, 11, 7, 1, 3, colours["back-eyes"]) + bars(20, 22, 7, 1, 3, colours["back-eyes"])
                 + box("front", 8, 11, 16, 16, 4.6) + bars(12, 18, 15.5, 2, 6, colours["front-eyes"]))
    else:
        body += (box("left", 2, 3, 5.5, 6, 1.6) + box("right", 8.5, 3, 5.5, 6, 1.6)
                 + box("front", 4, 6, 8, 8, 2.3) + bars(6, 9, 8, 1, 4, colours["front-eyes"]))
    return document(f"SwarmHub app icon, {look} appearance, drawn for {pixels} px", defs, body)


def edge_to_edge(inner):
    """Artwork drawn for the 824 px tile, spread over the whole canvas."""
    x, _, size, _ = TILE
    return f'<g transform="translate(512 512) scale({f(1024 / size)}) translate(-512 -512)">{inner}</g>'


def ios_drawing():
    colours = LOOKS["light"]
    defs = gradient("canvas", [(0, colours["tile"][0]), (1, colours["tile"][1])])
    faces = ""
    for name, cx, cy, size, turn, rise in FACES:
        defs += gradient(name, [(0, colours[name][0]), (1, colours[name][1])])
        eye = colours["front-eyes" if name == "front" else "back-eyes"]
        faces += (f'<g transform="rotate({turn} {f(cx)} {f(cy)})"><path d="{face_path(cx, cy, size)}" fill="url(#{name})"/>'
                  + eyes(cx, cy - size * rise, size, eye) + '</g>')
    return document("SwarmHub app icon for iOS", defs, '<rect width="1024" height="1024" fill="url(#canvas)"/>' + edge_to_edge(faces))


def mark():
    """The three faces alone, flat, in a 30 x 30 box: the mark that stands beside the name."""
    colours = LAYER_COLOURS["light"]
    faces = ""
    for name, cx, cy, size, turn, rise in FACES:
        eye = colours["front-eyes" if name == "front" else "back-eyes"]
        faces += (f'<g transform="rotate({turn} {f(cx)} {f(cy)})"><path d="{face_path(cx, cy, size)}" fill="{colours[name]}"/>'
                  + eyes(cx, cy - size * rise, size, eye) + '</g>')
    return f'<g transform="translate(15 15) scale(0.042) translate(-512 -491)">{faces}</g>'


# ---------------------------------------------------------------- the Icon Composer icon

def srgb(colour):
    return "srgb:" + ",".join(f"{int(colour[i:i + 2], 16) / 255:.5f}" for i in (1, 3, 5)) + ",1.00000"


def layers():
    """One SVG per layer, edge to edge: Icon Composer wants the artwork on the whole 1024 px canvas and masks it itself."""
    colours = LAYER_COLOURS["light"]
    out = {}
    for name, cx, cy, size, turn, rise in FACES:
        eye = colours["front-eyes" if name == "front" else "back-eyes"]
        head = f'<g transform="rotate({turn} {f(cx)} {f(cy)})"><path d="{face_path(cx, cy, size)}" fill="{colours[name]}"/></g>'
        pair = f'<g transform="rotate({turn} {f(cx)} {f(cy)})">' + eyes(cx, cy - size * rise, size, eye) + '</g>'
        for layer, inner in ((name, head), (name + "-eyes", pair)):
            text = f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{edge_to_edge(inner)}</svg>\n'
            ET.fromstring(text)
            out[layer] = text
    return out


def icon_document():
    """icon.json. The first group is the front one. A value that differs in the dark style is a `-specializations` list
    whose first entry has no appearance; a plain `fill` beside it would win and macOS would pick the dark tile itself.
    The tinted and clear styles are left to macOS, which derives them from the layers."""
    light, dark = LAYER_COLOURS["light"], LAYER_COLOURS["dark"]

    def fill(name):
        return [{"value": {"solid": srgb(light[name])}}, {"appearance": "dark", "value": {"solid": srgb(dark[name])}}]

    def group(name):
        eye = "front-eyes" if name == "front" else "back-eyes"
        return {"layers": [{"image-name": f"{name}-eyes.svg", "name": f"{name}-eyes", "fill-specializations": fill(eye)},
                           {"image-name": f"{name}.svg", "name": name, "fill-specializations": fill(name)}],
                "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": False, "value": 0.5}}

    return {"fill-specializations": [{"value": {"linear-gradient": [srgb(c) for c in light["tile"]]}},
                                     {"appearance": "dark", "value": {"linear-gradient": [srgb(c) for c in dark["tile"]]}}],
            "groups": [group("front"), group("right"), group("left")],
            "supported-platforms": {"squares": "shared"}}


def write_icon_composer_icon():
    icon = ASSETS / "AppIcon.icon"
    (icon / "Assets").mkdir(parents=True, exist_ok=True)
    for name, text in layers().items():
        (icon / "Assets" / f"{name}.svg").write_text(text)
    (icon / "icon.json").write_text(json.dumps(icon_document(), indent=2) + "\n")
    return icon


def icon_digest(icon):
    """Names and bytes of the icon's files, in name order (Finder's dot files left out); AppIconTests computes the same."""
    digest = hashlib.sha256()
    files = {path.relative_to(icon).as_posix(): path for path in icon.rglob("*") if path.is_file() and not path.name.startswith(".")}
    for name in sorted(files):
        digest.update(name.encode() + b"\0" + files[name].read_bytes())
    return digest.hexdigest() + f" generation {DESIGN_GENERATION}\n"


def find_ictool():
    try:
        developer = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
    except OSError:
        return None
    tool = Path(developer).parent / ICTOOL if developer else None
    return tool if tool and tool.exists() else None


def renditions(icon):
    """The light and the dark picture macOS draws from the icon; None where they are missing or older than the drawing."""
    folder = ASSETS / "Renditions"
    wanted = icon_digest(icon)
    tool = find_ictool()
    if tool:
        folder.mkdir(exist_ok=True)
        for name, rendition in (("default", "Default"), ("dark", "Dark")):
            subprocess.run([str(tool), str(icon), "--export-image", "--output-file", str(folder / f"{name}.png"), "--platform", "macOS",
                            "--rendition", rendition, "--width", "1024", "--height", "1024", "--scale", "1",
                            "--design-generation", DESIGN_GENERATION], check=True, stdout=subprocess.DEVNULL)
        (folder / "source.sha256").write_text(wanted)
    stamp = folder / "source.sha256"
    if stamp.exists() and stamp.read_text() == wanted and all((folder / f"{name}.png").exists() for name in ("default", "dark")):
        return {"light": folder / "default.png", "dark": folder / "dark.png"}
    print("Renditions/ is missing or older than the drawing: 64 px and larger come from the SVG drawing. "
          "Run this script on a Mac with Xcode, then here again.")
    return None


def on_tile(picture, look):
    """macOS's picture of the icon inside the usual margin, over the shadow macOS puts under an icon."""
    x, y, size, radius = TILE
    data = base64.b64encode(picture.read_bytes()).decode()
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><defs>{blur("shadow", 13)}</defs>'
            f'<path d="{squircle(x, y, size, size, radius)}" transform="translate(0 9)" fill="#000000" opacity="{0.4 if look == "dark" else 0.3}" filter="url(#shadow)"/>'
            f'<image x="{x}" y="{y}" width="{size}" height="{size}" href="data:image/png;base64,{data}"/></svg>\n')


# ---------------------------------------------------------------- rendering

def chrome():
    for name in ("google-chrome", "chromium", "chromium-browser"):
        if shutil.which(name):
            return shutil.which(name)
    mac = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    return str(mac) if mac.exists() else None


def render(jobs):
    """Each job is (svg file, png file, pixels, opaque)."""
    rsvg = shutil.which("rsvg-convert")
    if rsvg:
        for source, target, pixels, opaque in jobs:
            subprocess.run([rsvg, "--width", str(pixels), "--height", str(pixels)] + (["--background-color", CREAM] if opaque else [])
                           + ["--output", str(target), str(source)], check=True)
        return
    browser = chrome()
    try:
        from PIL import Image
    except ImportError:
        Image = None
    if not browser or Image is None:
        raise SystemExit("Install librsvg (rsvg-convert), or Chrome together with Pillow, to render the SVG icon.")
    # One page with every image at its own size, one screenshot, then cut apart: a Chrome start costs seconds.
    x = y = row = 0
    placed = []
    for job in sorted(jobs, key=lambda job: -job[2]):
        if x + job[2] > 4096:
            x, y, row = 0, y + row, 0
        placed.append((job, x, y))
        x, row = x + job[2], max(row, job[2])
    with tempfile.TemporaryDirectory() as folder:
        cells = "".join(f'<img src="{source.resolve().as_uri()}" style="position:absolute;left:{px}px;top:{py}px;width:{size}px;height:{size}px">'
                        for (source, _, size, _), px, py in placed)
        page = Path(folder) / "page.html"
        page.write_text(f'<!doctype html><html><body style="margin:0;background:transparent">{cells}</body></html>')
        shot = Path(folder) / "page.png"
        subprocess.run([browser, "--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--no-proxy-server",
                        "--disable-background-networking", "--disable-component-update", "--disable-sync", "--disable-extensions",
                        "--no-first-run", "--disable-features=NetworkServiceSandbox,Translate,OptimizationHints,MediaRouter",
                        f"--user-data-dir={folder}/profile", "--hide-scrollbars", "--force-device-scale-factor=1",
                        f"--screenshot={shot}", f"--window-size=4096,{y + row}", "--default-background-color=00000000", page.as_uri()],
                       check=True, timeout=600, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sheet = Image.open(shot).convert("RGBA")
        for (_, target, size, opaque), px, py in placed:
            image = sheet.crop((px, py, px + size, py + size))
            (image.convert("RGB") if opaque else image).save(target)


def replace_banner_icon(path, icon):
    """Preserve the banner's layout and copy; replace only the icon placed in it and the words that describe it."""
    banner = path.read_text()
    tree = ET.fromstring(banner)
    namespace = "{http://www.w3.org/2000/svg}"
    embedded = next((node for node in tree.iter(f"{namespace}svg")
                     if node.attrib.get("viewBox") == "0 0 1024 1024" and all(key in node.attrib for key in ["x", "y", "width", "height"])), None)
    if embedded is None:
        raise SystemExit(f"No embedded icon in {path}")
    start = re.search(r'<svg\b[^>]*viewBox="0 0 1024 1024"[^>]*>', banner).start()
    depth = 0
    for match in re.finditer(r"<svg\b|</svg>", banner[start:]):
        depth += -1 if match.group() == "</svg>" else 1
        if depth == 0:
            end = start + match.end()
            break
    placement = " ".join(f'{key}="{embedded.attrib[key]}"' for key in ["x", "y", "width", "height"])
    inner = icon[icon.index(">") + 1:icon.rindex("</svg>")]
    banner = banner[:start] + f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" {placement}>' + inner + "</svg>" + banner[end:]
    # The small mark beside the name.
    banner, marks = re.subn(r'(<svg\b[^>]*viewBox="0 0 30 30"[^>]*>).*?</svg>', lambda m: m.group(1) + "<title>SwarmHub</title>" + mark() + "</svg>",
                            banner, flags=re.S)
    if marks != 1:
        raise SystemExit(f"Expected one small mark in {path}, found {marks}")
    for old, new in (("the website's round two-eye SwarmHub logo below the headline", "the SwarmHub app icon below the headline: three rounded faces close together"),
                     ("the website's round two-eye SwarmHub logo", "the SwarmHub app icon: three rounded faces close together"),
                     ("The website's approved round two-eye SwarmHub mark", "The SwarmHub app icon, three rounded faces close together,")):
        banner = banner.replace(old, new)
    ET.fromstring(banner)
    path.write_text(banner)


def build_icns():
    iconutil = shutil.which("iconutil")
    if iconutil:
        subprocess.run([iconutil, "--convert", "icns", str(ASSETS / "AppIcon-dark.iconset"), "--output", str(ASSETS / "SwarmHub-dark.icns")], check=True)
    else:
        print("No iconutil here: SwarmHub-dark.icns was not rebuilt (run `scripts/render-app-icon.py --icns` on a Mac).")


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)
    # The two steps only a Mac can do, each on its own: neither needs an SVG renderer.
    if "--icns" in sys.argv:
        return build_icns()
    if "--renditions" in sys.argv:
        if not find_ictool():
            raise SystemExit("Icon Composer's ictool was not found: install Xcode 26 or later.")
        return renditions(write_icon_composer_icon())
    sources = {}
    for look in LOOKS:
        sources[look, "full"] = ASSETS / f"SwarmHub-icon-{look}.svg"
        sources[look, "full"].write_text(drawing(look))
        for pixels in (32, 16):
            sources[look, pixels] = ASSETS / f"SwarmHub-icon-{look}-{pixels}.svg"
            sources[look, pixels].write_text(small(look, pixels))
    ios = ASSETS / "SwarmHub-icon-ios.svg"
    ios.write_text(ios_drawing())
    (ASSETS / "SwarmHub-mark.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="30" height="30" viewBox="0 0 30 30">\n<title>SwarmHub</title>\n{mark()}\n</svg>\n')
    icon = write_icon_composer_icon()
    pictures = renditions(icon)

    with tempfile.TemporaryDirectory() as folder:
        jobs, copies = [], []
        for look, iconset in (("light", ASSETS / "AppIcon.iconset"), ("dark", ASSETS / "AppIcon-dark.iconset")):
            iconset.mkdir(exist_ok=True)
            large = sources[look, "full"]
            if pictures:
                large = Path(folder) / f"{look}.svg"
                large.write_text(on_tile(pictures[look], look))
            first = {}
            for points, scale in SIZES:
                pixels = points * scale
                target = iconset / f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
                if pixels in first:
                    copies.append((first[pixels], target))
                else:
                    first[pixels] = target
                    jobs.append((sources[look, pixels] if pixels in (16, 32) else large, target, pixels, False))
            copies.append((first[1024], ASSETS / "ThemeIcons" / f"SwarmHub-{look}.png"))
        copies.append((ASSETS / "AppIcon.iconset/icon_512x512@2x.png", ASSETS / "preview-1024.png"))
        (ASSETS / "ThemeIcons").mkdir(exist_ok=True)
        # iOS applies its own mask: the same artwork on an opaque canvas.
        jobs.append((ios, IOS_ICON, 1024, True))
        render(jobs)
        for source, target in copies:
            shutil.copyfile(source, target)

    for relative in BANNERS:
        replace_banner_icon(ROOT / relative, drawing("light", p="swarmhub-icon-"))

    build_icns()
    print("Exported the Crew icon: SVG drawings, AppIcon.icon, both Mac iconsets, ThemeIcons, the iOS seed's icon and the four README banners.")


if __name__ == "__main__":
    main()
