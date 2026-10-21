"""Generate StackPilot branding images and the Windows app icon.

Run from the project root:
    python tool/generate_branding.py
"""

from __future__ import annotations

import io
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets" / "branding"
WINDOWS_ICON = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"

SIZE = 1024
SS = 2  # draw at 2x for smoother edges, then downsample


def lerp(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGBA", (size, size))
    pixels = image.load()
    for y in range(size):
        t = y / max(1, size - 1)
        color = (
            lerp(top[0], bottom[0], t),
            lerp(top[1], bottom[1], t),
            lerp(top[2], bottom[2], t),
            255,
        )
        for x in range(size):
            pixels[x, y] = color
    return image


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def draw_plate(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    fill: tuple[int, int, int, int],
    shadow: tuple[int, int, int, int],
    radius: int,
) -> None:
    x0, y0, x1, y1 = box
    width = max(1, x1 - x0)
    height = max(1, y1 - y0)
    offset_x = max(1, round(width * 0.015))
    offset_y = max(1, round(height * 0.12))
    # Bottom thickness / shadow.
    draw.rounded_rectangle(
        (x0 + offset_x, y0 + offset_y, x1 + offset_x, y1 + offset_y),
        radius=radius,
        fill=shadow,
    )
    draw.rounded_rectangle(box, radius=radius, fill=fill)
    # Top highlight.
    inset = min(max(1, (x1 - x0) // 12), max(1, (x1 - x0) // 4))
    highlight_top = y0 + max(1, (y1 - y0) // 8)
    highlight_bottom = y0 + max(2, (y1 - y0) // 4)
    if x1 - inset > x0 + inset and highlight_bottom > highlight_top:
        draw.rounded_rectangle(
            (x0 + inset, highlight_top, x1 - inset, highlight_bottom),
            radius=radius // 2,
            fill=(255, 255, 255, 95),
        )


def draw_mark(size: int, background: bool, detail: bool = True) -> Image.Image:
    scale = size / SIZE
    canvas_size = size * SS
    image = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    def s(value: float) -> int:
        return round(value * scale * SS)

    # Background panel.
    if background:
        gradient = vertical_gradient(canvas_size, (9, 48, 36), (14, 122, 74))
        mask = rounded_mask(canvas_size, s(220))
        panel = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
        panel.paste(gradient, (0, 0), mask)

        # Soft top-left glow.
        glow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
        glow_draw = ImageDraw.Draw(glow)
        glow_draw.ellipse(
            (s(-240), s(-300), s(640), s(580)),
            fill=(80, 235, 165, 45),
        )
        glow = glow.filter(ImageFilter.GaussianBlur(s(90)))
        panel.alpha_composite(glow)
        image.alpha_composite(panel)

        # Inner border.
        draw.rounded_rectangle(
            (s(14), s(14), canvas_size - s(14), canvas_size - s(14)),
            radius=s(208),
            outline=(255, 255, 255, 42),
            width=s(7),
        )

        # Orbit ring behind the stack.
        if detail:
            draw.ellipse(
                (s(150), s(180), s(874), s(904)),
                outline=(160, 245, 210, 55),
                width=s(10),
            )

    # The stack: three rounded plates with a slight offset for depth.
    plate_specs = [
        ((s(210), s(590), s(814), s(724)), (244, 255, 250, 255)),
        ((s(240), s(458), s(784), s(592)), (214, 246, 230, 255)),
        ((s(270), s(326), s(754), s(460)), (178, 238, 210, 255)),
    ]
    for box, fill in plate_specs:
        draw_plate(
            draw,
            box,
            fill=fill,
            shadow=(4, 34, 24, 105),
            radius=s(62),
        )

    # Port dots on the right side of each plate.
    if detail:
        for cy, color in (
            (s(657), (14, 122, 74, 255)),
            (s(525), (14, 122, 74, 255)),
            (s(393), (14, 122, 74, 255)),
        ):
            draw.ellipse(
                (s(742), cy - s(13), s(768), cy + s(13)),
                fill=color,
            )

    # Launch arrow rising from the top plate.
    arrow = (255, 138, 76, 255)
    arrow_light = (255, 186, 140, 255)
    # Shaft.
    draw.rounded_rectangle(
        (s(490), s(170), s(534), s(388)),
        radius=s(22),
        fill=arrow,
    )
    # Arrowhead.
    draw.polygon(
        [
            (s(512), s(70)),
            (s(650), s(230)),
            (s(512), s(186)),
            (s(374), s(230)),
        ],
        fill=arrow,
    )
    # Highlight facet on the left half.
    draw.polygon(
        [
            (s(512), s(70)),
            (s(512), s(230)),
            (s(410), s(218)),
        ],
        fill=arrow_light,
    )
    draw.rounded_rectangle(
        (s(490), s(190), s(506), s(376)),
        radius=s(8),
        fill=arrow_light,
    )

    # A tiny pilot spark.
    if detail:
        draw.ellipse(
            (s(690), s(250), s(736), s(296)),
            fill=(255, 246, 224, 235),
        )
        draw.ellipse(
            (s(704), s(264), s(722), s(282)),
            fill=(14, 122, 74, 255),
        )

    return image.resize((size, size), Image.Resampling.LANCZOS)


def write_ico(path: Path, sizes: tuple[int, ...]) -> None:
    frames: list[tuple[int, bytes]] = []
    for size in sizes:
        image = draw_mark(size, background=True, detail=size >= 64)
        buffer = io.BytesIO()
        image.save(buffer, format="PNG", optimize=True)
        frames.append((size, buffer.getvalue()))

    header = struct.pack("<HHH", 0, 1, len(frames))
    entries: list[bytes] = []
    payload: list[bytes] = []
    offset = 6 + 16 * len(frames)
    for size, blob in frames:
        dimension = 0 if size >= 256 else size
        entries.append(
            struct.pack(
                "<BBBBHHII",
                dimension,
                dimension,
                0,
                0,
                1,
                32,
                len(blob),
                offset,
            )
        )
        offset += len(blob)
        payload.append(blob)

    path.write_bytes(header + b"".join(entries) + b"".join(payload))


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    WINDOWS_ICON.parent.mkdir(parents=True, exist_ok=True)

    icon = draw_mark(1024, background=True)
    mark = draw_mark(1024, background=False, detail=False)

    icon.save(ASSETS / "stackpilot_icon.png")
    mark.save(ASSETS / "stackpilot_mark.png")
    write_ico(WINDOWS_ICON, (16, 24, 32, 48, 64, 128, 256))

    print(f"Wrote {ASSETS / 'stackpilot_icon.png'}")
    print(f"Wrote {ASSETS / 'stackpilot_mark.png'}")
    print(f"Wrote {WINDOWS_ICON}")


if __name__ == "__main__":
    main()
