# SwarmHub logo and Mac icon

`SwarmHub-logo.svg` is the round two-eye mark used beside the name on swarmhub.org. Its shape, eye spacing, −9° tilt, dark olive (`#262821`) and cream (`#f7f7f2`) match the website header.

The Mac icon places that mark on a cream rounded tile, with transparent outer padding. `SwarmHub-icon.svg` is the generated vector version; `SwarmHub-icon-small.svg` contains the same design. `AppIcon.iconset/` contains all ten standard Mac icon files, from 16 to 1024 pixels. `preview-1024.png` is the largest export.

Regenerate the Mac iconset, iOS app icon and the embedded icons in all four README banners:

```bash
python3 scripts/render-app-icon.py
```

The iOS app icon uses the same approved mark on an opaque cream canvas, in `Apps/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon.png`.

The renderer requires `rsvg-convert` from librsvg. On a Mac with `iconutil`, it also creates `SwarmHub.icns`. To create the native icon from the committed PNGs without the SVG renderer:

```bash
iconutil --convert icns Resources/AppIcon/AppIcon.iconset \
  --output Resources/AppIcon/SwarmHub.icns
```

`scripts/package-release.sh` builds `SwarmHub.icns` directly from the iconset and places it in the app's `Contents/Resources/` before signing. `CFBundleIconFile` in `Resources/Info.plist` points to it, so Finder and Dock use the icon in packaged apps. Existing published installers retain their original signed resources until a new app release is built.

## Light and dark Dock icon (P38)

`SwarmHub-logo-dark.svg` and `SwarmHub-icon-dark.svg` are the dark drawing: a cream face with olive eyes on an olive
tile. `AppIcon-dark.iconset/` holds its ten Mac sizes. `ThemeIcons/SwarmHub-light.png` and `SwarmHub-dark.png` (1024 px)
are bundled for `AppIconAppearance`, which sets the running app's Dock icon from Settings → Appearance → App icon: Light
(the default, also for installs that never picked one) or Dark, apart from the theme (Konrad 2026-10-22). SwiftPM, the `swiftc` fallback and `package-release.sh` all include
`ThemeIcons/`. `AppIcon.icns` stays the light icon Finder shows before launch.

`SwarmHub-logo-light.svg` and `SwarmHub-icon-light.svg` are the light drawing under explicit names (the default paths
above keep the same drawing). `SwarmHub-dark.icns` is the dark iconset as a native icon (`iconutil --convert icns
Resources/AppIcon/AppIcon-dark.iconset --output Resources/AppIcon/SwarmHub-dark.icns`); `package-release.sh` builds it
into the app as `AppIcon-dark.icns` and the `swiftc` fallback copies it beside the binary, so `AppIconAppearance` still
finds a dark icon when the dark PNG cannot be read. `preview-appearances.png` (from `preview-appearances.svg`) shows both
drawings at large and small sizes.
