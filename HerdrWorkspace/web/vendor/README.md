# Bundled browser assets

The terminal viewer bundles these files locally so it works without a CDN or a network connection:

- [`@xterm/xterm` 5.5.0](https://www.npmjs.com/package/@xterm/xterm/v/5.5.0): `lib/xterm.js` and `css/xterm.css`, under [its MIT license](xterm-LICENSE).
- [`@xterm/addon-fit` 0.10.0](https://www.npmjs.com/package/@xterm/addon-fit/v/0.10.0): `lib/addon-fit.js`, under [its MIT license](addon-fit-LICENSE).

The JavaScript copies omit the trailing source map URL. The published archives are the source for these files; update the copies and the corresponding licenses together.

The file viewer bundles [Mozilla PDF.js 6.5.438](https://github.com/mozilla/pdf.js/releases/tag/v6.5.438) from `pdfjs-dist@6.5.438`. The `pdfjs/` directory contains the legacy minified display, parser, and renderer modules, along with CMaps, standard fonts, color profiles, and the image decoders they use. It omits the standalone viewer and scripting sandbox. The [Apache 2.0 license](pdfjs/LICENSE) and the licenses for the resources are included next to the copies. Rust embeds those assets at build time; no CDN or Node installation is needed to run the viewer.

Use `npm pack pdfjs-dist@6.5.438 --ignore-scripts` to obtain the upstream package. Its SHA-512 integrity is `sha512-vg8Pw1x+AFKy4AMDvhuWl5cOYV8d698UoEANoFFhc79hqXDnZQqnOXoxw3HG907WHOg1JYOvLhP756boddFxpA==`. Keep the three modules and their supporting assets at the same version when updating.

The desktop viewer embeds the browser module from [noVNC 1.6.0](https://github.com/novnc/noVNC/tree/v1.6.0), under [its licenses and notices](novnc/LICENSE.txt). Its core is under the [Mozilla Public License 2.0](novnc/LICENSE.MPL-2.0); bundled dependencies retain their separate terms in `novnc/`. The [upstream source archive](https://codeload.github.com/novnc/noVNC/tar.gz/refs/tags/v1.6.0) has SHA-256 `5066103959ef4e9b10f37e5a148627360dd8414e4cf8a7db92bdbd022e728aaa`. From its extraction directory (containing `noVNC-1.6.0`), run esbuild 0.25.12 with `esbuild noVNC-1.6.0/core/rfb.js --bundle --format=esm --target=chrome90,firefox90,safari15 --outfile=novnc.js`. No upstream source files are modified. The resulting bundle has SHA-256 `7c22c71c1dbe9166b66e60fd243e3917200a7cd83926dd18ec58cf3d0691a600`.
