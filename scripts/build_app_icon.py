"""Draw the app icon. Board #108.

**The PNGs in `ios/MonitorFinance/Assets.xcassets/AppIcon.appiconset/` are
GENERATED — run this, never edit them by hand.** Same rule as
`reference.json` and the Privat fixtures: a binary nobody can regenerate is a
binary nobody can change.

The mark is «Потік» — three currents running past each other. Each is a ribbon
along a cubic bezier whose width is a *function of t*, swelling where the
stream turns and thinning at both ends, because a constant-width stroke does
not read as moving water.

Colours are the app's own, read off `Theme.swift` rather than invented:

    bg    light (0.968, 0.961, 0.945) -> #F7F5F1
    green light (0.204, 0.545, 0.443) -> #348B71
    green dark  (0.325, 0.769, 0.635) -> #53C4A2

**Three variants, and their backgrounds are NOT the same rule.** This is the
part that is easy to get wrong, and was got wrong here first:

- **light** — opaque, the app's own warm off-white.
- **dark** — **transparent**. The system draws the background itself.
- **tinted** — **opaque greyscale on BLACK**, not transparent. The system reads
  the image's luminance and composites its own gradient through it, so a
  transparent tinted variant loses the shape the tint is supposed to follow.

Because tinted throws the hue away entirely, the mark has to read by shape and
luminance alone. That is why this design is one colour with no tonal layering:
anything leaning on the green is a grey smudge in tinted mode.

Run:  uv run python scripts/build_app_icon.py
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw

#: Rendered at SS times the final size and downsampled, because PIL has no
#: antialiased polygon fill and an icon with stair-stepped edges is worse than
#: no icon.
SIZE = 1024
SS = 3
S = SIZE * SS

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ios/MonitorFinance/Assets.xcassets/AppIcon.appiconset"

BG_LIGHT = (247, 245, 241, 255)
GREEN_LIGHT = (52, 139, 113, 255)
GREEN_DARK = (83, 196, 162, 255)
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)
BLACK = (0, 0, 0, 255)

#: The three streams, as fractions of the canvas. Their vertical centres are
#: evenly spaced and the outer two are inset from the edges by the same amount,
#: so the mark stays centred inside iOS's squircle mask.
STREAM_YS = (0.28, 0.50, 0.72)


def _bezier(points, t):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = points
    u = 1 - t
    return (
        u**3 * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t**3 * x3,
        u**3 * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t**3 * y3,
    )


def _tangent(points, t):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = points
    u = 1 - t
    return (
        3 * u * u * (x1 - x0) + 6 * u * t * (x2 - x1) + 3 * t * t * (x3 - x2),
        3 * u * u * (y1 - y0) + 6 * u * t * (y2 - y1) + 3 * t * t * (y3 - y2),
    )


def _swell(ends: float, middle: float, power: float = 0.55):
    """Width as a function of t: thin at both ends, fattest in the middle.

    An earlier draft interpolated only between a start and an end width, which
    meant a ribbon with equal ends never swelled at all and rendered as a
    hairline. Width has to be a function of position, not of its endpoints.
    """
    return lambda t: ends + (middle - ends) * (math.sin(math.pi * t) ** power)


def _ribbon(draw, points, width, colour, steps: int = 260) -> None:
    left, right = [], []
    for i in range(steps + 1):
        t = i / steps
        x, y = _bezier(points, t)
        dx, dy = _tangent(points, t)
        length = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / length, dx / length
        half = width(t) / 2
        left.append((x + nx * half, y + ny * half))
        right.append((x - nx * half, y - ny * half))
    draw.polygon(left + right[::-1], fill=colour)
    # Round caps. Without them the ribbon ends in a flat chord across the
    # normal, which reads as a cut-off pipe rather than as water.
    for t in (0.0, 1.0):
        cx, cy = _bezier(points, t)
        radius = width(t) / 2
        draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=colour)


def draw_icon(background, foreground) -> Image.Image:
    image = Image.new("RGBA", (S, S), background)
    draw = ImageDraw.Draw(image)
    for y in STREAM_YS:
        _ribbon(
            draw,
            [
                (0.10 * S, (y + 0.055) * S),
                (0.36 * S, (y - 0.10) * S),
                (0.64 * S, (y + 0.10) * S),
                (0.90 * S, (y - 0.055) * S),
            ],
            _swell(0.075 * S, 0.145 * S),
            foreground,
        )
    return image.resize((SIZE, SIZE), Image.LANCZOS)


VARIANTS = {
    "icon-light.png": (BG_LIGHT, GREEN_LIGHT),
    # Transparent: iOS draws the dark background behind this one.
    "icon-dark.png": (CLEAR, GREEN_DARK),
    # OPAQUE greyscale on black, NOT transparent — the system tints the
    # luminance and needs a filled image to tint through.
    "icon-tinted.png": (BLACK, WHITE),
}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (background, foreground) in VARIANTS.items():
        draw_icon(background, foreground).save(OUT / name)
        print(f"wrote {(OUT / name).relative_to(ROOT)}")


if __name__ == "__main__":
    main()
