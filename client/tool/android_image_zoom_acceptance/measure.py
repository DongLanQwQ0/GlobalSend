"""Read synthetic image marker pixels from an Android viewer screenshot."""
from pathlib import Path
from PIL import Image, ImageChops
import argparse
import json
import math

COLORS = {
    "topLeft": (235, 40, 35),
    "topRight": (12, 160, 245),
    "bottomLeft": (255, 145, 12),
    "bottomRight": (110, 35, 220),
    "focal": (244, 12, 180),
}


def measure(path):
    im = Image.open(path).convert("RGB")
    channels = im.split()
    markers = {}
    for name, rgb in COLORS.items():
        planes = [channel.point(lambda value, expected=expected: 255 if abs(value - expected) <= 5 else 0)
                  for channel, expected in zip(channels, rgb)]
        mask = ImageChops.multiply(ImageChops.multiply(planes[0], planes[1]), planes[2])
        box = mask.getbbox()
        if box is None:
            markers[name] = None
            continue
        left, top, right, bottom = box
        markers[name] = {
            "bounds": box,
            "center": [(left + right - 1) / 2, (top + bottom - 1) / 2],
            "width": right - left,
            "height": bottom - top,
            "pixels": mask.histogram()[255],
        }
    return {"file": str(Path(path).resolve()), "size": list(im.size), "markers": markers}


parser = argparse.ArgumentParser()
parser.add_argument("image")
parser.add_argument("--before")
parser.add_argument("--output")
args = parser.parse_args()
result = measure(args.image)
if args.before:
    before = measure(args.before)
    old = before["markers"]["focal"]
    new = result["markers"]["focal"]
    if old is None or new is None:
        raise SystemExit("Synthetic focal marker missing; comparison cannot pass")
    distance = math.dist(old["center"], new["center"])
    result["comparison"] = {
        "before": before["file"],
        "focalDisplacementPixels": distance,
        "focalWidthRatio": new["width"] / old["width"],
        "focalHeightRatio": new["height"] / old["height"],
    }
text = json.dumps(result, indent=2)
if args.output:
    Path(args.output).write_text(text + "\n", encoding="utf-8")
print(text)
