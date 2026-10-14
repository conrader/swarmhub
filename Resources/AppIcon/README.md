# SwarmHub brand artwork

Use the **complete four-agent logo** wherever SwarmHub is represented: the white, blue, orange and green agents together on the dark tile.

[SwarmHub-icon.svg](SwarmHub-icon.svg) is the canonical artwork. [SwarmHub-logo.svg](SwarmHub-logo.svg) and the compatibility filename `SwarmHub-icon-small.svg` contain the same complete composition. Scale the whole SVG proportionally and use `object-fit: contain` or SwiftUI's `scaledToFit()`. Preserve its viewBox and padding; avoid crops, isolated characters, initials or replacement eye marks.

Regenerate the README banners, Mac iconset, iOS app icon and iOS brand image from the repository root:

```bash
python3 scripts/sync-brand-assets.py
```

The script requires `rsvg-convert` from librsvg. It exports every size from the canonical vector, including the small icons. The iOS app icon has an opaque background; the standalone brand image retains the SVG's transparent padding. The Mac release script creates its `.icns` from `AppIcon.iconset/`.

The website's `assets/swarmhub-logo.svg`, favicon, download icon and social preview must also use this canonical artwork. Site source is managed separately; copy the canonical vector into its assets and embed the same vector in its social card before publishing.

Individual agent avatars identify those agents. The complete logo identifies SwarmHub.
