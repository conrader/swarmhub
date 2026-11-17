# SwarmHub app icon

The icon is "Crew": three rounded faces close together, the main bot in front, each with two upright bars for eyes.
Cream (`#f7f7f2`) and dark olive (`#262821`), with a sage and a clay face behind (Konrad chose it on 2026-11-17 in place
of the round two-eye mark, which read as a shirt button). The website header still shows the earlier round mark; it
is not in this repository.

`scripts/render-app-icon.py` is the source of the drawing: the shapes, colours and every export are written there.

```bash
python3 scripts/render-app-icon.py               # everything it can do on this machine
python3 scripts/render-app-icon.py --renditions  # Mac with Xcode 26 or later: what macOS draws from AppIcon.icon
python3 scripts/render-app-icon.py --icns        # Mac: SwarmHub-dark.icns from the dark iconset
```

The full run needs `rsvg-convert` (librsvg), or Chrome or Chromium together with Pillow. After a change to the drawing:
run `--renditions` on a Mac, bring `Renditions/` back, run the script, then `--icns` on a Mac. `AppIconTests` fails
while `Renditions/` belongs to an older drawing.

## What is here

| File | What it is |
| --- | --- |
| `SwarmHub-icon-light.svg`, `SwarmHub-icon-dark.svg` | The full drawing on the macOS tile (an 824 px tile with the continuous corner on a 1024 px canvas). Light: an olive face with cream eyes on a cream tile. Dark: a cream face with olive eyes on an olive tile. |
| `SwarmHub-icon-*-32.svg`, `SwarmHub-icon-*-16.svg` | Simpler drawings laid out on the 32 px and the 16 px grid: no tilt, flat colours, a hairline round the tile; at 16 px only the front face has eyes. |
| `SwarmHub-icon-ios.svg` | The light drawing edge to edge on an opaque canvas, for iOS, which masks the icon itself. |
| `SwarmHub-mark.svg` | The three faces alone, flat: the mark that stands beside the name. |
| `AppIcon.icon/` | The Icon Composer icon: `icon.json` and one SVG per layer in `Assets/` (each face and its eyes), with the colours of the dark style. |
| `Renditions/default.png`, `dark.png` | The pictures macOS draws from `AppIcon.icon` in the Default and the Dark icon style (Icon Composer's `ictool`, the macOS 26 look), and `source.sha256`, which names the icon they were made from. |
| `AppIcon.iconset/`, `AppIcon-dark.iconset/` | The ten Mac sizes. 16 and 32 px are the small drawings; 64 px and larger are `Renditions/` inside the usual margin over the usual shadow. |
| `ThemeIcons/SwarmHub-light.png`, `SwarmHub-dark.png` | The 1024 px images of the two iconsets, bundled for the running app. |
| `SwarmHub-dark.icns` | The dark iconset as a native icon. |
| `preview-1024.png` | The largest light image. |

The same script writes the iOS seed's icon (`Apps/iOS-seed/Resources/Assets.xcassets/AppIcon.appiconset/Icon.png`)
and replaces the icon and the small mark inside the four README banners (`docs/readme/` and `Apps/iOS-seed/assets/`).

## How the app gets its icon

`scripts/package-release.sh` puts three things into the app's `Contents/Resources/`:

- `Assets.car`, compiled from `AppIcon.icon` with `actool` (`CFBundleIconName` = `AppIcon`). macOS 26 and later draw
  the icon from it wherever the app is not running: Finder, Launchpad, the Dock. They draw it in the icon style of the
  Mac (System Settings → Appearance → Icon & widget style): Default, Dark, Clear or Tinted. Dark is our own dark
  drawing; Clear and Tinted are derived by macOS from the layers. Without `Assets.car`, a Mac with dark icons darkens
  the icns itself (checked on macOS 26.6: it ignores `AppIcon-dark.icns` and dark variants in an asset catalog's Mac
  icon set).
- `AppIcon.icns` from `AppIcon.iconset` (`CFBundleIconFile` = `AppIcon`), the icon on macOS before 26. `actool` writes
  an icns of its own; the script makes ours after it, so the small sizes are the small drawings.
- `ThemeIcons/` and `AppIcon-dark.icns`, for the running app.

`AppIcon.icon` was written by hand, without the Icon Composer app: the format is a folder with `icon.json` and the
layer images. Two things are not obvious. Layers are drawn on the whole 1024 px canvas (macOS masks and insets them),
so the script scales the tile's artwork up by 1024/824. And a value that changes with the icon style is a
`…-specializations` list whose first entry has no appearance; a plain `fill` beside such a list wins, and macOS then
picks the dark tile itself. `ictool` (in `Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/`)
draws any of the six styles of an icon to a PNG, which is how `Renditions/` is made and how a change can be checked
without changing the Mac's settings.

## Light and dark while the app runs (P38)

`AppIconAppearance` is the one place that decides which icon the running app draws: in the Dock, in the About panel
and on the setup wizard's first page. The icon is Light everywhere, also for installs that never picked one; it is
Dark only where Settings → Appearance → App icon says Dark and the app is shown dark (Theme Dark, or Theme System on a
dark Mac) (Konrad 2026-10-22 and 2026-11-17). The app sets its icon as the first step of launch and gives the same
image to the About panel. SwiftPM, the `swiftc` fallback and `package-release.sh` all include `ThemeIcons/`; the
`swiftc` fallback copies `SwarmHub-dark.icns` beside the binary and the packaged app carries `AppIcon-dark.icns`, so a
dark icon is still found when the dark PNG cannot be read (the light icon falls back to the app's `AppIcon.icns`).

So on a Mac whose icon style is Dark, the icon in the Dock is our dark drawing while the app is closed and the light
one while it runs, unless Dark is picked in Settings. The two light images are the same picture: `ThemeIcons/` is
what macOS draws from `AppIcon.icon` in the Default style.
