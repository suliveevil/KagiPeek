#!/usr/bin/env python3
"""Generate the Kaname macOS 27 app icon and every artefact derived from it.

Composition: one symmetrical Reuleaux triangle -- the constant-width curve
of three circular arcs, the shape that can rotate like a wheel -- fills the
icon. The Command mark is a cut-out near the rotor's visual centre: no keycap,
no socket, no second layer. The rotor turning around a modifier key is the
"kaname" (扇の要).

A rounded-square keycap used to frame the mark. It read as a key at 1024px
but made the icon busy, and a bare brass mark on cream loses all contrast at
Dock size. A single-layer cut-out is both simpler and the only variant that
survives 32px and the clear/tinted appearances.

The .icon layer is transparent 1024x1024 artwork only: no corner mask, no
gradient background, no baked highlights or shadows. macOS 27 / Icon Composer
supplies all of those.

This file lives in scripts/ (tracked) and is the SINGLE source of truth for
the icon geometry. Everything else is generated from it:

    python3 scripts/generate_icon.py          # run from anywhere

  deliverables/kaname-icon/  local previews, editable SVGs, a .icon copy
                             (working papers, ignored by git)
  KagiPeek/Kaname.icon/      the package both build paths compile (tracked)
  KagiPeek/Assets.xcassets/MenuBarIcon.imageset/*.png (tracked)

Keeping the generator out of deliverables/ matters: that directory is ignored,
so a generator living there only exists on one machine and a fresh checkout
can silently grow a second, divergent copy. app icon, flat previews and the
menu bar template all call the same command_mark(), so the shared offset
cannot drift again.

Requires rsvg-convert (librsvg). With Xcode present it also compiles the
.icon through actool and expands Kaname.icns for the system-rendered
previews; without Xcode it warns and still produces every tracked artefact.
"""

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DELIVER = REPO / "deliverables" / "kaname-icon"
PROJECT_ICON = REPO / "KagiPeek" / "Kaname.icon"
CATALOG = REPO / "KagiPeek" / "Assets.xcassets"
MENUBAR_CATALOG = CATALOG / "MenuBarIcon.imageset"
SRC = DELIVER / "source"
PREVIEW = DELIVER / "preview"
MENUBAR = DELIVER / "menubar"
ICON = DELIVER / "Kaname.icon"
ASSETS = ICON / "Assets"

if shutil.which("rsvg-convert") is None:
    raise SystemExit("error: rsvg-convert not found (brew install librsvg)")
if not MENUBAR_CATALOG.is_dir():
    raise SystemExit(f"error: menu bar catalog missing: {MENUBAR_CATALOG}")

for d in (SRC, PREVIEW, MENUBAR, ASSETS):
    d.mkdir(parents=True, exist_ok=True)

# Clear only artefacts this script generated in earlier revisions.
for p in list(PREVIEW.glob("*.png")) + list(SRC.glob("*.svg")):
    p.unlink()

CREAM = "#F3EFE6"
MONO = "#39404C"
MONO_BG = "#C9CDD6"
BG = "#122326"
BG_SRGB = "srgb:0.07059,0.13725,0.14902,1.00000"

HEAD = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
        'width="1024" height="1024">')
TAIL = "</svg>"

# --- Reuleaux triangle -------------------------------------------------------
# Equilateral triangle, apex down. Each arc is centred on the opposite vertex
# with radius = side length, which makes the curve constant-width: it keeps
# the same bounding circle at every rotation angle, so it can roll/turn.
SIDE = 820.0
CX, CY = 512.0, 450.0                    # centroid = the axle
HALF = SIDE / 2
RISE = SIDE / (2 * (3 ** 0.5))
DROP = SIDE / (3 ** 0.5)
A = (CX - HALF, CY - RISE)               # top-left corner
B = (CX + HALF, CY - RISE)               # top-right corner
C = (CX, CY + DROP)                      # bottom corner


def reuleaux_path():
    a = f"{A[0]:.1f} {A[1]:.1f}"
    b = f"{B[0]:.1f} {B[1]:.1f}"
    c = f"{C[0]:.1f} {C[1]:.1f}"
    r = f"{SIDE:.0f} {SIDE:.0f}"
    return f"M{a} A{r} 0 0 1 {b} A{r} 0 0 1 {c} A{r} 0 0 1 {a} Z"


REULEAUX = reuleaux_path()

# A bare mark has to be bigger than one trapped inside a keycap.
MARK = 400.0
MS = MARK / 200.0

