#!/usr/bin/env python3
"""Turn raw app screenshots into App Store marketing images.

Style matches the app: graphite canvas, brushed-gold caption, serif type.

Usage
    python3 scripts/make_screenshots.py \
        --input ~/pdfmaster_assets/raw \
        --output ~/pdfmaster_assets/out \
        --lang uk

The files are paired with captions in filename order, so name them
01-create.png, 02-scan.png, 03-sign.png, 04-convert.png …
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Apple's required sizes: iPhone 6.7" is mandatory, 6.5" is a useful extra.
CANVAS = {
    "6.7": (1290, 2796),
    "6.5": (1242, 2688),
}

CAPTIONS = {
    "uk": [
        ("Сканер документів", "Краї, перспектива й чистий скан — автоматично"),
        ("PDF з фото", "Кілька знімків — один акуратний документ"),
        ("Підпис у один дотик", "Намалюйте пальцем і збережіть назавжди"),
        ("Word та Excel у PDF", "Точний рендер без втрат форматування"),
    ],
    "en": [
        ("Document scanner", "Edges, perspective and a clean scan — automatically"),
        ("PDF from photos", "Several shots become one tidy document"),
        ("Sign in one tap", "Draw with a finger, reuse it forever"),
        ("Word and Excel to PDF", "Faithful rendering, no broken layout"),
    ],
}

GOLD = (230, 191, 77)
GOLD_LIGHT = (245, 219, 140)
CANVAS_COLOR = (10, 10, 13)
TEXT_COLOR = (245, 243, 238)
MUTED = (168, 163, 152)

SERIF_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"
SERIF = "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf"


def font(path: str, size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def wrap(draw: ImageDraw.ImageDraw, text: str, fnt, max_width: int) -> list[str]:
    words, lines, current = text.split(), [], ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if draw.textlength(candidate, font=fnt) <= max_width:
            current = candidate
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def vertical_gradient(size: tuple[int, int]) -> Image.Image:
    width, height = size
    base = Image.new("RGB", size, CANVAS_COLOR)
    top = Image.new("RGB", size, (16, 16, 21))
    mask = Image.linear_gradient("L").resize((width, height))
    return Image.composite(top, base, mask.point(lambda v: int(v * 0.55)))


def device_shot(screenshot: Image.Image, width: int) -> Image.Image:
    """Scale the screenshot to the requested width and round its corners."""
    ratio = width / screenshot.width
    shot = screenshot.convert("RGB").resize((width, int(screenshot.height * ratio)), Image.LANCZOS)
    radius = int(width * 0.045)
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.width, shot.height], radius=radius, fill=255)
    rounded = Image.new("RGB", shot.size, CANVAS_COLOR)
    rounded.paste(shot, (0, 0), mask)
    return rounded


def compose(screenshot: Image.Image, caption: str, subtitle: str, size: tuple[int, int]) -> Image.Image:
    width, height = size
    canvas = vertical_gradient(size)
    draw = ImageDraw.Draw(canvas)

    margin = int(width * 0.09)
    title_font = font(SERIF_BOLD, int(width * 0.075))
    subtitle_font = font(SERIF, int(width * 0.037))
    eyebrow_font = font(SERIF_BOLD, int(width * 0.028))

    y = int(height * 0.055)
    draw.text((margin, y), "PDF MASTER", font=eyebrow_font, fill=GOLD)
    y += int(width * 0.06)

    for line in wrap(draw, caption, title_font, width - margin * 2):
        draw.text((margin, y), line, font=title_font, fill=TEXT_COLOR)
        y += int(title_font.size * 1.18)

    y += int(width * 0.012)
    for line in wrap(draw, subtitle, subtitle_font, int(width * 0.78)):
        draw.text((margin, y), line, font=subtitle_font, fill=MUTED)
        y += int(subtitle_font.size * 1.35)

    # hairline gold rule
    rule_y = y + int(width * 0.03)
    draw.line([(margin, rule_y), (margin + int(width * 0.18), rule_y)], fill=GOLD, width=2)

    shot_y = rule_y + int(width * 0.11)
    # Fit the phone into the space that is actually left; otherwise a tall
    # screenshot would be clipped at the bottom of the canvas.
    available_height = height - shot_y - int(height * 0.045)
    aspect = screenshot.height / screenshot.width
    shot_width = min(int(width * 0.84), int(available_height / aspect))
    shot = device_shot(screenshot, shot_width)
    # Centre the phone in the space that is left, so a shorter crop does not
    # leave a large empty band at the bottom.
    shot_y += max(0, (available_height - shot.height) // 3)
    shot_x = (width - shot_width) // 2

    # shadow beneath the phone frame
    shadow = Image.new("RGBA", (shot.width + 80, shot.height + 80), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [40, 40, shadow.width - 40, shadow.height - 40],
        radius=int(shot_width * 0.05),
        fill=(0, 0, 0, 180),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    canvas.paste(shadow, (shot_x - 40, shot_y - 20), shadow)

    canvas.paste(shot, (shot_x, shot_y))
    frame = ImageDraw.Draw(canvas)
    frame.rounded_rectangle(
        [shot_x, shot_y, shot_x + shot.width, shot_y + shot.height],
        radius=int(shot_width * 0.045),
        outline=GOLD,
        width=2,
    )
    return canvas


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default=str(Path.home() / "pdfmaster_assets/raw"))
    parser.add_argument("--output", default=str(Path.home() / "pdfmaster_assets/out"))
    parser.add_argument("--lang", default="uk", choices=sorted(CAPTIONS))
    parser.add_argument("--sizes", default="6.7", help="comma separated: 6.7,6.5")
    parser.add_argument("--captions", help="JSON file with [[title, subtitle], ...]")
    args = parser.parse_args()

    source = Path(args.input).expanduser()
    target = Path(args.output).expanduser()
    target.mkdir(parents=True, exist_ok=True)
    shots = sorted(p for p in source.glob("*") if p.suffix.lower() in {".png", ".jpg", ".jpeg"})
    if not shots:
        print(f"no screenshots in {source}")
        return 1

    captions = CAPTIONS[args.lang]
    if args.captions:
        captions = [tuple(pair) for pair in json.loads(Path(args.captions).read_text())]

    sizes = [CANVAS[key.strip()] for key in args.sizes.split(",") if key.strip() in CANVAS]
    made = []
    for index, shot_path in enumerate(shots[: len(captions)]):
        title, subtitle = captions[index]
        screenshot = Image.open(shot_path)
        for device_size in sizes:
            label = f"{device_size[0]}x{device_size[1]}"
            canvas = compose(screenshot, title, subtitle, device_size)
            out = target / f"{index + 1:02d}-{args.lang}-{label}.png"
            canvas.save(out, "PNG", optimize=True)
            made.append(out)
            print(f"wrote {out} ({canvas.width}x{canvas.height})")
    print(f"\n{len(made)} files in {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
