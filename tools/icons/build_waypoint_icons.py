#!/usr/bin/env python3
"""Render the waypoint icons as MapLibre SDF sprites.

Glyphs come out of the Material Icons font the Flutter SDK already bundles, so
the map markers and the Dart `IconData` constants stay the same artwork. The
app registers each PNG with `addImage(..., sdf: true)` and tints it through a
data-driven `icon-color`, which only works if the alpha channel is a real
distance field rather than a plain antialiased mask.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
OUTPUT_DIR = REPOSITORY_ROOT / "app" / "assets" / "waypoint_icons"
PREVIEW_PATH = REPOSITORY_ROOT / ".artifacts" / "waypoint_icons_preview.png"

FALLBACK_FONT = Path(
    r"C:\_stuff\dev\tools\flutter\bin\cache\artifacts\material_fonts"
    r"\materialicons-regular.otf"
)
FONT_RELATIVE_TO_FLUTTER_ROOT = Path(
    "bin/cache/artifacts/material_fonts/materialicons-regular.otf"
)

SIZE = 64
# TinySDF's convention, which is what MapLibre's SDF shader is written against:
# a spread of 8 px either side of the edge and a 0.25 cutoff, so the edge lands
# at alpha 191 and the shader's 0.75 threshold reproduces the original outline.
RADIUS = 8
CUTOFF = 0.25
EDGE_ALPHA = 191
# The distance transform runs on a 4x mask because an exact EDT over a 64 px
# binary mask quantises the field to whole pixels, which shows up as stair
# steps along diagonal strokes once the shader antialiases against it.
SUPERSAMPLE = 4
# Ink fills 80% of the canvas: enough margin left for the 8 px spread plus the
# halo the map style draws outside it.
INK_FRACTION = 0.8
# Stands in for infinity in the distance transform. Parabola intersections are
# a difference of two of these, and a true inf yields NaN, which silently
# breaks the hull walk.
FAR = 1e20

# Codepoints are Flutter's own, copied from icons.dart, so that a Dart test can
# assert each one against the `IconData.codePoint` the app renders in lists.
#
# Keys are WaypointIcon ids, and they are also the PNG filenames the app loads,
# so renaming one changes the glyph on every waypoint already saved under it.
ICONS = {
    # 'other' rather than 'pin': the id predates the icon being a picture
    # instead of a category, and it is written into saved waypoint files.
    "other": 0xE4C9,
    "viewpoint": 0xE365,
    "camp": 0xE11D,
    "tent": 0xE263,
    "firepit": 0xE463,
    "water": 0xF05A2,
    "cache": 0xE34A,
    "foraging": 0xE217,
    "stand": 0xE14E,
    "blind": 0xE42C,
    "camera": 0xE4B6,
    "sign": 0xE4A1,
    "blood": 0xE0E3,
    "harvest": 0xE28E,
    "food": 0xE2E4,
    "fishing": 0xF0548,
    "dock": 0xE084,
    "boat-launch": 0xE1D3,
    "parking": 0xE39D,
    "trailhead": 0xE313,
    "signpost": 0xF0569,
    "ford": 0xE6D0,
    "hazard": 0xE6CB,
    # Glyphs for lines. A line needs no icon on the map, but a list row, a card
    # and a filter chip all draw one -- and a point can be given any of these
    # glyphs, so every one of them has to exist as an image: MapLibre draws
    # nothing at all, and says nothing, when icon-image does not resolve.
    "trail": 0xF0561,
    "route": 0xE080,
    "road": 0xE1D7,
    "portage": 0xE350,
    "boundary": 0xE262,
}

# Glyphs that are not waypoint icons. Kept apart from ICONS because a Dart test
# asserts that map one-to-one onto WaypointIcon, and an extra in there would
# read as an icon the app had forgotten to define.
EXTRAS = {
    # Direction markers repeated along a track. Every one points right, because
    # MapLibre's `symbol-placement: line` aligns a symbol's horizontal axis with
    # the direction the line's coordinates run.
    #
    # A solid triangle, an open chevron and a double chevron rather than three
    # variations on one shape: they have to be told apart at around 10 dp, where
    # ink weight and how many strokes there are is about all that survives.
    "track-arrow": 0xE4CB,
    "track-chevron": 0xE15F,
    "track-chevron-double": 0xE1FF,
}

# Shapes drawn *under* a waypoint glyph rather than as one.
#
# Kept apart from ICONS and EXTRAS because these are measured as well as
# rendered, and because they are the one place a glyph is not drawn as the font
# has it: Material's pin is a teardrop with a circular counter punched out of
# its head, and a transparent hole is exactly where the glyph has to read. The
# counter is filled below, which is a deterministic close of the same Material
# outline rather than new artwork -- Material Icons has no solid pin.
#
# The measurements written to the manifest are load-bearing, not documentation.
# A pin's point marks the coordinate where a centred glyph only approximates
# it, so the app has to know where in the image the point and the head sit or
# switching the setting moves every waypoint on screen.
BACKDROPS = {
    # Icons.place, the same glyph WaypointIcon.pin draws as.
    "pin-backdrop": 0xE4C9,
}


def resolve_font(explicit: str | None) -> Path:
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise FileNotFoundError(f"--font is not a file: {path}")
        return path
    if FALLBACK_FONT.is_file():
        return FALLBACK_FONT
    flutter = shutil.which("flutter")
    if flutter:
        # flutter on PATH is <root>/bin/flutter[.bat]; the font ships two
        # levels down from the same root.
        derived = Path(flutter).resolve().parents[1] / FONT_RELATIVE_TO_FLUTTER_ROOT
        if derived.is_file():
            return derived
    raise FileNotFoundError(
        "Could not find materialicons-regular.otf.\n"
        f"  Looked at: {FALLBACK_FONT}\n"
        "  And beside 'flutter' on PATH, at "
        f"<flutter root>/{FONT_RELATIVE_TO_FLUTTER_ROOT.as_posix()}\n"
        "  Pass --font <path to materialicons-regular.otf> to override."
    )


def draw_glyph(font_path: Path, codepoint: int, font_size: int) -> Image.Image:
    font = ImageFont.truetype(str(font_path), font_size)
    char = chr(codepoint)
    left, top, right, bottom = font.getbbox(char)
    pad = 8
    image = Image.new("L", (right - left + 2 * pad, bottom - top + 2 * pad), 0)
    ImageDraw.Draw(image).text((pad - left, pad - top), char, fill=255, font=font)
    return image


def render_mask(font_path: Path, key: str, codepoint: int) -> np.ndarray:
    canvas = SIZE * SUPERSAMPLE
    wanted = round(canvas * INK_FRACTION)
    font_size = wanted
    glyph = None
    for _ in range(8):
        image = draw_glyph(font_path, codepoint, font_size)
        box = image.getbbox()
        if box is None:
            raise ValueError(
                f"{key}: U+{codepoint:04X} rendered no ink from {font_path.name}. "
                "The font may not carry that glyph."
            )
        glyph = image.crop(box)
        extent = max(glyph.width, glyph.height)
        if abs(extent - wanted) <= 1:
            break
        scaled = max(1, round(font_size * wanted / extent))
        if scaled == font_size:
            break
        font_size = scaled
    assert glyph is not None

    if glyph.width > canvas or glyph.height > canvas:
        raise ValueError(
            f"{key}: glyph is {glyph.width}x{glyph.height} at {canvas}px canvas"
        )
    placed = Image.new("L", (canvas, canvas), 0)
    placed.paste(glyph, ((canvas - glyph.width) // 2, (canvas - glyph.height) // 2))
    mask = np.asarray(placed, dtype=np.uint8) >= 128
    if not mask.any():
        raise ValueError(f"{key}: mask is empty after thresholding at 128")
    return mask


def enclosed_holes(mask: np.ndarray) -> np.ndarray:
    """Empty pixels the outside cannot reach, i.e. the glyph's counters."""
    empty = ~mask
    reached = np.zeros_like(empty)
    height, width = mask.shape
    stack: list[tuple[int, int]] = []

    def seed(y: int, x: int) -> None:
        if empty[y, x] and not reached[y, x]:
            reached[y, x] = True
            stack.append((y, x))

    for x in range(width):
        seed(0, x)
        seed(height - 1, x)
    for y in range(height):
        seed(y, 0)
        seed(y, width - 1)
    while stack:
        y, x = stack.pop()
        if y > 0:
            seed(y - 1, x)
        if y < height - 1:
            seed(y + 1, x)
        if x > 0:
            seed(y, x - 1)
        if x < width - 1:
            seed(y, x + 1)
    return empty & ~reached