# SINGLE source of truth for the mark's vertical placement. Both the app icon
# (keys_layer) and the menu bar template (menubar_doc) call command_mark(),
# so neither can drift from the other again.
#
# CY is the triangle's geometric centroid -- the literal axle of a rotating
# constant-width rotor. But an apex-down Reuleaux triangle has its bounding
# box centred around y=513, not 450. At CY the mark leaves 223px above and
# 349px below; +60 gives 283 / 289, i.e. visually centred. The trade-off is
# that the mark is no longer on the mathematical axle: "the rotor turns
# around the key" becomes a metaphor rather than a literal geometry.
MARK_OFFSET_Y = 60.0
MARK_CY = CY + MARK_OFFSET_Y


def command_mark(fill, holes=False):
    """The four-leaf Command clover, as a mask shape (no keycap around it)."""
    def X(v):
        return f"{CX + v * MS:.1f}"

    def Y(v):
        return f"{MARK_CY + v * MS:.1f}"

    def N(v):
        return f"{v * MS:.1f}"

    out = "".join(
        f'<rect x="{X(dx - 24)}" y="{Y(dy - 24)}" width="{N(48)}" '
        f'height="{N(48)}" rx="{N(16)}" fill="{fill}"/>'
        for dx, dy in ((-38, -38), (38, -38), (-38, 38), (38, 38))
    )
    out += (
        f'<g fill="none" stroke="{fill}" stroke-width="{N(18)}" '
        'stroke-linecap="round">'
        f'<path d="M{X(-12)} {Y(-12)} L{X(-26)} {Y(-26)}"/>'
        f'<path d="M{X(12)} {Y(-12)} L{X(26)} {Y(-26)}"/>'
        f'<path d="M{X(-12)} {Y(12)} L{X(-26)} {Y(26)}"/>'
        f'<path d="M{X(12)} {Y(12)} L{X(26)} {Y(26)}"/>'
        '</g>'
    )
    out += (f'<rect x="{X(-20)}" y="{Y(-20)}" width="{N(40)}" '
            f'height="{N(40)}" rx="{N(6)}" fill="{fill}"/>')
    if holes:
        # Small counter-bores keep the four leaves reading as loops at 1024px.
        out += "".join(
            f'<circle cx="{X(dx)}" cy="{Y(dy)}" r="{N(10)}" fill="#000000"/>'
            for dx, dy in ((-38, -38), (38, -38), (-38, 38), (38, 38))
        )
    return out


def keys_layer(color):
    defs = (
        '<mask id="rotormask" maskUnits="userSpaceOnUse" '
        'x="0" y="0" width="1024" height="1024">'
        f'<path d="{REULEAUX}" fill="#ffffff"/>'
        + command_mark("#000000") +
        '</mask>'
    )
    body = f'<rect width="1024" height="1024" fill="{color}" mask="url(#rotormask)"/>'
    return defs, body


def doc(defs, body):
    return HEAD + ("<defs>" + defs + "</defs>" if defs else "") + body + TAIL


def preview_doc(rotor_color, background):
    kdefs, kbody = keys_layer(rotor_color)
    defs = (
        '<clipPath id="squircle"><rect width="1024" height="1024" rx="228"/></clipPath>'
        + kdefs
    )
    body = ('<g clip-path="url(#squircle)"><rect width="1024" height="1024" '
            f'fill="{background}"/></g>' + kbody)
    return doc(defs, body)


def write(path, text):
    path.write_text(text, encoding="utf-8")


def render(src, size, dst):
    subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), str(src), "-o", str(dst)],
        check=True,
    )


# --- editable vector source --------------------------------------------------
write(SRC / "rotor.svg", doc(*keys_layer(CREAM)))

# --- the .icon package -------------------------------------------------------
render(SRC / "rotor.svg", 1024, ASSETS / "rotor.png")

icon_json = {
    "fill-specializations": [
        {"value": {"solid": BG_SRGB}},
        {"appearance": "dark", "value": "automatic"},
    ],
    "groups": [
        {
            "layers": [
                {"name": "Reuleaux rotor", "glass": True, "fill": "none",
                 "image-name": "rotor.png"}
            ],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.18},
        },
    ],
    "supported-platforms": {"squares": ["macOS"]},
}
write(ICON / "icon.json", json.dumps(icon_json, indent=2, ensure_ascii=False) + "\n")
# Earlier revisions shipped other layer names; keep the package clean.
for stale in ("command-key.png", "keys.png", "pin.png", "triangle.png", "funnel.png"):
    old = ASSETS / stale
    if old.exists():
        old.unlink()

# Both build paths read the project-side copy; keep it byte-identical to the
# working package instead of maintaining two hand-edited .icon bundles.
if PROJECT_ICON.exists():
    shutil.rmtree(PROJECT_ICON)
