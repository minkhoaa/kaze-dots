#!/usr/bin/env python3
"""Independent visual/pixel/contrast/OCR oracles using grim and stdlib."""

from __future__ import annotations

import hashlib
import math
from pathlib import Path
import re
import subprocess
from typing import Any, NamedTuple


class RawImage(NamedTuple):
    width: int
    height: int
    data: bytes  # RGB24 (len == width * height * 3)


def parse_ppm(blob: bytes) -> RawImage:
    """Parse binary PPM (P6) bytes into RawImage."""
    if not blob.startswith(b"P6"):
        raise ValueError("Not a P6 PPM stream")
    idx = 2
    n = len(blob)
    tokens: list[bytes] = []
    while len(tokens) < 3 and idx < n:
        ch = blob[idx : idx + 1]
        if ch in b" \t\r\n":
            idx += 1
            continue
        if ch == b"#":
            nl = blob.find(b"\n", idx)
            if nl == -1:
                break
            idx = nl + 1
            continue
        start = idx
        while idx < n and blob[idx : idx + 1] not in b" \t\r\n#":
            idx += 1
        tokens.append(blob[start:idx])
    if len(tokens) < 3:
        raise ValueError("Incomplete PPM header")
    width = int(tokens[0])
    height = int(tokens[1])
    maxval = int(tokens[2])
    if maxval != 255:
        raise ValueError(f"Unsupported PPM maxval={maxval}")
    if idx < n and blob[idx : idx + 1] in b" \t\r\n":
        idx += 1
    expected = width * height * 3
    rgb = blob[idx : idx + expected]
    if len(rgb) != expected:
        raise ValueError(f"Truncated PPM payload: got {len(rgb)}, expected {expected}")
    return RawImage(width, height, rgb)


def _grim_args(region: tuple[int, int, int, int] | None, output: str | None) -> list[str]:
    args = ["grim"]
    if region is not None:
        x, y, w, h = region
        args.extend(["-g", f"{int(x)},{int(y)} {int(w)}x{int(h)}"])
    elif output:
        args.extend(["-o", output])
    return args


def capture_ppm(
    region: tuple[int, int, int, int] | None = None,
    output: str | None = "Virtual-1",
) -> RawImage:
    cmd = [*_grim_args(region, output), "-t", "ppm", "-"]
    res = subprocess.run(cmd, check=True, capture_output=True, timeout=5)
    return parse_ppm(res.stdout)


def capture_png(
    path: str | Path,
    region: tuple[int, int, int, int] | None = None,
    output: str | None = "Virtual-1",
) -> Path:
    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [*_grim_args(region, output), "-t", "png", str(out_path)]
    subprocess.run(cmd, check=True, capture_output=True, timeout=5)
    return out_path


def sha256_img(img: RawImage) -> str:
    return hashlib.sha256(img.data).hexdigest()


def pixel_variance(img: RawImage) -> float:
    data = img.data
    n_pix = img.width * img.height
    if n_pix == 0:
        return 0.0
    lums = [
        0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2]
        for i in range(0, len(data), 3)
    ]
    mean = sum(lums) / n_pix
    return sum((v - mean) ** 2 for v in lums) / n_pix


def diff_stats(img_a: RawImage, img_b: RawImage, threshold: int = 14) -> dict[str, Any]:
    if (img_a.width, img_a.height) != (img_b.width, img_b.height):
        raise ValueError(
            f"Image size mismatch: {(img_a.width, img_a.height)} vs {(img_b.width, img_b.height)}"
        )
    w, h = img_a.width, img_a.height
    da, db = img_a.data, img_b.data
    changed_indices: list[int] = []
    abs_sum = 0
    x0, y0, x1, y1 = w, h, -1, -1
    row_pixels: dict[int, list[int]] = {}

    for p in range(w * h):
        off = p * 3
        dr = abs(da[off] - db[off])
        dg = abs(da[off + 1] - db[off + 1])
        db_ = abs(da[off + 2] - db[off + 2])
        abs_sum += dr + dg + db_
        if max(dr, dg, db_) >= threshold:
            changed_indices.append(p)
            x = p % w
            y = p // w
            if x < x0:
                x0 = x
            if y < y0:
                y0 = y
            if x > x1:
                x1 = x
            if y > y1:
                y1 = y
            row_pixels.setdefault(y, []).append(x)

    y_bands: list[tuple[int, int, int, int, int]] = []
    if row_pixels:
        ys = sorted(row_pixels)
        bands: list[list[int]] = [[ys[0]]]
        for y in ys[1:]:
            if y - bands[-1][-1] >= 4:
                bands.append([y])
            else:
                bands[-1].append(y)
        for by in bands:
            sx = 0
            sy = 0
            cnt = 0
            for y in by:
                xs = row_pixels[y]
                sx += sum(xs)
                sy += y * len(xs)
                cnt += len(xs)
            y_bands.append((by[0], by[-1], round(sx / cnt), round(sy / cnt), cnt))

    n_pix = max(w * h, 1)
    bbox = (x0, y0, x1, y1) if x1 >= 0 else None
    return {
        "changed_count": len(changed_indices),
        "changed_ratio": len(changed_indices) / n_pix,
        "mae": abs_sum / (n_pix * 3.0),
        "bbox": bbox,
        "y_bands": y_bands,
        "changed_indices": changed_indices,
    }


