# SwarmHub logo and Mac icon

`SwarmHub-logo.svg` is the round two-eye mark used beside the name on swarmhub.org. Its shape, eye spacing, −9° tilt, dark olive (`#262821`) and cream (`#f7f7f2`) match the website header.

The Mac icon places that mark on a cream rounded tile, with transparent outer padding. `SwarmHub-icon.svg` is the generated vector version; `SwarmHub-icon-small.svg` contains the same design. `AppIcon.iconset/` contains all ten standard Mac icon files, from 16 to 1024 pixels. `preview-1024.png` is the largest export.

Regenerate the Mac iconset, the iPhone icon kept in `Apps/iOS-seed`, and the embedded icons in all four README banners (two in `docs/readme`, two in `Apps/iOS-seed/assets`):

```bash
python3 scripts/render-app-icon.py
```

There is no iPhone app. The icon kept for one uses the same approved mark on an opaque cream canvas, in `Apps/iOS-seed/Resources/Assets.xcassets/AppIcon.appiconset/Icon.png`.

The renderer requires `rsvg-convert` from librsvg. On a Mac with `iconutil`, it also creates `SwarmHub.icns`. To create the native icon from the committed PNGs without the SVG renderer:

```bash
iconutil --convert icns Resources/AppIcon/AppIcon.iconset \
  --output Resources/AppIcon/SwarmHub.icns
```

`scripts/package-release.sh` builds `SwarmHub.icns` directly from the iconset and places it in the app's `Contents/Resources/` before signing. `CFBundleIconFile` in `Resources/Info.plist` points to it, so Finder and Dock use the icon in packaged apps. Existing published installers retain their original signed resources until a new app release is built.

## Light and dark icon (P38)

`SwarmHub-logo-dark.svg` and `SwarmHub-icon-dark.svg` are the dark drawing: a cream face with olive eyes on an olive
tile. `AppIcon-dark.iconset/` holds its ten Mac sizes. `ThemeIcons/SwarmHub-light.png` and `SwarmHub-dark.png` (1024 px)
are bundled for `AppIconAppearance`, the one place that decides which icon the running app draws: in the Dock, in the
About panel and on the setup wizard's first page. The icon is Light everywhere, also for installs that never picked
one; it is Dark only where Settings → Appearance → App icon says Dark and the app is shown dark (Theme Dark, or Theme
System on a dark Mac) (Konrad 2026-10-22 and 2026-11-17). SwiftPM, the `swiftc` fallback and `package-release.sh` all
include `ThemeIcons/`. `AppIcon.icns` is the light icon the bundle carries for Finder.

On macOS 26 with the icon style set to Dark (System Settings → Appearance → Icon & widget style), macOS does not show
`AppIcon.icns` as drawn: it redraws every bundle icon as a dark tile, and it ignores `AppIcon-dark.icns` and dark
variants in an asset catalog's Mac icon set (checked on macOS 26.6 with Xcode 27.2). The standard About panel and the
Dock during launch used that drawing. The app therefore sets its own icon as the first step of launch and gives the
same image to the About panel. Finder, Launchpad and the Dock before the app runs still show the system's drawing on
such a Mac; only an Icon Composer icon with its own dark variant changes that.

`SwarmHub-logo-light.svg` and `SwarmHub-icon-light.svg` are the light drawing under explicit names (the default paths
above keep the same drawing). `SwarmHub-dark.icns` is the dark iconset as a native icon (`iconutil --convert icns
Resources/AppIcon/AppIcon-dark.iconset --output Resources/AppIcon/SwarmHub-dark.icns`); `package-release.sh` builds it
into the app as `AppIcon-dark.icns` and the `swiftc` fallback copies it beside the binary, so `AppIconAppearance` still
finds a dark icon when the dark PNG cannot be read (the light icon falls back to the app's `AppIcon.icns` the same
way). `preview-appearances.png` (from `preview-appearances.svg`) shows both drawings at large and small sizes.
