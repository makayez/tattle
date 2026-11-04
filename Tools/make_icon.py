#!/usr/bin/env python3
"""Render the Tattle Turtle addon icon.

No third-party dependencies on purpose: this repo's only other tooling is Lua,
and an icon that needs Pillow installed is an icon nobody can regenerate.

Outputs, all drawn from the same scene function so they can never disagree:

  TattleTurtle.tga        128x128 32-bit, the in-game icon (## IconTexture)
  TattleTurtle.png        128x128  the same picture, for the README and anything else
  Tools/tattle-turtle-512.png  512x512  the CurseForge project icon upload
  Tools/tattle-turtle-32.png    32x32   a readability check at tab-list size

Usage:  python3 Tools/make_icon.py
"""

import math
import os
import struct
import zlib

D = 128.0          # everything below is laid out in a 128x128 design grid


# ---------------------------------------------------------------------------
# Geometry primitives. Read the return convention before using one:
#
#   in_ellipse / in_circle  -> normalised distance, <= 1.0 means inside
#   in_round_rect           -> SIGNED distance in units, > 0 means inside
#   in_poly                 -> bool
#
# A bare `> 0` on the first kind is always a bug: it is true for almost every
# point on the canvas.
# ---------------------------------------------------------------------------

def in_ellipse(px, py, cx, cy, rx, ry, deg=0.0):
    if deg:
        a = math.radians(deg)
        dx, dy = px - cx, py - cy
        px = cx + dx * math.cos(a) - dy * math.sin(a)
        py = cy + dx * math.sin(a) + dy * math.cos(a)
    dx = (px - cx) / rx
    dy = (py - cy) / ry
    return dx * dx + dy * dy


def in_circle(px, py, cx, cy, r):
    dx, dy = px - cx, py - cy
    return (dx * dx + dy * dy) / (r * r)


def disc(px, py, cx, cy, r):
    return in_circle(px, py, cx, cy, r) <= 1.0


def in_round_rect(px, py, x0, y0, x1, y1, r):
    cx = min(max(px, x0 + r), x1 - r)
    cy = min(max(py, y0 + r), y1 - r)
    return r - math.hypot(px - cx, py - cy)


def in_poly(px, py, verts):
    inside = False
    n = len(verts)
    for i in range(n):
        x0, y0 = verts[i]
        x1, y1 = verts[(i + 1) % n]
        if (y0 > py) != (y1 > py):
            xt = x0 + (py - y0) * (x1 - x0) / (y1 - y0)
            if px < xt:
                inside = not inside
    return inside


def covers_any(px, py, shapes):
    for shape in shapes:
        if in_ellipse(px, py, *shape) <= 1.0:
            return True
    return False


def fills(px, py, test, eps=1.5):
    """True when the point and its four neighbours are all inside `test`.

    Used to draw one continuous ink line around a union of shapes: comparing
    per-shape rims would leave seams where two ellipses overlap.
    """
    return all(test(qx, qy) for qx, qy in (
        (px - eps, py), (px + eps, py), (px, py - eps), (px, py + eps)))


SQRT3 = math.sqrt(3.0)


def hex_cell(px, py, size, rot_deg=0.0, sx=1.0):
    """Pointy-top hexagon lattice cell, optionally rotated and stretched.

    The stretch is what makes the carapace read as a row of big central scutes
    with smaller flank plates instead of a uniform honeycomb.
    """
    if rot_deg:
        a = math.radians(rot_deg)
        dx, dy = px, py
        px = dx * math.cos(a) - dy * math.sin(a)
        py = dx * math.sin(a) + dy * math.cos(a)
    q = (SQRT3 / 3.0 * px - 1.0 / 3.0 * py) / (size * sx)
    r = (2.0 / 3.0 * py) / size
    x, z = q, r
    y = -x - z
    rx, ry, rz = round(x), round(y), round(z)
    dx, dy, dz = abs(rx - x), abs(ry - y), abs(rz - z)
    if dx > dy and dx > dz:
        rx = -ry - rz
    elif dy > dz:
        ry = -rx - rz
    else:
        rz = -rx - ry
    return rx, rz


# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------

def mix(c1, c2, t):
    if t <= 0.0:
        return c1
    if t >= 1.0:
        return c2
    return (c1[0] + (c2[0] - c1[0]) * t,
            c1[1] + (c2[1] - c1[1]) * t,
            c1[2] + (c2[2] - c1[2]) * t)