shutil.copytree(ICON, PROJECT_ICON)

# --- flat previews -----------------------------------------------------------
write(SRC / "preview.svg", preview_doc(CREAM, BG))
for size in (1024, 256, 128, 32):
    render(SRC / "preview.svg", size, PREVIEW / f"Kaname-{size}.png")

write(SRC / "preview-mono.svg", preview_doc(MONO, MONO_BG))
for size in (1024, 128, 32):
    render(SRC / "preview-mono.svg", size, PREVIEW / f"Kaname-mono-{size}.png")

# --- menu bar template -------------------------------------------------------
# Black + alpha only; the system tints it for light and dark menu bars. Built
# from the same REULEAUX path, the same axle, and the same Command mark, so a
# change to the rotor can never leave the menu bar behind. With no keycap there
# is no socket ring either: the mark is simply a transparent cut-out.
MB_BOX = 900.0
MB_SCALE = MB_BOX / SIDE
MB_CENTRE_Y = CY + (DROP - RISE) / 2        # centre of the rotor's bounding box


def menubar_doc():
    transform = (f"translate(512 512) scale({MB_SCALE:.6f}) "
                 f"translate(-512 -{MB_CENTRE_Y:.1f})")
    mask = (
        '<mask id="mbmask" maskUnits="userSpaceOnUse" '
        'x="0" y="0" width="1024" height="1024">'
        f'<g transform="{transform}">'
        f'<path d="{REULEAUX}" fill="#ffffff"/>'
        + command_mark("#000000") +
        '</g></mask>'
    )
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
        'width="18" height="18">'
        + mask +
        '<rect width="1024" height="1024" fill="#000000" mask="url(#mbmask)"/>'
        '</svg>'
    )


write(SRC / "menubar.svg", menubar_doc())
render(SRC / "menubar.svg", 18, MENUBAR / "menubar.png")
render(SRC / "menubar.svg", 36, MENUBAR / "menubar@2x.png")
render(SRC / "menubar.svg", 360, PREVIEW / "Kaname-menubar-360.png")

# NSImage(named: "MenuBarIcon") loads from the catalog, so the template has
# to live there too -- not only in the working-paper directory.
for name in ("menubar.png", "menubar@2x.png"):
    shutil.copy2(MENUBAR / name, MENUBAR_CATALOG / name)


def system_previews():
    """Regenerate the real macOS renderings instead of leaving them stale.

    The preview sweep above deletes every PNG in preview/, including the two
    actool outputs. Compiling here means one command rebuilds ALL artefacts.
    Xcode is optional: a warning is printed, never a silent missing preview.
    """
    if shutil.which("xcrun") is None or shutil.which("iconutil") is None:
        print("warning: Xcode tools unavailable; no system-rendered previews")
        return
    tmp = Path(tempfile.mkdtemp(prefix="kagipeek-icon-"))
    try:
        out = tmp / "compiled"
        out.mkdir()
        run = subprocess.run(
            ["xcrun", "actool", "--compile", str(out),
             "--platform", "macosx", "--minimum-deployment-target", "14.0",
             "--app-icon", "Kaname", str(ICON), str(CATALOG),
             "--output-partial-info-plist", str(tmp / "partial.plist")],
            capture_output=True, text=True,
        )
        if run.returncode != 0 or not (out / "Kaname.icns").exists():
            reason = (run.stderr or run.stdout).strip().splitlines()
            print("warning: actool failed; no system-rendered previews:",
                  reason[-1] if reason else "unknown error")
            return
        iconset = tmp / "render.iconset"
        run = subprocess.run(
            ["iconutil", "-c", "iconset", str(out / "Kaname.icns"),
             "-o", str(iconset)],
            capture_output=True, text=True,
        )
        if run.returncode != 0:
            reason = (run.stderr or run.stdout).strip().splitlines()
            print("warning: iconutil failed; no system-rendered previews:",
                  reason[-1] if reason else "unknown error")
            return
        shutil.copy2(iconset / "icon_128x128@2x.png",
                     PREVIEW / "Kaname-system-256.png")
        shutil.copy2(iconset / "icon_16x16@2x.png",
                     PREVIEW / "Kaname-system-32.png")
        print("system previews: actool + iconutil OK")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


system_previews()

print("built:", ICON)
print("project icon:", PROJECT_ICON)
print("reuleaux side:", SIDE, "centre:", (CX, CY), "mark:", MARK)
print("layers:", ", ".join(p.name for p in sorted(ASSETS.glob("*.png"))))
print("previews:", ", ".join(p.name for p in sorted(PREVIEW.glob("*.png"))))
