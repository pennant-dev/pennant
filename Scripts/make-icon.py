#!/usr/bin/env python3
"""Renders Pennant's app icon into both asset catalogs.

The icon is Pennant's mark: the ribbon from Sources/PennantUI/Avatars.swift (`PennantShape`, same geometry),
violet into blue, on a quiet white tile.

    python3 Scripts/make-icon.py            # writes both AppIcon.appiconsets + AccentColor.colorsets
    python3 Scripts/make-icon.py --preview /tmp/icon-preview.png   # also writes a contact sheet

Everything is drawn at 4x and downsampled with Lanczos so edges stay smooth. Requires Pillow.
"""
import argparse
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageOps

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAC_CATALOG = os.path.join(ROOT, "Apps", "PennantMac", "Assets.xcassets")
IOS_CATALOG = os.path.join(ROOT, "Apps", "PennantiOS", "Assets.xcassets")
HOST_ICNS = os.path.join(ROOT, "Sources", "PennantHost", "AppIcon.icns")

SIZE = 1024          # master canvas, points at 1x
SS = 4               # supersampling factor
LANCZOS = Image.Resampling.LANCZOS

# Palette: the app's light surfaces and ink (PennantTheme); ocean stays the system accent colour.
OCEAN = (0x2F, 0x80, 0xED)        # PennantPalette.defaultHex, used for AccentColor
VIOLET = (0x8B, 0x5C, 0xF6)       # the mark's gradient: violet ("needs you") into ocean blue
BLUE = OCEAN
ACCENT = (0x7A, 0x4F, 0xE6)       # PennantTheme.brand: the system accent (toggles, focus rings, selection)
INK = (0x12, 0x12, 0x14)          # PennantTheme.ink
TILE_TOP = (0xFF, 0xFF, 0xFF)
TILE_BOTTOM = (0xEC, 0xEE, 0xF2)

# Composition (fractions of the 1024 master)
MARK_WIDTH = 0.58                 # the pennant's unit square, as a fraction of the canvas
MARK_CENTRE_SHIFT = 0.03          # the pennant's box spans x 0.22-0.84, so nudge left to centre it

# macOS icon grid: 824 px rounded square centred on a 1024 canvas, continuous corners of radius 185.
MAC_ART = 824
MAC_MARGIN = (SIZE - MAC_ART) // 2
MAC_CORNER = 185
MAC_SHADOW = dict(offset=6, blur=10, alpha=0.26)



def cubic_points(p0, c1, c2, p3, steps):
    """Flattens one cubic Bézier into `steps` points (excluding p0)."""
    out = []
    for i in range(1, steps + 1):
        t = i / steps
        u = 1.0 - t
        a, b, c, d = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
        out.append((a * p0[0] + b * c1[0] + c * c2[0] + d * p3[0],
                    a * p0[1] + b * c1[1] + c * c2[1] + d * p3[1]))
    return out


def continuous_rounded_square(size, radius, steps=64):
    """Apple-style continuous ("squircle") rounded square as a polygon.

    Uses the three-cubic corner construction that approximates SwiftUI's `.continuous` corner style:
    the curve begins 1.5287 r from each corner and the 45° inset is within 1% of a circular corner's.
    """
    k = 1.52866483
    corner = [  # (a, b) in units of r: a along the incoming edge back from the corner, b along the outgoing edge
        ((1.08849323, 0.0), (0.86840689, 0.0), (0.63149379, 0.07491139)),
        ((0.37282383, 0.16905956), (0.16905956, 0.37282383), (0.07491139, 0.63149379)),
        ((0.0, 0.86840689), (0.0, 1.08849323), (0.0, k)),
    ]
    w = h = size
    corners = [  # clockwise, screen coordinates: (corner point, incoming edge direction, outgoing edge direction)
        ((w, 0), (1, 0), (0, 1)),
        ((w, h), (0, 1), (-1, 0)),
        ((0, h), (-1, 0), (0, -1)),
        ((0, 0), (0, -1), (1, 0)),
    ]
    poly = []
    for (cx, cy), (ux, uy), (vx, vy) in corners:
        def place(ab):
            a, b = ab[0] * radius, ab[1] * radius
            return (cx - a * ux + b * vx, cy - a * uy + b * vy)
        cur = (k, 0.0)
        poly.append(place(cur))
        for c1, c2, p3 in corner:
            poly.extend(place(p) for p in cubic_points(cur, c1, c2, p3, steps))
            cur = p3
    return poly


