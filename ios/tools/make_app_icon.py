#!/usr/bin/env python3
"""Generate the Anixart iOS app icon (1024x1024, opaque PNG).

Style: dark background (#0E0F13 family), orange accent (#FA5C33),
a geometric "A" monogram whose counter is a clean triangle. Pure vector
math + Pillow, supersampled 4x, no noise/texture.

Run with the bundled DSH python (has Pillow):
  python tools/make_app_icon.py
"""

import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4                      # supersampling factor for the mark
BIG = SIZE * SS

ACCENT = np.array([250, 92, 51], dtype=np.float32)      # #FA5C33
ACCENT_TOP = np.array([255, 130, 88], dtype=np.float32)   # lit top edge
ACCENT_BOT = np.array([214, 55, 22], dtype=np.float32)    # shaded bottom

BG_CENTER = np.array([20, 22, 30], dtype=np.float32)    # slightly lifted centre
BG_EDGE = np.array([9, 10, 13], dtype=np.float32)       # corners

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Anixart", "Resources", "Assets.xcassets",
    "AppIcon.appiconset", "icon-1024.png",
)

# --- mark geometry in 1024 space -------------------------------------------
# outer triangle of the "A"
APEX = (512.0, 194.0)
BASE_Y = 830.0
LEFT_X = 238.0
RIGHT_X = 786.0
# inner edges converge at INNER_APEX, leaving a solid tip
INNER_APEX_Y = 300.0
LEG_IN_L = 358.0        # inner edge of the left leg at the baseline
LEG_IN_R = 666.0        # inner edge of the right leg at the baseline
BAR_TOP = 596.0         # crossbar top edge
BAR_BOT = 696.0         # crossbar bottom edge


def _x_on_inner(side: str, y: float) -> float:
    """x of the inner leg edge at a given y."""
    t = (BASE_Y - y) / (BASE_Y - INNER_APEX_Y)
    if side == "l":
        return LEG_IN_L + (512.0 - LEG_IN_L) * t
    return LEG_IN_R + (512.0 - LEG_IN_R) * t


def background() -> np.ndarray:
    """Smooth radial gradient + warm glow + vignette. Returns float32 HxWx3."""
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    cx, cy = 0.5 * SIZE, 0.40 * SIZE

    # radial falloff to the corners
    d = np.sqrt(((xx - cx) / (0.80 * SIZE)) ** 2 + ((yy - cy) / (0.80 * SIZE)) ** 2)
    t = np.clip(d, 0.0, 1.0)
    t = t * t * (3.0 - 2.0 * t)                 # smoothstep
    bg = BG_CENTER[None, None, :] + (BG_EDGE - BG_CENTER)[None, None, :] * t[..., None]

    # warm halo behind the mark (kept tight so the base stays dark)
    gx, gy = 0.5 * SIZE, 0.55 * SIZE
    g = np.exp(-((((xx - gx) / (0.28 * SIZE)) ** 2 +
                  ((yy - gy) / (0.28 * SIZE)) ** 2)))
    bg = bg + ACCENT[None, None, :] * (0.13 * g)[..., None]

    # gentle vignette
    vd = np.sqrt(((xx - 0.5 * SIZE) / (0.72 * SIZE)) ** 2 +
                 ((yy - 0.5 * SIZE) / (0.72 * SIZE)) ** 2)
    vig = 1.0 - 0.26 * np.clip(vd, 0.0, 1.0) ** 2
    return bg * vig[..., None]


def mark_mask() -> np.ndarray:
    """Anti-aliased 0..1 mask of the 'A' at SIZE, from a 4x drawing."""
    m = Image.new("L", (BIG, BIG), 0)
    d = ImageDraw.Draw(m)

    def sc(pts):
        return [(x * SS, y * SS) for x, y in pts]

    # solid outer triangle
    d.polygon(sc([APEX, (RIGHT_X, BASE_Y), (LEFT_X, BASE_Y)]), fill=255)
    # notch between the legs, below the crossbar
    d.polygon(sc([(LEG_IN_L, BASE_Y), (LEG_IN_R, BASE_Y),
                  (_x_on_inner("r", BAR_BOT), BAR_BOT),
                  (_x_on_inner("l", BAR_BOT), BAR_BOT)]), fill=0)
    # counter above the crossbar
    d.polygon(sc([(_x_on_inner("l", BAR_TOP), BAR_TOP),
                  (_x_on_inner("r", BAR_TOP), BAR_TOP),
                  (512.0, INNER_APEX_Y)]), fill=0)

    # uniform corner rounding: blur then re-threshold
    r = 9.0 * SS
    m = m.filter(ImageFilter.GaussianBlur(r))
    m = m.point(lambda v: 255 if v >= 128 else 0)

    return np.asarray(
        m.resize((SIZE, SIZE), Image.Resampling.LANCZOS), dtype=np.float32
    ) / 255.0


def main() -> None:
    bg = background()

    mask = mark_mask()

    # soft drop shadow under the mark so it lifts off the background
    shadow = Image.fromarray((mask * 255).astype(np.uint8)).filter(
        ImageFilter.GaussianBlur(30)
    )
    sh = np.asarray(shadow, dtype=np.float32) / 255.0
    sh = np.roll(sh, 12, axis=0) * 0.50
    bg = bg * (1.0 - sh[..., None])

    # diagonal gradient across the mark: lit at the top-left, deeper at the base
    ys = np.linspace(0.0, 1.0, SIZE, dtype=np.float32)[:, None]
    xs = np.linspace(0.0, 1.0, SIZE, dtype=np.float32)[None, :]
    f = 0.62 * ys + 0.38 * xs                     # 0 top-left .. 1 bottom-right
    f = np.clip((f - f.min()) / (f.max() - f.min()), 0.0, 1.0)
    grad = (ACCENT_TOP[None, None, :] * (1.0 - f[..., None]) +
            ACCENT_BOT[None, None, :] * f[..., None])
    # keep the overall hue anchored on the brand orange
    grad = grad * 0.45 + ACCENT[None, None, :] * 0.55

    m3 = mask[..., None]
    out = bg * (1.0 - m3) + grad * m3

    out = np.clip(out, 0, 255).astype(np.uint8)
    img = Image.fromarray(out, mode="RGB")                # no alpha channel
    img.save(OUT, "PNG", optimize=True)

    # sanity report
    probe = Image.open(OUT)
    print("path      :", OUT)
    print("size      :", probe.size)
    print("mode      :", probe.mode)
    print("bytes     :", os.path.getsize(OUT))
    print("corner px :", img.getpixel((0, 0)))
    print("centre px :", img.getpixel((512, 512)))


if __name__ == "__main__":
    main()
