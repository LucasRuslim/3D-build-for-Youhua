#!/usr/bin/env python3
"""Builds everyday school items that work as weapons: models, textures, scenes.

Outputs (relative to the repo root):
  assets/school_items/models/*.glb
  assets/school_items/textures/*.png
  assets/school_items/scenes/*.tscn

Items are StationeryWeapon props (the fire extinguisher has its own script).
Conventions: metres, +Y up, the grip at the origin, the business end along -Z.

  python3 tools/generate_school_items.py
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_assets import (MeshPart, add_box, add_profiled_slab, add_round_tube_path,  # noqa: E402
                             fix_winding, grid_indices, height_to_normal, periodic_noise, write_glb)
from generate_stationery import (add_lathe, add_prism, add_transformed, parts_aabb, parts_for,  # noqa: E402
                                 rot_x, shift_parts, write_scene)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "school_items"
UP = rot_x(-math.pi / 2)  # turns a lathe built along +Z into one along +Y


def upright(part, origin, build):
    """Build a lathe (along Z) and stand it up along Y at `origin`."""
    add_transformed(part, UP, origin, build)


# --------------------------------------------------------------------------
# Textures
# --------------------------------------------------------------------------

def make_textures() -> dict[str, Path]:
    tex_dir = OUT / "textures"
    tex_dir.mkdir(parents=True, exist_ok=True)
    paths: dict[str, Path] = {}

    def save(name, img):
        p = tex_dir / f"{name}.png"
        img.save(p, optimize=True)
        paths[name] = p

    # Basketball: equirectangular, pebbled orange with the classic 8-panel seams.
    W, H = 1024, 512
    lon = (np.arange(W) + 0.5) / W * 2 * math.pi
    lat = (np.arange(H) + 0.5) / H * math.pi  # 0 = top
    LON, LAT = np.meshgrid(lon, lat)
    d = np.stack([np.sin(LAT) * np.cos(LON), np.cos(LAT), np.sin(LAT) * np.sin(LON)], axis=-1)
    seam = np.zeros((H, W), bool)
    w = 0.018
    seam |= np.abs(d[..., 1]) < w                      # equator
    seam |= np.abs(d[..., 0]) < w                      # middle line, half-way between the curves
    for sx in (1, -1):                                 # the two curved side seams, around +-X
        seam |= np.abs(d[..., 0] * sx - math.cos(math.radians(48))) < w * 1.1
    pebble = periodic_noise(W, 0.9, 21)[:H, :W]
    base = np.array((214, 98, 30), float)
    col = base[None, None, :] * (1.0 + 0.07 * pebble[..., None])
    col[seam] = (25, 18, 14)
    save("basketball_albedo", Image.fromarray(np.clip(col, 0, 255).astype(np.uint8)))
    hgt = periodic_noise(W, 0.9, 22)[:H, :W] - seam * 1.5
    save("basketball_normal", Image.fromarray(height_to_normal(hgt, 1.2)))

    # Fire extinguisher label, wraps around the body (U = around, V = up/down).
    lw, lh = 1024, 256
    img = Image.new("RGB", (lw, lh), (200, 30, 30))
    dr = ImageDraw.Draw(img)
    x0, x1 = int(0.08 * lw), int(0.42 * lw)  # panel centred on U = 0.25 (faces -Z)
    dr.rectangle([x0, 0, x1, lh], fill=(245, 245, 240))
    big = ImageFont.load_default(size=34)
    small = ImageFont.load_default(size=20)
    for i, line in enumerate(["FIRE", "EXTINGUISHER"]):
        tw = dr.textlength(line, font=big)
        dr.text(((x0 + x1) / 2 - tw / 2, 18 + i * 40), line, font=big, fill=(200, 30, 30))
    for i, (letter, colr) in enumerate([("A", (30, 140, 60)), ("B", (220, 60, 40)), ("C", (40, 90, 200))]):
        cx = x0 + 40 + i * 70
        dr.rectangle([cx, 120, cx + 54, 174], fill=colr)
        dr.text((cx + 17, 130), letter, font=big, fill=(255, 255, 255))
    dr.text((x0 + 18, 196), "PULL  AIM  SQUEEZE  SWEEP", font=small, fill=(30, 30, 30))
    save("extinguisher_label", img)

    # Textbook cover.
    img = Image.new("RGB", (512, 704), (32, 78, 160))
    dr = ImageDraw.Draw(img)
    dr.rectangle([0, 470, 512, 560], fill=(250, 196, 40))
    title = ImageFont.load_default(size=120)
    tw = dr.textlength("MATH", font=title)
    dr.text((256 - tw / 2, 120), "MATH", font=title, fill=(255, 255, 255))
    sub = ImageFont.load_default(size=44)
    tw = dr.textlength("Grade 8", font=sub)
    dr.text((256 - tw / 2, 290), "Grade 8", font=sub, fill=(220, 230, 255))
    for k in range(6):
        dr.ellipse([60 + k * 70, 600, 100 + k * 70, 640], outline=(250, 196, 40), width=6)
    save("textbook_cover", img)

    # Red backpack fabric.
    s = 512
    yy, xx = np.mgrid[0:s, 0:s]
    weave = np.sin(xx * 2 * math.pi / 8) * np.sin(yy * 2 * math.pi / 8) + periodic_noise(s, 1.0, 23) * 0.4
    base = np.array((178, 34, 40), float)
    shade = 1.0 + 0.06 * weave + 0.04 * periodic_noise(s, 20, 24)
    save("fabric_red_albedo", Image.fromarray(np.clip(base[None, None, :] * shade[..., None], 0, 255).astype(np.uint8)))
    save("fabric_red_normal", Image.fromarray(height_to_normal(weave, 0.6)))

    # Spray paint puff: thousands of tiny droplets, dense in the middle and
    # thinning to fine speckles at the edge, over a faint haze. White (tinted
    # by the paint colour in Godot); overlapping puffs build up like real
    # spray paint.
    n = 512
    rng = np.random.default_rng(100)
    a = np.zeros((n, n))
    yy, xx = np.mgrid[0:5, 0:5] - 2.0
    for _ in range(14000):
        r = min(abs(rng.normal(0.0, 0.34)), 0.97)
        t = rng.uniform(0, 2 * math.pi)
        px, py = (0.5 + 0.5 * r * math.cos(t)) * n, (0.5 + 0.5 * r * math.sin(t)) * n
        rad = rng.uniform(0.5, 1.4)
        ix, iy = int(px), int(py)
        if not (2 <= ix < n - 2 and 2 <= iy < n - 2):
            continue
        d = np.hypot(xx + ix + 0.5 - px, yy + iy + 0.5 - py)
        cov = np.clip(rad - d + 0.5, 0, 1) * rng.uniform(0.6, 1.0)
        win = a[iy - 2:iy + 3, ix - 2:ix + 3]
        a[iy - 2:iy + 3, ix - 2:ix + 3] = 1 - (1 - win) * (1 - cov)
    gy, gx = (np.mgrid[0:n, 0:n] + 0.5) / n * 2 - 1
    haze = 0.32 * np.exp(-(np.hypot(gx, gy) / 0.32) ** 2)
    a = 1 - (1 - a) * (1 - haze)
    rgba = np.zeros((n, n, 4), np.uint8)
    rgba[..., :3] = 255
    rgba[..., 3] = np.clip(a * 255, 0, 255).astype(np.uint8)
    save("paint_spray", Image.fromarray(rgba, "RGBA"))

    # Spray can label: red with drips and the colour name.
    img = Image.new("RGB", (1024, 384), (205, 18, 24))
    dr = ImageDraw.Draw(img)
    dr.rectangle([0, 0, 1024, 70], fill=(30, 30, 34))
    for k in range(18):
        x = 30 + k * 57
        dr.rectangle([x, 70, x + 16, 70 + 40 + (k * 37) % 90], fill=(30, 30, 34))
        dr.ellipse([x - 3, 100 + (k * 37) % 90, x + 19, 122 + (k * 37) % 90], fill=(30, 30, 34))
    big = ImageFont.load_default(size=70)
    small = ImageFont.load_default(size=34)
    for cx in (256, 768):
        dr.text((cx - dr.textlength("RED", font=big) / 2, 210), "RED", font=big, fill=(255, 255, 255))
        dr.text((cx - dr.textlength("SPRAY PAINT", font=small) / 2, 300), "SPRAY PAINT", font=small,
                fill=(255, 230, 230))
    save("spray_label", img)
    return paths


MATS = {
    "ExtRed": {"color": (200, 30, 30), "roughness": 0.3},
    "ExtLabel": {"color": (255, 255, 255), "albedo_tex": "extinguisher_label", "roughness": 0.4},
    "Chrome": {"color": (216, 220, 224), "metallic": 0.8, "roughness": 0.2},
    "BlackPlastic": {"color": (28, 28, 30), "roughness": 0.5},
    "PinYellow": {"color": (240, 200, 30), "roughness": 0.4},
    "HandleBlue": {"color": (40, 90, 180), "roughness": 0.4},
    "BroomRed": {"color": (200, 45, 45), "roughness": 0.5},
    "Bristle": {"color": (232, 197, 71), "roughness": 0.9},
    "Canopy": {"color": (32, 40, 78), "roughness": 0.7},
    "Cover": {"color": (32, 78, 160), "roughness": 0.45},
    "CoverPrint": {"color": (255, 255, 255), "albedo_tex": "textbook_cover", "roughness": 0.45},
    "Pages": {"color": (243, 238, 222), "roughness": 0.9},
    "Fabric": {"color": (255, 255, 255), "albedo_tex": "fabric_red_albedo",
               "normal_tex": "fabric_red_normal", "normal_scale": 0.5, "roughness": 0.9},
    "Webbing": {"color": (30, 30, 34), "roughness": 0.85},
    "Zipper": {"color": (60, 62, 68), "metallic": 0.6, "roughness": 0.45},
    "BottleCream": {"color": (226, 212, 180), "roughness": 0.35},
    "Steel": {"color": (200, 204, 208), "metallic": 0.8, "roughness": 0.3},
    "Basketball": {"color": (255, 255, 255), "albedo_tex": "basketball_albedo",
                   "normal_tex": "basketball_normal", "normal_scale": 0.6, "roughness": 0.75},
    "BinPlastic": {"color": (112, 128, 146), "roughness": 0.55},
    "EraserWood": {"color": (198, 156, 109), "roughness": 0.6},
    "Felt": {"color": (58, 58, 62), "roughness": 1.0},
    "TrayOrange": {"color": (224, 122, 46), "roughness": 0.4},
    "SprayLabel": {"color": (255, 255, 255), "albedo_tex": "spray_label", "roughness": 0.35},
    "CanSteel": {"color": (205, 208, 212), "metallic": 0.85, "roughness": 0.3},
    "NozzleWhite": {"color": (240, 240, 240), "roughness": 0.5},
}


# --------------------------------------------------------------------------
# Items
# --------------------------------------------------------------------------

def build_fire_extinguisher():
    P = parts_for("ExtRed", "ExtLabel", "Chrome", "BlackPlastic", "PinYellow")
    # Body (built along Z = height, then stood up). Origin: the carry handle.
    upright(P["ExtRed"], (0, 0, 0), lambda q: add_lathe(q, [
        (0.060, -0.585), (0.068, -0.575), (0.068, -0.425), (0.068, -0.235), (0.068, -0.16), (0.06, -0.135),
        (0.035, -0.12), (0.02, -0.115)], sides=28, cap_start=True))
    upright(P["ExtLabel"], (0, 0, 0), lambda q: add_lathe(
        q, [(0.0686, -0.42), (0.0686, -0.24)], sides=28, uv_band=(-0.24, -0.42)))
    upright(P["BlackPlastic"], (0, 0, 0), lambda q: add_lathe(
        q, [(0.071, -0.59), (0.071, -0.555), (0.066, -0.55)], sides=28, cap_start=True))  # foot ring
    upright(P["Chrome"], (0, 0, 0), lambda q: add_lathe(
        q, [(0.021, -0.118), (0.021, -0.07), (0.026, -0.065), (0.026, -0.02), (0.018, -0.015)], sides=20,
        cap_end=True))  # neck + valve head
    # Carry handle (lower) and squeeze lever (upper), pointing forward.
    add_box(P["BlackPlastic"], (0, -0.012, -0.055), (0.03, 0.012, 0.13))
    add_box(P["BlackPlastic"], (0, 0.012, -0.05), (0.028, 0.01, 0.12))
    # Pressure gauge on the side.
    add_transformed(P["Chrome"], np.array([[0, 0, 1], [0, 1, 0], [-1, 0, 0]]), (0.026, -0.045, 0.0),
                    lambda q: add_lathe(q, [(0.014, 0.0), (0.014, 0.008)], sides=16, cap_end=True))
    # Safety pin ring.
    add_round_tube_path(P["PinYellow"], [(0.032 + 0.012 * math.cos(a), -0.035 + 0.012 * math.sin(a), 0.01)
                                         for a in np.linspace(0, 2 * math.pi, 14, endpoint=False)],
                        0.0018, sides=6, closed=True)
    # Short hose and horn nozzle pointing -Z.
    add_round_tube_path(P["BlackPlastic"], [(0.026, -0.05, -0.01), (0.04, -0.08, -0.06), (0.03, -0.07, -0.11),
                                            (0.0, -0.05, -0.13)], 0.007, sides=10)
    add_lathe(P["BlackPlastic"], [(0.008, -0.125), (0.012, -0.145), (0.02, -0.17)], sides=14, center=(0.0, -0.05))
    return P


def build_broom():
    P = parts_for("HandleBlue", "BroomRed", "Bristle")
    add_lathe(P["HandleBlue"], [(0.012, 0.6), (0.012, -0.5)], sides=14)
    add_lathe(P["BroomRed"], [(0.0135, 0.64), (0.0135, 0.6)], sides=14, cap_start=True)  # hang cap
    add_box(P["BroomRed"], (0, 0, -0.53), (0.21, 0.045, 0.07))
    add_prism(P["Bristle"], [(-0.095, -0.565), (0.095, -0.565), (0.15, -0.79), (-0.15, -0.79)], -0.013, 0.013)
    shift_parts(P, (0, 0, 0.3))
    return P


def build_umbrella():
    P = parts_for("Chrome", "Canopy", "BlackPlastic")
    add_lathe(P["Chrome"], [(0.006, 0.42), (0.006, -0.47)], sides=10)
    add_lathe(P["Canopy"], [(0.007, 0.29), (0.028, 0.2), (0.035, 0.06), (0.022, -0.22), (0.008, -0.44)],
              sides=8, flat=True, cap_start=True, cap_end=True)
    add_lathe(P["Chrome"], [(0.006, -0.47), (0.002, -0.505)], sides=10)
    add_box(P["Canopy"], (0, 0, -0.05), (0.076, 0.076, 0.03))  # strap
    hook = [(0, 0, 0.40), (0, 0, 0.52)] + [(0, -0.05 + 0.05 * math.cos(a), 0.52 + 0.05 * math.sin(a))
                                           for a in np.linspace(0.15, math.pi, 8)]
    add_round_tube_path(P["BlackPlastic"], hook, 0.012, sides=12)
    shift_parts(P, (0, 0, 0.46))
    return P


def build_textbook():
    P = parts_for("Cover", "CoverPrint", "Pages")
    W, T, L = 0.19, 0.035, 0.26
    add_box(P["Cover"], (0, T / 2 - 0.00125, 0), (W, 0.0025, L))
    add_box(P["Cover"], (0, -T / 2 + 0.00125, 0), (W, 0.0025, L))
    add_box(P["Cover"], (-W / 2 + 0.002, 0, 0), (0.004, T, L))  # spine
    add_box(P["Pages"], (0.0, 0, 0), (W - 0.012, T - 0.004, L - 0.008))
    y = T / 2 + 0.0002
    quad = np.array([(-W / 2, y, -L / 2), (W / 2, y, -L / 2), (W / 2, y, L / 2), (-W / 2, y, L / 2)])
    up = np.tile([0, 1, 0], (4, 1))
    P["CoverPrint"].add(quad, up, [(0, 0), (1, 0), (1, 1), (0, 1)], fix_winding(quad, up, np.array([0, 1, 2, 0, 2, 3])))
    return P


def build_backpack():
    P = parts_for("Fabric", "Webbing", "Zipper")
    R = 0.06
    pillow = [(R * (1 - math.cos(a)), R * (1 + math.sin(a))) for a in np.linspace(-math.pi / 2, math.pi / 2, 9)]
    # Slab built lying down (its Z = the bag's height), then stood up so the
    # front of the bag faces -Z and the back (straps) faces +Z.
    add_transformed(P["Fabric"], UP, (0, 0, 0),
                    lambda q: add_profiled_slab(q, 0.30, 0.40, 0.05, pillow, 0.0, seg=8))
    small = [(0.025 * (1 - math.cos(a)), 0.025 * (1 + math.sin(a))) for a in np.linspace(-math.pi / 2, math.pi / 2, 7)]
    add_transformed(P["Fabric"], UP, (0, -0.07, -0.105),
                    lambda q: add_profiled_slab(q, 0.22, 0.18, 0.03, small, 0.0, seg=6))  # front pocket
    add_box(P["Zipper"], (0, 0.03, -0.122), (0.18, 0.004, 0.004))
    add_box(P["Zipper"], (0, 0.2, -0.06), (0.2, 0.004, 0.004))
    for sx in (-1, 1):
        x = sx * 0.075
        add_round_tube_path(P["Webbing"], [(x, 0.185, -0.01), (x, 0.14, 0.018), (x * 1.15, 0.0, 0.024),
                                           (x * 1.3, -0.12, 0.018), (x * 1.3, -0.17, -0.01)], 0.008, sides=8)
    add_round_tube_path(P["Webbing"], [(-0.04, 0.198, -0.06), (-0.03, 0.233, -0.06), (0.0, 0.243, -0.06),
                                       (0.03, 0.233, -0.06), (0.04, 0.198, -0.06)], 0.007, sides=8)
    shift_parts(P, (0, 0.235, -0.06))  # hold it by the top handle
    return P


def build_water_bottle():
    P = parts_for("BottleCream", "Steel")
    upright(P["BottleCream"], (0, 0, 0), lambda q: add_lathe(
        q, [(0.036, 0.0), (0.042, 0.008), (0.042, 0.19), (0.039, 0.2)], sides=24, cap_start=True))
    upright(P["Steel"], (0, 0, 0), lambda q: add_lathe(q, [(0.0405, 0.2), (0.0405, 0.215)], sides=24))
    upright(P["BottleCream"], (0, 0, 0), lambda q: add_lathe(
        q, [(0.039, 0.215), (0.04, 0.245), (0.033, 0.258), (0.02, 0.261)], sides=24, cap_end=True))
    add_round_tube_path(P["Steel"], [(-0.024, 0.254, 0), (-0.02, 0.284, 0), (0, 0.295, 0), (0.02, 0.284, 0),
                                     (0.024, 0.254, 0)], 0.0035, sides=8)
    add_box(P["Steel"], (0, 0.23, -0.041), (0.016, 0.03, 0.006))  # clasp
    shift_parts(P, (0, 0.13, 0))
    return P


def build_basketball():
    P = parts_for("Basketball")
    r, rings, segs = 0.12, 24, 48
    pos, nrm, uv = [], [], []
    for i in range(rings + 1):
        lat = math.pi * i / rings
        for j in range(segs + 1):
            lon = 2 * math.pi * j / segs
            d = (math.sin(lat) * math.cos(lon), math.cos(lat), math.sin(lat) * math.sin(lon))
            pos.append(np.array(d) * r)
            nrm.append(d)
            uv.append((j / segs, i / rings))
    pos, nrm = np.array(pos), np.array(nrm)
    P["Basketball"].add(pos, nrm, uv, fix_winding(pos, nrm, grid_indices(rings + 1, segs + 1)))
    return P


def build_trash_bin():
    P = parts_for("BinPlastic")
    upright(P["BinPlastic"], (0, 0, 0), lambda q: add_lathe(q, [
        (0.13, 0.0), (0.15, 0.37), (0.158, 0.38), (0.158, 0.4), (0.146, 0.4), (0.128, 0.015), (0.0002, 0.015)],
        sides=28, cap_start=True, profile_normals=True))
    shift_parts(P, (0, 0.2, 0))
    return P


def build_board_eraser():
    P = parts_for("EraserWood", "Felt")
    soft = [(0.004, 0.0), (0.0, 0.004), (0.0, 0.026), (0.006, 0.032)]
    add_profiled_slab(P["EraserWood"], 0.055, 0.15, 0.012, soft, -0.013, seg=5)
    add_box(P["Felt"], (0, -0.016, 0), (0.054, 0.006, 0.148))
    return P


def build_lunch_tray():
    P = parts_for("TrayOrange")
    W, L, t, h = 0.27, 0.36, 0.006, 0.024
    add_box(P["TrayOrange"], (0, 0, 0), (W, 0.004, L))
    for sx in (-1, 1):
        add_box(P["TrayOrange"], (sx * (W / 2 - t / 2), h / 2, 0), (t, h, L))
    for sz in (-1, 1):
        add_box(P["TrayOrange"], (0, h / 2, sz * (L / 2 - t / 2)), (W - 2 * t, h, t))
    add_box(P["TrayOrange"], (0.03, h * 0.4, 0), (0.005, h * 0.8, L - 2 * t))   # long divider
    add_box(P["TrayOrange"], (-0.05, h * 0.4, -0.04), (W / 2 - 0.02, h * 0.8, 0.005))  # small divider
    return P


def build_spray_paint():
    P = parts_for("CanSteel", "SprayLabel", "NozzleWhite", "BlackPlastic")
    h0, h1, r = -0.095, 0.075, 0.033
    upright(P["CanSteel"], (0, 0, 0), lambda q: add_lathe(q, [(0.028, h0), (r, h0 + 0.008)], sides=24, cap_start=True))
    upright(P["SprayLabel"], (0, 0, 0), lambda q: add_lathe(q, [(r, h0 + 0.008), (r, h1)], sides=24,
                                                             uv_band=(h1, h0 + 0.008)))
    upright(P["CanSteel"], (0, 0, 0), lambda q: add_lathe(
        q, [(r, h1), (0.03, 0.088), (0.02, 0.098), (0.012, 0.101), (0.011, 0.104)], sides=24, cap_end=True))
    upright(P["NozzleWhite"], (0, 0, 0), lambda q: add_lathe(q, [(0.0085, 0.104), (0.0085, 0.121)], sides=14,
                                                              cap_end=True))
    add_box(P["BlackPlastic"], (0, 0.113, -0.0085), (0.004, 0.004, 0.002))  # the hole
    return P


# fname, node, builder, mass, settings, kwargs for write_scene
ITEMS = [
    ("fire_extinguisher", "FireExtinguisher", build_fire_extinguisher, 4.0,
     dict(attack_style=1, melee_damage=20.0, melee_range=1.0, attack_cooldown=1.0, melee_knockback=6.0,
          throw_speed=9.0, throw_spin=4.0, throw_damage_per_speed=2.0),
     dict(script="fire_extinguisher.gd", extra_synced=("spray_charge", "spraying"))),
    ("broom", "Broom", build_broom, 0.6,
     dict(attack_style=1, melee_damage=9.0, melee_range=1.7, attack_cooldown=0.7, melee_knockback=3.0,
          throw_speed=12.0, throw_spin=6.0, throw_damage_per_speed=0.6), {}),
    ("umbrella", "Umbrella", build_umbrella, 0.45,
     dict(attack_style=0, melee_damage=11.0, melee_range=1.35, attack_cooldown=0.55, melee_knockback=2.0,
          throw_speed=14.0, throw_spin=0.5, throw_damage_per_speed=0.8), {}),
    ("textbook", "Textbook", build_textbook, 0.9,
     dict(attack_style=1, melee_damage=10.0, melee_range=0.9, attack_cooldown=0.55, melee_knockback=2.0,
          throw_speed=13.0, throw_spin=10.0, throw_damage_per_speed=1.0, flat_spin=True), {}),
    ("backpack", "Backpack", build_backpack, 2.5,
     dict(attack_style=1, melee_damage=13.0, melee_range=1.1, attack_cooldown=0.85, melee_knockback=5.0,
          throw_speed=9.0, throw_spin=3.0, throw_damage_per_speed=1.4), {}),
    ("water_bottle", "WaterBottle", build_water_bottle, 0.5,
     dict(attack_style=1, melee_damage=9.0, melee_range=0.9, attack_cooldown=0.5, melee_knockback=2.0,
          throw_speed=15.0, throw_spin=8.0, throw_damage_per_speed=1.0), {}),
    ("basketball", "Basketball", build_basketball, 0.6,
     dict(attack_style=1, melee_damage=5.0, melee_range=0.9, attack_cooldown=0.5, melee_knockback=3.0,
          throw_speed=16.0, throw_spin=6.0, throw_damage_per_speed=0.9, ccd_in_flight=False),
     dict(shape="sphere", bounce=0.8, friction=0.6)),
    ("trash_bin", "TrashBin", build_trash_bin, 2.0,
     dict(attack_style=1, melee_damage=14.0, melee_range=1.0, attack_cooldown=0.9, melee_knockback=6.0,
          throw_speed=9.0, throw_spin=3.0, throw_damage_per_speed=1.6,
          hold_offset="Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, -0.1, -0.25)"),
     dict(shape="cylinder")),
    ("board_eraser", "BoardEraser", build_board_eraser, 0.12,
     dict(attack_style=1, melee_damage=4.0, melee_range=0.8, attack_cooldown=0.35,
          throw_speed=17.0, throw_spin=8.0, throw_damage_per_speed=0.6), {}),
    ("lunch_tray", "LunchTray", build_lunch_tray, 0.4,
     dict(attack_style=1, melee_damage=10.0, melee_range=1.0, attack_cooldown=0.55, melee_knockback=3.0,
          throw_speed=14.0, throw_spin=14.0, throw_damage_per_speed=0.9, flat_spin=True),
     dict(min_size=0.04)),  # a 2.6 cm light tray sinks into desks with a thinner or bottom-flush box
    ("spray_paint", "SprayPaint", build_spray_paint, 0.4,
     dict(attack_style=1, melee_damage=5.0, melee_range=0.8, attack_cooldown=0.45,
          throw_speed=15.0, throw_spin=8.0, throw_damage_per_speed=0.8),
     dict(script="res://assets/school_items/scripts/spray_paint.gd", extra_synced=("paint", "spraying"))),
]


WEAPON_SCRIPT = "res://assets/stationery/scripts/stationery_weapon.gd"


def main() -> None:
    tex = make_textures()
    (OUT / "models").mkdir(parents=True, exist_ok=True)
    for fname, node, builder, mass, settings, kw in ITEMS:
        parts = {k: v for k, v in builder().items() if v.count}
        write_glb(OUT / "models" / f"{fname}.glb", node, parts, tex, MATS)
        lo, hi = parts_aabb(parts)
        write_scene(fname, node, mass, lo, hi, settings, out=OUT, **{"script": WEAPON_SCRIPT, **kw})
        tris = sum(len(p.arrays()[3]) // 3 for p in parts.values())
        print(f"{fname}.glb: {tris} tris, {np.round((hi - lo) * 100, 1)} cm")


if __name__ == "__main__":
    main()