def ribbon_polygon(steps=240):
    """The ribbon as unit-square points: the upper edge left to right, then the lower edge back. Keep in step with
    `PennantShape.outline` in Sources/PennantUI/Avatars.swift."""
    top, bottom = [], []
    for i in range(steps + 1):
        t = i / steps
        x = 0.182 + 0.655 * t
        y = 0.5 + 0.1335 * math.sin(t * math.pi * 1.6 - 0.6)
        half = 0.1456 * (1 - t) ** 0.8 + 0.0097
        top.append((x, y - half))
        bottom.append((x, y + half))
    return top + bottom[::-1]


def render_master(ss=SS):
    """The full-bleed 1024-point artwork, rendered at `ss` x supersampling. Returns an RGB image of side 1024*ss."""
    n = SIZE * ss

    # A quiet white tile, a touch cooler at the bottom, like the app's own surfaces.
    ramp = Image.linear_gradient("L").resize((n, n), Image.Resampling.BILINEAR)
    bg = Image.composite(Image.new("RGB", (n, n), TILE_BOTTOM), Image.new("RGB", (n, n), TILE_TOP), ramp)
    art = bg.convert("RGBA")

    # The mark: the ribbon (PennantShape in Sources/PennantUI/Avatars.swift, same unit-square geometry), filled with
    # a violet-to-blue diagonal gradient.
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).polygon([(x * n, y * n) for x, y in ribbon_polygon()], fill=255)
    fill = Image.new("RGB", (2, 2))
    fill.putpixel((0, 0), VIOLET); fill.putpixel((1, 1), BLUE)
    fill.putpixel((1, 0), tuple((a + b) // 2 for a, b in zip(VIOLET, BLUE))); fill.putpixel((0, 1), fill.getpixel((1, 0)))
    fill = fill.resize((n, n), Image.Resampling.BILINEAR).convert("RGBA")
    mark = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    mark.paste(fill, (0, 0), mask)
    art.alpha_composite(mark)
    return art.convert("RGB")


def render_mac(master_ss, ss=SS):
    """macOS variant: master scaled onto the 824 grid, continuous-corner mask, soft shadow, transparent margin."""
    n = SIZE * ss
    art_n = MAC_ART * ss
    margin = MAC_MARGIN * ss
    art = master_ss.resize((art_n, art_n), LANCZOS).convert("RGBA")
    mask = Image.new("L", (art_n, art_n), 0)
    ImageDraw.Draw(mask).polygon(continuous_rounded_square(art_n, MAC_CORNER * ss), fill=255)
    art.putalpha(mask)

    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    shadow_mask = Image.new("L", (n, n), 0)
    shadow_mask.paste(mask, (margin, margin + MAC_SHADOW["offset"] * ss))
    shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(MAC_SHADOW["blur"] * ss))
    shadow_mask = shadow_mask.point(lambda v: int(v * MAC_SHADOW["alpha"]))
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 255))
    shadow.putalpha(shadow_mask)
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(art, (margin, margin))
    return canvas


def downsample(img, size):
    return img.resize((size, size), LANCZOS)


def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


CATALOG_INFO = {"author": "xcode", "version": 1}


