#!/usr/bin/env python3
"""Generates the Arkenal icon files from one drawing.

The mark: a peak (an "A", a snowy summit, a roof) with a snow-filled tip,
sheltering a core. Drawn in a 100-unit square; everything else is scaled
from it, so the app icons, the menu bar icon and the Finder symbol match.

Run from the repository's harbor/ folder:  python3 Design/AppIcon/make_icons.py
"""
import json
from pathlib import Path

# Two legs (outer edge mitred at the top) and the snow-filled tip, as one shape.
PEAK = [(19.56, 78), (50, 14.78), (80.44, 78), (71.56, 78), (54.47, 42.5), (45.53, 42.5), (28.44, 78)]
CORE = ((50, 63), 8)
# The icon artwork sits a little lower so the mark looks centred.
ICON_SHIFT = 3

VARIANTS = {
    # folder: (background, mark, core)
    "AppIcon": ("232B30", "EEF1F2", "A9B8C1"),          # Granite (main icon)
    "AppIcon-Snow": ("EEF1F2", "2E3A41", "6F7E86"),
    "AppIcon-Spruce": ("1D4B3C", "F3F0E8", "8FD3B0"),
    "AppIcon-Fjord": ("1F4A6E", "F2F5F8", "7FB2DA"),
}

ROOT = Path(__file__).resolve().parents[2]


def pts(scale, dx=0.0, dy=0.0):
    return " ".join(f"{x * scale + dx:.1f},{y * scale + dy:.1f}" for x, y in PEAK)


def circle(scale, dx=0.0, dy=0.0):
    (cx, cy), r = CORE
    return cx * scale + dx, cy * scale + dy, r * scale


def icon_layers(mark, core):
    s, dy = 10.24, ICON_SHIFT * 10.24
    cx, cy, r = circle(s, 0, dy)
    peak = (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            f'  <!-- Arkenal: the peak, its snow-filled tip a roof over the core. -->\n'
            f'  <polygon points="{pts(s, 0, dy)}" fill="#{mark}" stroke="#{mark}" stroke-width="6" stroke-linejoin="round"/>\n'
            f'</svg>\n')
    dot = (f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
           f'  <!-- The core: what Arkenal keeps safe. -->\n'
           f'  <circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="#{core}"/>\n'
           f'</svg>\n')
    return peak, dot


def srgb(hexcolor):
    r, g, b = (int(hexcolor[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"extended-srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


def write_icon(folder, background, mark, core):
    base = ROOT / "App" / f"{folder}.icon"
    assets = base / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for old in assets.iterdir():
        old.unlink()
    peak, dot = icon_layers(mark, core)
    (assets / "peak.svg").write_text(peak)
    (assets / "core.svg").write_text(dot)
    spec = {
        "fill": {"automatic-gradient": srgb(background)},
        "groups": [{
            "layers": [
                {"image-name": "core.svg", "name": "core", "glass": True},
                {"image-name": "peak.svg", "name": "peak", "glass": True},
            ],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.4},
        }],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    (base / "icon.json").write_text(json.dumps(spec, indent=2) + "\n")


def write_preview():
    background, mark, core = VARIANTS["AppIcon"]
    s, dy = 10.24, ICON_SHIFT * 10.24
    cx, cy, r = circle(s, 0, dy)
    (ROOT / "Design/AppIcon/preview.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
        f'  <!-- Flat preview of the full icon (Icon Composer adds the glass, light and dark). -->\n'
        f'  <rect width="1024" height="1024" rx="229" fill="#{background}"/>\n'
        f'  <polygon points="{pts(s, 0, dy)}" fill="#{mark}" stroke="#{mark}" stroke-width="6" stroke-linejoin="round"/>\n'
        f'  <circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="#{core}"/>\n'
        f'</svg>\n')


def write_menu_bar():
    cx, cy, r = circle(1)
    (ROOT / "App/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="16 12.4 68 68">\n'
        f'  <!-- The Arkenal mark as a menu bar template: black on clear. -->\n'
        f'  <polygon points="{pts(1)}" fill="#000"/>\n'
        f'  <circle cx="{cx}" cy="{cy}" r="{r}" fill="#000"/>\n'
        f'</svg>\n')


def write_symbol():
    path = ROOT / "FileProvider/Assets.xcassets/ArkenalMark.symbolset/ArkenalMark.svg"
    text = path.read_text()
    # Regular-M: the glyph fills the cap height of the template (y 1042-1132).
    s = 90 / (78 - 14.78)
    ox, oy = 1391 - 50 * s, 1042 - 14.78 * s
    xs = [x * s + ox for x, _ in PEAK]
    poly = " L".join(f"{x * s + ox:.2f} {y * s + oy:.2f}" for x, y in PEAK)
    (cx, cy), r = CORE
    cx, cy, r = cx * s + ox, cy * s + oy, r * s
    glyph = (f'  <g id="Regular-M">\n'
             f'   <path d="M{poly} Z"/>\n'
             f'   <path d="M{cx - r:.2f} {cy:.2f} A{r:.2f} {r:.2f} 0 1 1 {cx + r:.2f} {cy:.2f} A{r:.2f} {r:.2f} 0 1 1 {cx - r:.2f} {cy:.2f} Z"/>\n'
             f'  </g>\n')
    start = text.index('  <g id="Regular-M">')
    end = text.index('  </g>\n', start) + len('  </g>\n')
    text = text[:start] + glyph + text[end:]
    left, right = min(xs) - 4, max(xs) + 4
    import re
    text = re.sub(r'(id="left-margin-Regular-M"[^>]*x1=")[\d.]+(" x2=")[\d.]+', rf'\g<1>{left:.2f}\g<2>{left:.2f}', text)
    text = re.sub(r'(id="right-margin-Regular-M"[^>]*x1=")[\d.]+(" x2=")[\d.]+', rf'\g<1>{right:.2f}\g<2>{right:.2f}', text)
    text = text.replace("<!-- Arkenal mark as a custom symbol", "<!-- The Arkenal peak as a custom symbol")
    path.write_text(text)


if __name__ == "__main__":
    for folder, colors in VARIANTS.items():
        write_icon(folder, *colors)
    write_preview()
    write_menu_bar()
    write_symbol()
    print("Wrote", ", ".join(VARIANTS), "+ preview, menu bar icon, Finder symbol")
