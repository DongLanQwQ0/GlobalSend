from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import json

root = Path(__file__).resolve().parents[3]
dest = root / "artifacts" / "fixtures" / "android-image-zoom"
dest.mkdir(parents=True, exist_ok=True)
font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 30)
result = {}
for name, size, focal in [
    ("landscape", (1600, 1000), (600, 400)),
    ("portrait", (1000, 1600), (350, 650)),
]:
    width, height = size
    im = Image.new("RGB", size, (240, 244, 248))
    draw = ImageDraw.Draw(im)
    for x in range(0, width, 100):
        draw.line((x, 0, x, height), fill=(185, 196, 208), width=2)
    for y in range(0, height, 100):
        draw.line((0, y, width, y), fill=(185, 196, 208), width=2)
    markers = {
        "topLeft": ((40, 40), (235, 40, 35)),
        "topRight": ((width - 40, 40), (12, 160, 245)),
        "bottomLeft": ((40, height - 40), (255, 145, 12)),
        "bottomRight": ((width - 40, height - 40), (110, 35, 220)),
        "focal": (focal, (244, 12, 180)),
    }
    for marker, ((x, y), rgb) in markers.items():
        draw.rectangle((x - 20, y - 20, x + 20, y + 20), fill=rgb)
        tx = min(width - 230, max(5, x + 28))
        ty = min(height - 40, max(5, y + 25))
        draw.text((tx, ty), marker, font=font, fill=(20, 35, 55))
    draw.text((width // 2 - 170, height // 2 + 80), "GLOBALSEND ZOOM TEST", font=font, fill=(20, 35, 55))
    path = dest / f"GlobalSend-zoom-{name}.png"
    im.save(path, optimize=True)
    review = im.copy()
    review.thumbnail((720, 720))
    review.save(dest / f"GlobalSend-zoom-{name}-review.jpg", quality=78, optimize=True)
    result[name] = {"path": str(path), "size": size, "markers": markers}
(dest / "fixtures.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
print(json.dumps({name: value["path"] for name, value in result.items()}))