def accent_colorset(catalog):
    d = os.path.join(catalog, "AccentColor.colorset")
    os.makedirs(d, exist_ok=True)
    components = {"alpha": "1.000", "red": "0x%02X" % ACCENT[0], "green": "0x%02X" % ACCENT[1], "blue": "0x%02X" % ACCENT[2]}
    color = {"color-space": "srgb", "components": components}
    write_json(os.path.join(d, "Contents.json"), {
        "colors": [
            {"color": color, "idiom": "universal"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}], "color": color, "idiom": "universal"},
        ],
        "info": CATALOG_INFO,
    })


def write_mac_catalog(mac_ss):
    os.makedirs(MAC_CATALOG, exist_ok=True)
    write_json(os.path.join(MAC_CATALOG, "Contents.json"), {"info": CATALOG_INFO})
    d = os.path.join(MAC_CATALOG, "AppIcon.appiconset")
    os.makedirs(d, exist_ok=True)
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = "icon_%dx%d%s.png" % (pt, pt, "@2x" if scale == 2 else "")
            downsample(mac_ss, px).save(os.path.join(d, name), optimize=True)
            images.append({"filename": name, "idiom": "mac", "scale": "%dx" % scale, "size": "%dx%d" % (pt, pt)})
    write_json(os.path.join(d, "Contents.json"), {"images": images, "info": CATALOG_INFO})
    accent_colorset(MAC_CATALOG)


def write_ios_catalog(master_ss):
    os.makedirs(IOS_CATALOG, exist_ok=True)
    write_json(os.path.join(IOS_CATALOG, "Contents.json"), {"info": CATALOG_INFO})
    d = os.path.join(IOS_CATALOG, "AppIcon.appiconset")
    os.makedirs(d, exist_ok=True)
    name = "AppIcon-1024.png"
    downsample(master_ss, 1024).convert("RGB").save(os.path.join(d, name), optimize=True)
    write_json(os.path.join(d, "Contents.json"), {
        "images": [{"filename": name, "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": CATALOG_INFO,
    })
    accent_colorset(IOS_CATALOG)


def write_preview(path, master_ss, mac_ss):
    """A contact sheet: master, mac 1024, and the small mac sizes blown up with nearest-neighbour."""
    sheet = Image.new("RGBA", (1024 * 2 + 3 * 32, 1024 + 256 + 3 * 32), (0xEE, 0xEE, 0xEE, 255))
    sheet.alpha_composite(downsample(master_ss, 1024).convert("RGBA"), (32, 32))
    sheet.alpha_composite(downsample(mac_ss, 1024), (1024 + 64, 32))
    x = 32
    for s in (256, 128, 64, 32, 16):
        small = downsample(mac_ss, s).resize((256, 256), Image.Resampling.NEAREST)
        sheet.alpha_composite(small, (x, 1024 + 64))
        x += 256 + 32
    sheet.convert("RGB").save(path)


def write_host_icns():
    """The embedded Pennant Host helper shows in System Settings › Privacy; give it the same icon as an .icns."""
    import shutil
    import subprocess
    import tempfile
    src = os.path.join(MAC_CATALOG, "AppIcon.appiconset")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for name in os.listdir(src):
            if name.endswith(".png"):
                shutil.copy(os.path.join(src, name), os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", HOST_ICNS], check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--preview", metavar="PNG", help="also write a contact sheet to this path")
    ap.add_argument("--master", metavar="PNG", help="also write the 1024 full-bleed master to this path")
    args = ap.parse_args()

    master_ss = render_master()
    mac_ss = render_mac(master_ss)
    write_mac_catalog(mac_ss)
    write_ios_catalog(master_ss)
    write_host_icns()
    if args.master:
        downsample(master_ss, 1024).save(args.master)
    if args.preview:
        write_preview(args.preview, master_ss, mac_ss)
    print("wrote", os.path.relpath(MAC_CATALOG, ROOT), "and", os.path.relpath(IOS_CATALOG, ROOT))


if __name__ == "__main__":
    sys.exit(main())
