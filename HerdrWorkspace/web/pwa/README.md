These PWA icons are RGB PNG sizes of [the existing iOS SwarmHub icon](../../../Apps/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon.png), with no alterations to the mark or native application. The opaque cream background and centered mark are suitable for launcher masks. To regenerate them from `HerdrWorkspace` with Pillow:

```sh
python3 - <<'PY'
from PIL import Image
source = Image.open('../Apps/iOS/Resources/Assets.xcassets/AppIcon.appiconset/Icon.png').convert('RGB')
for size in (180, 192, 512):
    source.resize((size, size), Image.LANCZOS).save(f'web/pwa/icon-{size}.png', optimize=True)
PY
```