def smooth(edge0, edge1, x):
    if edge0 == edge1:
        return 0.0 if x < edge0 else 1.0
    t = (x - edge0) / (edge1 - edge0)
    t = 0.0 if t < 0 else (1.0 if t > 1 else t)
    return t * t * (3 - 2 * t)


def vgrad(y, top, bottom, y0=0.0, y1=D):
    return mix(top, bottom, smooth(y0, y1, y))


# ---------------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------------

BG_TOP = (32.0, 52.0, 62.0)
BG_BOT = (9.0, 16.0, 24.0)
GLOW = (48.0, 78.0, 82.0)
BG_EDGE = (92.0, 122.0, 128.0)

SHELL_TOP = (140.0, 192.0, 98.0)
SHELL_BOT = (50.0, 94.0, 56.0)
SHELL_RIM = (24.0, 46.0, 32.0)          # the ink line around the carapace
SCUTE_SEAM = (34.0, 62.0, 40.0)
SHELL_SHEEN = (226.0, 240.0, 196.0)
PLASTRON = (216.0, 202.0, 148.0)        # the pale belly plate showing at the rim

SKIN_TOP = (166.0, 208.0, 130.0)
SKIN_BOT = (98.0, 146.0, 84.0)
SKIN_RIM = (34.0, 62.0, 40.0)           # the ink line around the body
TOE = (74.0, 116.0, 66.0)
BLUSH = (232.0, 146.0, 132.0)
NOSTRIL_C = (44.0, 74.0, 46.0)

EYE_WHITE = (252.0, 252.0, 250.0)
EYE_DARK = (26.0, 26.0, 32.0)
MOUTH = (60.0, 30.0, 36.0)

BUBBLE = (248.0, 242.0, 222.0)
BUBBLE_EDGE = (36.0, 40.0, 50.0)
ALERT = (178.0, 58.0, 58.0)


# ---------------------------------------------------------------------------
# Layout. Turtle faces left, mid-tattle; the shell is a scalloped dome, the head
# carries a beak, and every body part shares one ink outline.
# ---------------------------------------------------------------------------

BG_R, BG_PAD = 22.0, 1.0

SHELL_C = (72.0, 74.0)
SHELL_RX, SHELL_RY = 36.0, 31.0
SCALLOP_N, SCALLOP_AMP = 9, 0.055       # the marginal rim's shallow bumps

HEAD = (29.0, 54.0, 17.0, 14.5, -12.0)
SNOUT = (15.5, 60.5, 9.0, 7.5, -25.0)
NECK = (45.0, 64.0, 15.0, 11.0, -12.0)
FOOT_FRONT = (50.0, 109.0, 12.0, 8.5, -6.0)
FOOT_REAR = (95.0, 109.0, 12.0, 8.5, 6.0)
TAIL = (112.0, 91.0, 8.5, 4.8, 28.0)
SHADOW = (72.0, 119.0, 47.0, 7.0)

SKIN = (HEAD, SNOUT, NECK, FOOT_FRONT, FOOT_REAR, TAIL)

EYE = (22.0, 49.0, 5.4)                 # white
EYE_RING = 4.5                          # inner radius of the eye's ink ring
PUPIL = (20.2, 50.0, 3.1)
GLINT = (18.6, 48.2, 1.35)
MOUTH_E = (9.5, 63.5, 3.8, 2.5, -32.0)
NOSTRIL_P = (9.5, 56.5, 1.1)
# The cheek has to stay clear of the carapace rim, which reaches x~40 at this
# height; a blush drawn under the shell is simply never seen.
BLUSH_E = (28.0, 59.0, 4.6)

# Toe seams: short vertical dark lines at the front edge of each foot.
TOES = ((41.0, 45.0, 104.0, 117.0), (86.0, 90.0, 104.0, 117.0))

SCUTE_SIZE, SCUTE_ROT, SCUTE_STRETCH = 21.0, 18.0, 1.45

# The bubble sits above the head and its tail aims at the head: a tail that
# lands on the turtle's back says the shell is doing the talking.
BUB = (12.0, 6.0, 62.0, 36.0, 8.0)
# The tip stops on the head's crown (~y 40 at x 24). A longer tail reaches the
# eye at (22,49) r 5.4 and paints over it - the reason this is short.
BUB_TAIL = ((26.0, 32.0), (42.0, 32.0), (24.0, 40.0))
BANG_BAR = (34.0, 12.0, 40.0, 27.0, 3.0)
BANG_DOT = (37.0, 32.0, 2.9)


