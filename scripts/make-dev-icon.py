#!/usr/bin/env python3
"""Generate the AppIconDev icon set from the production AppIcon master images.

Overlays a diagonal "DEV" ribbon on the bottom-right corner so the development
build (bundle id de.cwitzl.slurmapp.dev, display name "Slurmy Dev") is instantly
distinguishable from the stable "Slurmy" in the Dock / Launchpad.

Run from the repo root:   python3 scripts/make-dev-icon.py
Idempotent: rewrites SlurmApp/Resources/Assets.xcassets/AppIconDev.appiconset.
"""
import json
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "SlurmApp/Resources/Assets.xcassets")
SRC = os.path.join(ASSETS, "AppIcon.appiconset")
DST = os.path.join(ASSETS, "AppIconDev.appiconset")

FONT_PATH = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
RIBBON_COLOR = (255, 122, 0, 240)   # warm orange — "this is a dev build"
TEXT_COLOR = (255, 255, 255, 255)

# (output filename, pixel size, master to derive from)
MAC = "icon-mac-1024.png"
IOS = "icon-ios-1024.png"
OUTPUTS = [
    ("icon-mac-16.png", 16, MAC),
    ("icon-mac-32.png", 32, MAC),
    ("icon-mac-64.png", 64, MAC),
    ("icon-mac-128.png", 128, MAC),
    ("icon-mac-256.png", 256, MAC),
    ("icon-mac-512.png", 512, MAC),
    ("icon-mac-1024.png", 1024, MAC),
    ("icon-ios-1024.png", 1024, IOS),
]


def add_ribbon(img):
    """Composite a diagonal DEV ribbon across the bottom-right corner."""
    img = img.convert("RGBA")
    S = img.width

    band_w = int(S * 1.25)
    band_h = int(S * 0.17)
    band = Image.new("RGBA", (band_w, band_h), (0, 0, 0, 0))
    d = ImageDraw.Draw(band)
    d.rectangle([0, 0, band_w, band_h], fill=RIBBON_COLOR)

    font = ImageFont.truetype(FONT_PATH, int(band_h * 0.60))
    text = "DEV"
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    tw, th = r - l, b - t
    # track-out the letters a touch for a stenciled, badge-like look
    d.text(((band_w - tw) / 2 - l, (band_h - th) / 2 - t),
           text, font=font, fill=TEXT_COLOR)

    band = band.rotate(45, expand=True, resample=Image.BICUBIC)

    # Center the rotated strip near the bottom-right corner so it crosses it.
    cx, cy = int(S * 0.80), int(S * 0.80)
    img.alpha_composite(band, (cx - band.width // 2, cy - band.height // 2))
    return img


def main():
    os.makedirs(DST, exist_ok=True)

    # Build badged 1024 masters once, downscale from them with LANCZOS.
    masters = {}
    for m in (MAC, IOS):
        src = Image.open(os.path.join(SRC, m)).convert("RGBA")
        if src.width != 1024:
            src = src.resize((1024, 1024), Image.LANCZOS)
        masters[m] = add_ribbon(src)

    for name, size, master in OUTPUTS:
        out = masters[master]
        if size != out.width:
            out = out.resize((size, size), Image.LANCZOS)
        out.save(os.path.join(DST, name))
        print(f"  wrote {name} ({size}x{size})")

    # Mirror the production Contents.json verbatim (same filenames).
    with open(os.path.join(SRC, "Contents.json")) as f:
        contents = json.load(f)
    with open(os.path.join(DST, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")
    print(f"Done → {os.path.relpath(DST, ROOT)}")


if __name__ == "__main__":
    main()