def _iter_region_pixels(
    img: RawImage,
    region_bbox: tuple[int, int, int, int] | None = None,
    indices: list[int] | None = None,
):
    da = img.data
    w, h = img.width, img.height
    if indices is not None:
        for p in indices:
            off = p * 3
            yield da[off], da[off + 1], da[off + 2]
        return
    if region_bbox is None:
        x0, y0, x1, y1 = 0, 0, w - 1, h - 1
    else:
        x0, y0, x1, y1 = region_bbox
        x0 = max(0, x0)
        y0 = max(0, y0)
        x1 = min(w - 1, x1)
        y1 = min(h - 1, y1)
    for y in range(y0, y1 + 1):
        base = y * w * 3
        for x in range(x0, x1 + 1):
            off = base + x * 3
            yield da[off], da[off + 1], da[off + 2]


def chromatic_stats(
    img: RawImage,
    region_bbox: tuple[int, int, int, int] | None = None,
    indices: list[int] | None = None,
    min_sat: int = 50,
) -> dict[str, Any]:
    sr = sg = sb = cnt = 0
    for r, g, b in _iter_region_pixels(img, region_bbox, indices):
        if max(r, g, b) - min(r, g, b) >= min_sat:
            sr += r
            sg += g
            sb += b
            cnt += 1
    if cnt == 0:
        return {"count": 0, "mean_r": 0.0, "mean_g": 0.0, "mean_b": 0.0}
    return {
        "count": cnt,
        "mean_r": sr / cnt,
        "mean_g": sg / cnt,
        "mean_b": sb / cnt,
    }


def mean_rgb(
    img: RawImage,
    region_bbox: tuple[int, int, int, int] | None = None,
) -> tuple[float, float, float]:
    sr = sg = sb = cnt = 0
    for r, g, b in _iter_region_pixels(img, region_bbox, None):
        sr += r
        sg += g
        sb += b
        cnt += 1
    if cnt == 0:
        return (0.0, 0.0, 0.0)
    return (sr / cnt, sg / cnt, sb / cnt)


def _srgb_channel(v: int) -> float:
    c = v / 255.0
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def relative_luminance(rgb: tuple[int, int, int]) -> float:
    r, g, b = rgb
    return 0.2126 * _srgb_channel(r) + 0.7152 * _srgb_channel(g) + 0.0722 * _srgb_channel(b)


def wcag_contrast_ratio(rgb1: tuple[int, int, int], rgb2: tuple[int, int, int]) -> float:
    l1 = relative_luminance(rgb1)
    l2 = relative_luminance(rgb2)
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def parse_hex_color(value: str) -> tuple[int, int, int]:
    s = value.strip()
    m = re.match(r"^(?:#|0x)?([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$", s)
    if m:
        hx = m.group(1)
        return int(hx[0:2], 16), int(hx[2:4], 16), int(hx[4:6], 16)
    m_rgb = re.match(r"^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)", s)
    if m_rgb:
        return int(m_rgb.group(1)), int(m_rgb.group(2)), int(m_rgb.group(3))
    raise ValueError(f"Unrecognized color format: {value!r}")


def check_theme_wcag(
    foot_theme_path: str | Path,
    gtk3_css_path: str | Path,
) -> tuple[float, dict[str, float]]:
    ratios: dict[str, float] = {}
    foot_text = Path(foot_theme_path).read_text(errors="replace")
    section = ""
    foot_colors: dict[str, dict[str, tuple[int, int, int]]] = {}
    for raw_line in foot_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if "=" in line:
            k, v = [x.strip() for x in line.split("=", 1)]
            if k in ("foreground", "background"):
                try:
                    foot_colors.setdefault(section, {})[k] = parse_hex_color(v)
                except ValueError:
                    pass
    for sec, cols in foot_colors.items():
        if "foreground" in cols and "background" in cols:
            ratios[f"foot:{sec}"] = wcag_contrast_ratio(cols["foreground"], cols["background"])

    gtk_text = Path(gtk3_css_path).read_text(errors="replace")
    gtk_vars: dict[str, tuple[int, int, int]] = {}
    for m in re.finditer(r"@define-color\s+([A-Za-z0-9_-]+)\s+([^;]+);", gtk_text):
        try:
            gtk_vars[m.group(1)] = parse_hex_color(m.group(2))
        except ValueError:
            pass
    for fg_name, bg_name in (
        ("theme_fg_color", "theme_bg_color"),
        ("theme_text_color", "theme_base_color"),
        ("theme_selected_fg_color", "theme_selected_bg_color"),
        ("window_fg_color", "window_bg_color"),
        ("view_fg_color", "view_bg_color"),
        ("accent_fg_color", "accent_bg_color"),
    ):
        if fg_name in gtk_vars and bg_name in gtk_vars:
            ratios[f"gtk:{fg_name}/{bg_name}"] = wcag_contrast_ratio(
                gtk_vars[fg_name], gtk_vars[bg_name]
            )
    if not ratios:
        raise ValueError("No foreground/background color pairs found in generated themes")
    return min(ratios.values()), ratios


def ocr_words(png_path: str | Path, psm: int = 11) -> list[dict[str, Any]]:
    res = subprocess.run(
        ["tesseract", str(png_path), "stdout", "--psm", str(psm), "tsv"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    words: list[dict[str, Any]] = []
    lines = res.stdout.splitlines()
    for line in lines[1:]:
        parts = line.split("\t")
        if len(parts) < 12:
            continue
        text = parts[11].strip()
        if not text:
            continue
        try:
            conf = float(parts[10])
            x, y, w, h = int(parts[6]), int(parts[7]), int(parts[8]), int(parts[9])
        except ValueError:
            continue
        words.append({"text": text, "x": x, "y": y, "w": w, "h": h, "conf": conf})
    return words