def shell_f(px, py):
    """Normalised distance into the carapace; 1.0 is the scalloped rim."""
    u = (px - SHELL_C[0]) / SHELL_RX
    v = (py - SHELL_C[1]) / SHELL_RY
    r = math.hypot(u, v)
    if r == 0.0:
        return 0.0
    boundary = 1.0 + SCALLOP_AMP * math.cos(SCALLOP_N * math.atan2(v, u))
    return r / boundary


def in_shell(px, py):
    return shell_f(px, py) <= 1.0


def in_skin(px, py):
    return covers_any(px, py, SKIN)


def scute_seam(px, py, eps=1.5):
    cx, cy = SHELL_C
    dx, dy = px - cx, py - cy
    c = hex_cell(dx, dy, SCUTE_SIZE, SCUTE_ROT, SCUTE_STRETCH)
    return (hex_cell(dx + eps, dy, SCUTE_SIZE, SCUTE_ROT, SCUTE_STRETCH) != c
            or hex_cell(dx, dy + eps, SCUTE_SIZE, SCUTE_ROT, SCUTE_STRETCH) != c)


def scute_tint(px, py):
    """One brightness factor per scute so the plates are not all identical."""
    cx, cy = SHELL_C
    q, r = hex_cell(px - cx, py - cy, SCUTE_SIZE, SCUTE_ROT, SCUTE_STRETCH)
    return (1.00, 0.92, 1.08)[(q * 7 + r * 13) % 3]


def toe_seam(px, py):
    for x0, x1, y0, y1 in TOES:
        if y0 <= py <= y1 and (abs(px - x0) < 0.8 or abs(px - x1) < 0.8):
            return True
    return False


def shade(px, py):
    """Front-to-back: the first shape covering the point wins."""

    # --- speech bubble ----------------------------------------------------
    d = in_round_rect(px, py, BUB[0], BUB[1], BUB[2], BUB[3], BUB[4])
    if d > 0:
        if d < 2.2:
            return (*BUBBLE_EDGE, 255)
        if (in_round_rect(px, py, *BANG_BAR) > 0
                or disc(px, py, BANG_DOT[0], BANG_DOT[1], BANG_DOT[2])):
            return (*ALERT, 255)
        return (*BUBBLE, 255)
    if in_poly(px, py, BUB_TAIL):
        return (*(BUBBLE if fills(px, py, lambda qx, qy: in_poly(qx, qy, BUB_TAIL), 1.4)
                  else BUBBLE_EDGE), 255)

    # --- carapace: scalloped rim, scutes, plastron, sheen -----------------
    if in_shell(px, py):
        f = shell_f(px, py)
        c = vgrad(py, SHELL_TOP, SHELL_BOT, 42.0, 106.0)
        c = tuple(ch * scute_tint(px, py) for ch in c)
        if scute_seam(px, py) and f < 0.86:
            c = mix(c, SCUTE_SEAM, 0.85)
        # Pale plastron showing along the lower rim.
        v = (py - SHELL_C[1]) / SHELL_RY
        if v > 0.52 and f > 0.60:
            c = mix(c, PLASTRON, smooth(0.52, 0.95, v) * smooth(0.60, 0.80, f) * 0.85)
        sheen = 1.0 - smooth(0.0, 1.0, in_ellipse(px, py, 58.0, 54.0, 19.0, 10.0))
        if sheen > 0.0:
            c = mix(c, SHELL_SHEEN, sheen * 0.28)
        if f > 1.0 - 0.12:                      # ink line around the dome
            c = mix(c, SHELL_RIM, smooth(1.0 - 0.12, 1.0, f))
        return (*c, 255)

    # --- body: head, beak, neck, feet, tail, all one ink outline ----------
    if in_skin(px, py):
        # Features first, so the outline logic never paints over them.
        if disc(px, py, EYE[0], EYE[1], EYE[2]):
            ring = in_circle(px, py, EYE[0], EYE[1], EYE[2])
            if ring >= (EYE_RING / EYE[2]) ** 2:
                return (*EYE_DARK, 255)         # the eye's own ink ring
            if disc(px, py, PUPIL[0], PUPIL[1], PUPIL[2]):
                if disc(px, py, GLINT[0], GLINT[1], GLINT[2]):
                    return (*EYE_WHITE, 255)
                return (*EYE_DARK, 255)
            return (*EYE_WHITE, 255)
        if in_ellipse(px, py, *MOUTH_E) <= 1.0:
            return (*MOUTH, 255)
        if disc(px, py, *NOSTRIL_P):
            return (*NOSTRIL_C, 255)
        if toe_seam(px, py):
            return (*TOE, 255)

        c = vgrad(py, SKIN_TOP, SKIN_BOT, 40.0, 116.0)
        if disc(px, py, *BLUSH_E):
            c = mix(c, BLUSH, 0.32)
        if not fills(px, py, in_skin, 1.8):
            c = mix(c, SKIN_RIM, 0.92)          # shared silhouette line
        return (*c, 255)

    # --- ground shadow ----------------------------------------------------
    if in_ellipse(px, py, *SHADOW) <= 1.0:
        base = vgrad(py, BG_TOP, BG_BOT)
        return (*tuple(ch * 0.55 for ch in base), 255)

    # --- plaque -----------------------------------------------------------
    d = in_round_rect(px, py, BG_PAD, BG_PAD, D - BG_PAD, D - BG_PAD, BG_R)
    if d > 0:
        c = vgrad(py, BG_TOP, BG_BOT)
        g = 1.0 - smooth(0.0, 1.0, in_circle(px, py, 66.0, 72.0, 62.0))
        if g > 0.0:
            c = mix(c, GLOW, g * 0.55)
        if d < 2.6:
            c = mix(c, BG_EDGE, 1.0 - smooth(0.0, 2.6, d))
        return (*c, 255)

    return (0.0, 0.0, 0.0, 0)


