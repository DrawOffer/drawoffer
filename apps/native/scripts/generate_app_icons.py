"""Package the existing Web mark on a warm-white application icon plate.

Run from repo root:
    uv run --directory apps/backend python ../native/scripts/generate_app_icons.py
No logo redesign or new dependency; Pillow is already a backend dependency.
"""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "apps/web/src/assets/drawoffer-mark.png"
MAC_PNG = ROOT / "apps/mac/Sources/DrawOfferApp/Resources/AppIcon.png"
MAC_ICNS = ROOT / "apps/mac/Resources/DrawOffer.icns"
WINDOWS_ICO = ROOT / "apps/windows/src/DrawOffer.App/Assets/DrawOffer.ico"
ELECTRON_PNG = ROOT / "apps/desktop/build/icon.png"

for target in [MAC_PNG, MAC_ICNS, WINDOWS_ICO, ELECTRON_PNG]:
    target.parent.mkdir(parents=True, exist_ok=True)
with Image.open(SOURCE) as raw:
    if raw.width != raw.height:
        raise ValueError("Application mark must be square")
    # Classic ICNS/ICO need a baked-in plate. Only its exterior is transparent.
    # 源图可能带透明留白，图标按裁掉留白后的内容放大到 1024，避免图标里的标记过小。
    size = 1024
    content = raw.convert("RGBA").crop(raw.getbbox())
    source = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    longest = max(content.size)
    fitted = int(size * 0.78)
    content = content.resize((fitted * content.width // longest, fitted * content.height // longest), Image.Resampling.LANCZOS)
    source.alpha_composite(content, ((size - content.width) // 2, (size - content.height) // 2))
    scale = 4
    mask = Image.new("L", (size * scale, size * scale))
    ImageDraw.Draw(mask).rounded_rectangle(
        (size * scale * 0.06, size * scale * 0.06,
         size * scale * 0.94 - 1, size * scale * 0.94 - 1),
        radius=size * scale * 0.19, fill=255,
    )
    icon = Image.new("RGBA", (size, size), "#F7F5F0")
    icon.putalpha(mask.resize((size, size), Image.Resampling.LANCZOS))
    icon.alpha_composite(source)
    icon.save(MAC_PNG)
    icon.save(ELECTRON_PNG)
    icon.save(MAC_ICNS, format="ICNS")
    icon.save(WINDOWS_ICO, format="ICO", sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
print("Updated Mac ICNS/runtime PNG, Windows ICO and Electron PNG: warm white #F7F5F0")
