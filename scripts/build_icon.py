#!/usr/bin/env python3
"""Generate 128x128 Works launcher icon (app/assets/icon.jpg) for ESP-Mosaico."""
from pathlib import Path
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parents[1] / "app" / "assets" / "icon.jpg"
OUT.parent.mkdir(parents=True, exist_ok=True)

im = Image.new("RGB", (128, 128), (36, 104, 180))
d = ImageDraw.Draw(im)

# Ocean & islands
d.ellipse((14, 18, 70, 68), fill=(104, 204, 214))
d.ellipse((20, 22, 64, 62), fill=(238, 220, 164))
d.ellipse((24, 26, 60, 56), fill=(96, 178, 52))
d.ellipse((32, 32, 52, 48), fill=(146, 140, 134))

d.ellipse((74, 72, 120, 114), fill=(104, 204, 214))
d.ellipse((78, 76, 114, 108), fill=(238, 220, 164))
d.ellipse((83, 81, 108, 102), fill=(70, 158, 64))

# Wingtip vapor trails
d.line((20, 104, 46, 78), fill=(214, 232, 250), width=2)
d.line((54, 118, 78, 92), fill=(214, 232, 250), width=2)

# Afterburner flame
d.polygon([(46, 86), (34, 98), (42, 96)], fill=(255, 164, 44))
d.polygon([(52, 92), (40, 104), (48, 99)], fill=(255, 224, 120))

# Pixel fighter jet silhouette (diagonal top-right)
d.polygon([(92, 36), (62, 74), (54, 66)], fill=(240, 88, 14))
d.polygon([(88, 40), (42, 62), (56, 70), (66, 84)], fill=(84, 89, 105))
d.polygon([(88, 40), (58, 68), (64, 74)], fill=(196, 201, 211))
# Canopy
d.polygon([(78, 50), (68, 58), (72, 62)], fill=(30, 140, 160))

im.save(OUT, format="JPEG", quality=92)
print(f"Generated {OUT} ({OUT.stat().st_size} bytes)")