# ---------------------------------------------------------------------------
# Renderer and writers
# ---------------------------------------------------------------------------

def render(out_size, supersample):
    n = out_size * supersample
    scale = n / D
    rows = []
    for oy in range(out_size):
        row = []
        base_y = oy * supersample
        for ox in range(out_size):
            base_x = ox * supersample
            r = g = b = a = 0.0
            for sy in range(supersample):
                py = (base_y + sy + 0.5) / scale
                for sx in range(supersample):
                    px = (base_x + sx + 0.5) / scale
                    cr, cg, cb, ca = shade(px, py)
                    r += cr
                    g += cg
                    b += cb
                    a += ca
            k = supersample * supersample
            row.append((int(r / k + 0.5), int(g / k + 0.5),
                        int(b / k + 0.5), int(a / k + 0.5)))
        rows.append(row)
    return rows


def write_png(path, rows):
    h = len(rows)
    w = len(rows[0])
    raw = bytearray()
    for row in rows:
        raw.append(0)                      # filter type 0 (none)
        for r, g, b, a in row:
            raw += bytes((r, g, b, a))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))


def write_tga(path, rows):
    """32-bit uncompressed TGA, bottom-left origin: what WoW's own tools emit."""
    h = len(rows)
    w = len(rows[0])
    header = struct.pack("<BBBHHBHHHHBB",   # exactly 18 bytes
                         0,                 # id_length: no image ID field
                         0,                 # colormap_type: none
                         2,                 # image_type: uncompressed true-colour
                         0,                 # colormap_first_index
                         0,                 # colormap_length
                         0,                 # colormap_depth
                         0, 0,              # x_origin, y_origin
                         w, h,
                         32,                # pixel_depth
                         0x08)              # bottom-left origin, 8 alpha bits
    buf = bytearray(header)
    for row in reversed(rows):             # bottom-up
        for r, g, b, a in row:
            buf += bytes((b, g, r, a))     # TGA is B,G,R,A
    with open(path, "wb") as f:
        f.write(buf)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)

    icon = render(128, 4)
    write_tga(os.path.join(root, "TattleTurtle.tga"), icon)
    write_png(os.path.join(root, "TattleTurtle.png"), icon)
    write_png(os.path.join(here, "tattle-turtle-512.png"), render(512, 2))
    write_png(os.path.join(here, "tattle-turtle-32.png"), render(32, 8))
    print("wrote TattleTurtle.tga, TattleTurtle.png, "
          "Tools/tattle-turtle-512.png, Tools/tattle-turtle-32.png")


if __name__ == "__main__":
    main()