def measure_backdrop(key: str, mask: np.ndarray, holes: np.ndarray) -> dict:
    """Where the pin's point and its head sit, in units of the 64 px canvas.

    Coordinates are continuous rather than pixel indices, and they name the
    boundary of the mask, because that is where `distance_field` puts the zero
    crossing: the edge below the last ink row is at row index + 1.
    """
    rows = np.flatnonzero(mask.any(axis=1))
    hole_rows = np.flatnonzero(holes.any(axis=1))
    hole_cols = np.flatnonzero(holes.any(axis=0))

    # The counter is concentric with the head, so its centre is the head's.
    # Asserted rather than assumed: if a font release moves it off the axis,
    # the glyph would be placed off-centre in the pin and nothing else here
    # would notice.
    centre_x = (hole_cols[0] + hole_cols[-1] + 1) / 2 / SUPERSAMPLE
    if abs(centre_x - SIZE / 2) > 0.5:
        raise ValueError(
            f"{key}: counter centred at x={centre_x:.2f}, not {SIZE / 2}. "
            "The head is not on the glyph's vertical axis."
        )
    head_centre_y = (hole_rows[0] + hole_rows[-1] + 1) / 2 / SUPERSAMPLE

    # The head lobe's outer width, read across the head's own centre line so a
    # tapering body cannot be mistaken for it.
    head_row = min(int(round(head_centre_y * SUPERSAMPLE)), mask.shape[0] - 1)
    head_cols = np.flatnonzero(mask[head_row])
    return {
        "tip_y": (rows[-1] + 1) / SUPERSAMPLE,
        "head_centre_y": head_centre_y,
        "head_diameter": (head_cols[-1] + 1 - head_cols[0]) / SUPERSAMPLE,
    }


def squared_edt_1d(f: np.ndarray) -> np.ndarray:
    """Felzenszwalb & Huttenlocher's exact 1D squared distance transform."""
    n = f.shape[0]
    v = np.zeros(n, dtype=np.int64)
    z = np.empty(n + 1, dtype=np.float64)
    d = np.empty(n, dtype=np.float64)

    k = 0
    z[0] = -FAR
    z[1] = FAR
    for q in range(1, n):
        s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0 * (q - v[k]))
        # k has to stay non-negative: equal parabolas put the intersection left
        # of every one already on the hull, and walking past index 0 reads the
        # sentinel as a real vertex and corrupts the rest of the row.
        while k > 0 and s <= z[k]:
            k -= 1
            s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0 * (q - v[k]))
        k += 1
        v[k] = q
        z[k] = s
        z[k + 1] = FAR

    k = 0
    for q in range(n):
        while z[k + 1] < q:
            k += 1
        d[q] = (q - v[k]) ** 2 + f[v[k]]
    return d


def squared_edt(seeds: np.ndarray) -> np.ndarray:
    f = np.where(seeds, 0.0, FAR)
    for axis in (1, 0):
        f = np.apply_along_axis(squared_edt_1d, axis, f)
    return f


def distance_field(mask: np.ndarray) -> np.ndarray:
    outside = np.sqrt(squared_edt(mask))
    inside = np.sqrt(squared_edt(~mask))
    # Both are centre-to-centre distances, so the two pixels straddling an edge
    # read +1 and -1 and the edge itself would never be zero. The half-pixel
    # shift puts the zero crossing between them, where the outline is.
    signed = np.where(mask, -(inside - 0.5), outside - 0.5) / SUPERSAMPLE
    return signed.reshape(SIZE, SUPERSAMPLE, SIZE, SUPERSAMPLE).mean(axis=(1, 3))


def encode_alpha(distance: np.ndarray) -> np.ndarray:
    return np.clip(
        np.round(255.0 - 255.0 * (distance / RADIUS + CUTOFF)), 0, 255
    ).astype(np.uint8)


def ring_peak(alpha: np.ndarray) -> int:
    """Highest alpha in the outermost 2 px, where ink would mean a clipped SDF."""
    return int(
        max(
            alpha[:2].max(),
            alpha[-2:].max(),
            alpha[:, :2].max(),
            alpha[:, -2:].max(),
        )
    )


def write_icon(alpha: np.ndarray, path: Path) -> None:
    white = np.full((SIZE, SIZE), 255, dtype=np.uint8)
    # MapLibre samples only the alpha channel of an SDF image and takes the
    # colour from icon-color, so the RGB content is arbitrary; white keeps the
    # PNG readable if anyone opens it.
    rgba = np.dstack([white, white, white, alpha])
    Image.fromarray(rgba, "RGBA").save(path, optimize=True)


def label_font() -> ImageFont.ImageFont:
    try:
        return ImageFont.load_default(size=14)
    except TypeError:
        return ImageFont.load_default()


def write_preview(alphas: dict[str, np.ndarray], path: Path) -> None:
    """Contact sheet of every icon thresholded where MapLibre puts the edge."""
    scale = 2
    tile = SIZE * scale
    label_band = 18
    pad = 10
    columns = 5
    rows = (len(alphas) + columns - 1) // columns
    sheet = Image.new(
        "RGB",
        (
            columns * (tile + pad) + pad,
            rows * (tile + label_band + pad) + pad,
        ),
        (255, 255, 255),
    )
    draw = ImageDraw.Draw(sheet)
    font = label_font()

    for index, (key, alpha) in enumerate(alphas.items()):
        column, row = index % columns, index // columns
        x = pad + column * (tile + pad)
        y = pad + row * (tile + label_band + pad)
        ink = np.where(alpha >= EDGE_ALPHA, 0, 255).astype(np.uint8)
        shape = Image.fromarray(ink, "L").convert("RGB")
        sheet.paste(shape.resize((tile, tile), Image.NEAREST), (x, y))
        # The border is the 64 px canvas edge, so a clipped glyph is obvious.
        draw.rectangle([x, y, x + tile - 1, y + tile - 1], outline=(200, 200, 200))
        draw.text((x + tile // 2, y + tile + 3), key, fill=(0, 0, 0), font=font, anchor="ma")

    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)


def write_manifest(path: Path, backdrops: dict[str, dict]) -> None:
    manifest = {
        "note": (
            "Generated by tools/icons/build_waypoint_icons.py. "
            "Do not edit by hand."
        ),
        "source": (
            "Material Icons, Apache License 2.0, as bundled with the Flutter SDK"
        ),
        "size": SIZE,
        "radius": RADIUS,
        "cutoff": CUTOFF,
        "ink_fraction": INK_FRACTION,
        "icons": dict(ICONS),
        "extras": dict(EXTRAS),
        "backdrops": backdrops,
    }
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--font", help="Path to materialicons-regular.otf")
    args = parser.parse_args()

    font_path = resolve_font(args.font)

    # The shader compares against 0.75 of full alpha, so an on-edge sample has
    # to encode to 191 or every glyph comes out fattened or eroded.
    assert int(encode_alpha(np.zeros(1))[0]) == EDGE_ALPHA
    print(f"edge alpha at d=0 is {EDGE_ALPHA}: ok")
    print(f"font: {font_path}")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    alphas: dict[str, np.ndarray] = {}
    for key, codepoint in {**ICONS, **EXTRAS}.items():
        mask = render_mask(font_path, key, codepoint)
        alpha = encode_alpha(distance_field(mask))
        peak = ring_peak(alpha)
        assert peak < 255, f"{key}: ink reaches the 2px border (alpha {peak})"
        alphas[key] = alpha

        path = OUTPUT_DIR / f"{key}.png"
        write_icon(alpha, path)
        solid = int((alpha >= EDGE_ALPHA).sum())
        assert solid > 0, f"{key}: nothing survives the {EDGE_ALPHA} threshold"
        print(
            f"  {key:<10} U+{codepoint:04X}  ink {mask.sum():>6} px  "
            f"inside-edge {solid:>4} px  border peak {peak:>3}  "
            f"{path.stat().st_size:>5} bytes"
        )

    backdrops: dict[str, dict] = {}
    for key, codepoint in BACKDROPS.items():
        mask = render_mask(font_path, key, codepoint)
        holes = enclosed_holes(mask)
        if not holes.any():
            raise ValueError(
                f"{key}: U+{codepoint:04X} has no counter to fill or measure. "
                "A backdrop is measured from its counter, so a glyph that is "
                "already solid needs its head located some other way."
            )
        measurement = measure_backdrop(key, mask, holes)
        filled = mask | holes
        alpha = encode_alpha(distance_field(filled))
        peak = ring_peak(alpha)
        assert peak < 255, f"{key}: ink reaches the 2px border (alpha {peak})"
        alphas[key] = alpha

        path = OUTPUT_DIR / f"{key}.png"
        write_icon(alpha, path)
        backdrops[key] = {
            "codepoint": codepoint,
            "holes_filled": True,
            **{name: round(value, 4) for name, value in measurement.items()},
        }
        print(
            f"  {key:<14} U+{codepoint:04X}  ink {mask.sum():>6} px  "
            f"counter {holes.sum():>5} px filled  "
            f"tip y {measurement['tip_y']:.2f}  "
            f"head ({measurement['head_centre_y']:.2f}, "
            f"d {measurement['head_diameter']:.2f})  "
            f"{path.stat().st_size:>5} bytes"
        )

    write_preview(alphas, PREVIEW_PATH)
    manifest_path = OUTPUT_DIR / "manifest.json"
    write_manifest(manifest_path, backdrops)

    print(f"\nicons:    {OUTPUT_DIR}")
    print(f"manifest: {manifest_path}")
    print(f"preview:  {PREVIEW_PATH}")


if __name__ == "__main__":
    main()
