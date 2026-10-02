#!/usr/bin/env python3
"""Builds the stationery weapons: models, textures and Godot scenes.

Outputs (relative to the repo root):
  assets/stationery/models/*.glb
  assets/stationery/textures/*.png
  assets/stationery/scenes/*.tscn   (StationeryWeapon rigid bodies)

Convention for every item: metres, +Y up when lying flat on a desk, the grip
is at the origin and the business end (tip / blade / front) points along -Z,
which is the direction a Godot PropHolder aims.

Needs numpy + Pillow and reuses the mesh helpers of generate_assets.py:
  python3 tools/generate_stationery.py
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_assets import (MeshPart, UV_SCALE, add_box, add_profiled_slab, add_round_tube_path,
                             fix_winding, grid_indices, periodic_noise, height_to_normal, write_glb)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "stationery"


# --------------------------------------------------------------------------
# Extra mesh helpers
# --------------------------------------------------------------------------

def rot_x(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def rot_z(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def rot_y(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def add_transformed(part: MeshPart, basis, origin, build) -> None:
    """Run build(tmp_part), then rotate by `basis` and move by `origin`."""
    tmp = MeshPart()
    build(tmp)
    pos, nrm, uv, idx = tmp.arrays()
    pos = pos @ np.asarray(basis, float).T + np.asarray(origin, float)
    nrm = nrm @ np.asarray(basis, float).T
    part.add(pos, nrm, uv, fix_winding(pos, nrm, idx))


def add_lathe(part: MeshPart, profile, sides=16, flat=False, angle0=0.0, cap_start=False, cap_end=False,
              center=(0.0, 0.0), uv_band=None, profile_normals=False):
    """Surface of revolution around the Z axis. profile: [(radius, z), ...].
    uv_band=(z0, z1) maps V to 0-1 over that Z range (for wrap-around labels).
    profile_normals: take normals from the profile's direction instead of
    pointing them outward (needed for double walls, e.g. a bin's inside)."""
    prof = [(max(r, 0.0002), z) for r, z in profile]
    cx, cy = center
    angles = [angle0 + 2 * math.pi * k / sides for k in range(sides + 1)]
    ring = lambda r, z: [(cx + r * math.cos(a), cy + r * math.sin(a), z) for a in angles]
    grid = np.array([ring(r, z) for r, z in prof])  # rows x (sides+1) x 3
    rows = len(prof)
    if flat:
        for i in range(rows - 1):
            for k in range(sides):
                quad = np.array([grid[i, k], grid[i, k + 1], grid[i + 1, k + 1], grid[i + 1, k]])
                n = np.cross(quad[1] - quad[0], quad[3] - quad[0])
                if np.linalg.norm(n) < 1e-12:
                    n = np.cross(quad[2] - quad[1], quad[3] - quad[1])
                mid = quad.mean(axis=0)
                if np.dot(n, mid - np.array([cx, cy, mid[2]])) < 0:
                    n = -n
                uv = [(k / sides, quad[j][2] * UV_SCALE) for j in range(4)]
                part.add(quad, np.tile(n, (4, 1)), uv, fix_winding(quad, np.tile(n, (4, 1)),
                                                                     np.array([0, 1, 2, 0, 2, 3])))
    else:
        du = np.gradient(grid, axis=1)
        dv = np.gradient(grid, axis=0)
        n = np.cross(du, dv)
        radial = grid - np.array([cx, cy, 0.0])
        radial[..., 2] = 0
        flip = (n * radial).sum(axis=2) < 0
        n[flip] = -n[flip]
        n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-12)
        if profile_normals:
            pr = np.array(prof)
            t = np.gradient(pr, axis=0)
            nr, nz = t[:, 1], -t[:, 0]  # tangent turned clockwise in the (r, z) plane
            ln = np.maximum(np.hypot(nr, nz), 1e-12)
            nr, nz = nr / ln, nz / ln
            ang = np.array(angles)
            n = np.stack([nr[:, None] * np.cos(ang)[None, :], nr[:, None] * np.sin(ang)[None, :],
                          np.repeat(nz[:, None], len(ang), axis=1)], axis=-1)
        uv = np.zeros((rows, sides + 1, 2))
        uv[..., 0] = np.arange(sides + 1)[None, :] / sides
        uv[..., 1] = grid[..., 2] * UV_SCALE
        if uv_band is not None:
            uv[..., 1] = (grid[..., 2] - uv_band[0]) / (uv_band[1] - uv_band[0])
        p, nn = grid.reshape(-1, 3), n.reshape(-1, 3)
        part.add(p, nn, uv.reshape(-1, 2), fix_winding(p, nn, grid_indices(rows, sides + 1)))
    for use, i, sign in ((cap_start, 0, 1), (cap_end, rows - 1, -1)):
        if not use:
            continue
        r, z = prof[i]
        other_z = prof[1][1] if i == 0 else prof[-2][1]
        nz = 1.0 if z > other_z else -1.0
        pts = np.array([(cx, cy, z)] + ring(r, z)[:-1])
        nrm = np.tile([0, 0, nz], (len(pts), 1))
        idx = []
        for k in range(sides):
            idx += [0, 1 + k, 1 + (k + 1) % sides]
        part.add(pts, nrm, pts[:, :2] * UV_SCALE, fix_winding(pts, nrm, np.array(idx)))


def add_prism(part: MeshPart, pts2d, y0, y1):
    """Convex polygon given in the XZ plane, extruded between y0 and y1."""
    pts = np.asarray(pts2d, float)
    c = pts.mean(axis=0)
    pts = pts[np.argsort(np.arctan2(pts[:, 1] - c[1], pts[:, 0] - c[0]))]
    n = len(pts)
    for y, ny in ((y1, 1.0), (y0, -1.0)):
        cap = np.c_[pts[:, 0], np.full(n, y), pts[:, 1]]
        cap = np.vstack([[c[0], y, c[1]], cap])
        nrm = np.tile([0, ny, 0], (n + 1, 1))
        idx = []
        for k in range(n):
            idx += [0, 1 + k, 1 + (k + 1) % n]
        part.add(cap, nrm, cap[:, [0, 2]] * UV_SCALE, fix_winding(cap, nrm, np.array(idx)))
    for k in range(n):
        a, b = pts[k], pts[(k + 1) % n]
        edge = b - a
        out = np.array([edge[1], 0, -edge[0]])
        mid = (a + b) / 2
        if np.dot(out[[0, 2]], mid - c) < 0:
            out = -out
        quad = np.array([(a[0], y0, a[1]), (b[0], y0, b[1]), (b[0], y1, b[1]), (a[0], y1, a[1])])
        nrm = np.tile(out / (np.linalg.norm(out) + 1e-12), (4, 1))
        L = np.linalg.norm(edge)
        part.add(quad, nrm, [(0, 0), (L * UV_SCALE, 0), (L * UV_SCALE, 0.01), (0, 0.01)],
                 fix_winding(quad, nrm, np.array([0, 1, 2, 0, 2, 3])))


def ellipse(cx, cz, rx, rz, y, n=20):
    return [(cx + rx * math.cos(2 * math.pi * k / n), y, cz + rz * math.sin(2 * math.pi * k / n)) for k in range(n)]


def shift_parts(parts: dict[str, MeshPart], offset) -> None:
    off = np.asarray(offset, np.float32)
    for p in parts.values():
        p.pos = [a - off for a in p.pos]


def parts_aabb(parts: dict[str, MeshPart]):
    allp = np.concatenate([np.concatenate(p.pos) for p in parts.values() if p.count])
    return allp.min(axis=0), allp.max(axis=0)


# --------------------------------------------------------------------------
# Textures
# --------------------------------------------------------------------------

def make_textures() -> dict[str, Path]:
    tex_dir = OUT / "textures"
    tex_dir.mkdir(parents=True, exist_ok=True)
    paths: dict[str, Path] = {}

    # Ruler print: mm/half-cm/cm ticks and numbers 0-30, transparent background.
    W, H = 4096, 448
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    ruler_len = 0.32
    px_per_m = W / ruler_len
    x0 = 0.01 * px_per_m  # zero mark 1 cm from the end
    font = ImageFont.load_default(size=72)
    ink = (20, 24, 40, 255)
    for mm in range(0, 301):
        x = x0 + mm / 1000 * px_per_m
        h = 150 if mm % 10 == 0 else (105 if mm % 5 == 0 else 65)
        d.rectangle([x - 3, 0, x + 3, h], fill=ink)
        if mm % 10 == 0:
            label = str(mm // 10)
            tw = d.textlength(label, font=font)
            d.text((x - tw / 2, 165), label, font=font, fill=ink)
    d.text((W - 900, 330), "cm  30", font=ImageFont.load_default(size=56), fill=ink)
    p = tex_dir / "ruler_print.png"
    img.save(p, optimize=True)
    paths["ruler_print"] = p

    # Fabric for the navy pencil case (the pouch on the desk in the video).
    s = 512
    yy, xx = np.mgrid[0:s, 0:s]
    weave = (np.sin(xx * 2 * math.pi / 8) * np.sin(yy * 2 * math.pi / 8))
    weave = weave + periodic_noise(s, 1.0, 11) * 0.4
    base = np.array((31, 42, 74), float)
    shade = 1.0 + 0.06 * weave + 0.04 * periodic_noise(s, 20, 12)
    alb = np.clip(base[None, None, :] * shade[..., None], 0, 255).astype(np.uint8)
    p = tex_dir / "fabric_navy_albedo.png"
    Image.fromarray(alb).save(p, optimize=True)
    paths["fabric_navy_albedo"] = p
    p = tex_dir / "fabric_navy_normal.png"
    Image.fromarray(height_to_normal(weave, 0.6)).save(p, optimize=True)
    paths["fabric_navy_normal"] = p
    return paths


# --------------------------------------------------------------------------
# Items
# --------------------------------------------------------------------------

MATS = {
    "PencilYellow": {"color": (242, 193, 46), "roughness": 0.35},
    "Wood": {"color": (221, 185, 138), "roughness": 0.8},
    "Graphite": {"color": (46, 46, 50), "metallic": 0.4, "roughness": 0.35},
    "Ferrule": {"color": (201, 205, 210), "metallic": 0.8, "roughness": 0.3},
    "EraserPink": {"color": (238, 154, 170), "roughness": 0.9},
    "PenWhite": {"color": (236, 240, 244), "roughness": 0.3},
    "PenBlue": {"color": (30, 79, 184), "roughness": 0.45},
    "GripRubber": {"color": (42, 86, 198), "roughness": 0.85},
    "Chrome": {"color": (216, 220, 224), "metallic": 0.8, "roughness": 0.2},
    "Steel": {"color": (201, 206, 212), "metallic": 0.8, "roughness": 0.28},
    "HandleRed": {"color": (211, 58, 58), "roughness": 0.45},
    "BlackPlastic": {"color": (30, 30, 32), "roughness": 0.5},
    "RulerPlastic": {"color": (156, 201, 232), "alpha": 0.55, "roughness": 0.15,
                     "alpha_mode": "BLEND", "double_sided": True},
    "RulerPrint": {"color": (255, 255, 255), "albedo_tex": "ruler_print", "alpha_mode": "MASK",
                   "roughness": 0.5, "double_sided": True},
    "EraserWhite": {"color": (243, 241, 234), "roughness": 0.95},
    "SleeveBlue": {"color": (47, 111, 208), "roughness": 0.6},
    "Fabric": {"color": (255, 255, 255), "albedo_tex": "fabric_navy_albedo",
               "normal_tex": "fabric_navy_normal", "normal_scale": 0.5, "roughness": 0.9},
    "ZipperGrey": {"color": (60, 62, 68), "metallic": 0.6, "roughness": 0.45},
    "LogoWhite": {"color": (235, 235, 235), "roughness": 0.6},
}


def parts_for(*names):
    return {n: MeshPart() for n in names}


def build_pencil():
    P = parts_for("PencilYellow", "Wood", "Graphite", "Ferrule", "EraserPink")
    r = 0.0040  # hexagon corner radius (7 mm across the flats)
    hexa = dict(sides=6, flat=True, angle0=math.pi / 6)
    add_lathe(P["PencilYellow"], [(r, 0.075), (r, -0.075)], **hexa)
    add_lathe(P["Wood"], [(r, -0.075), (0.0013, -0.093)], **hexa)  # sharpened cone
    add_lathe(P["Graphite"], [(0.0013, -0.093), (0.0002, -0.098)], sides=12)
    add_lathe(P["Ferrule"], [(r * 0.98, 0.087), (r * 1.02, 0.086), (r * 1.02, 0.076), (r * 0.98, 0.075)], sides=16)
    add_lathe(P["EraserPink"], [(r * 0.9, 0.0870), (r * 0.9, 0.094), (r * 0.6, 0.0955)], sides=16, cap_end=True)
    shift_parts(P, (0, 0, 0.035))  # hold it near the back third
    return P


def build_pen():
    P = parts_for("PenWhite", "PenBlue", "GripRubber", "Chrome")
    r = 0.0045
    add_lathe(P["PenBlue"], [(r * 0.95, 0.073), (r, 0.071), (r, 0.064)], sides=20, cap_start=True)
    add_lathe(P["PenWhite"], [(r, 0.064), (r, -0.040)], sides=20)
    add_lathe(P["GripRubber"], [(r, -0.040), (r * 1.1, -0.045), (r * 1.1, -0.058), (r * 0.95, -0.060)], sides=20)
    add_lathe(P["PenWhite"], [(r * 0.95, -0.060), (0.0013, -0.070)], sides=20)
    add_lathe(P["Chrome"], [(0.0013, -0.070), (0.0005, -0.0735)], sides=12)
    # Pocket clip.
    add_box(P["PenBlue"], (0, r + 0.0012, 0.052), (0.0032, 0.0012, 0.036))
    add_box(P["PenBlue"], (0, r + 0.0006, 0.068), (0.0032, 0.0022, 0.004))
    shift_parts(P, (0, 0, 0.03))
    return P


def build_ruler():
    P = parts_for("RulerPlastic", "RulerPrint")
    L, W, T = 0.32, 0.035, 0.003
    add_box(P["RulerPlastic"], (0, 0, 0), (W, T, L))
    # Printed scale on top: one quad mapped 0-1 along the length.
    y = T / 2 + 0.0002
    quad = np.array([(-W / 2, y, L / 2), (-W / 2, y, -L / 2), (W / 2, y, -L / 2), (W / 2, y, L / 2)])
    up = np.tile([0, 1, 0], (4, 1))
    P["RulerPrint"].add(quad, up, [(0, 0), (1, 0), (1, 1), (0, 1)], fix_winding(quad, up, np.array([0, 1, 2, 0, 2, 3])))
    shift_parts(P, (0, 0, 0.12))  # grip near one end, the long part sticks out forward
    return P


def build_scissors():
    P = parts_for("Steel", "HandleRed")
    t = 0.0016
    # Two closed blades meeting at the tip (-Z), pivot at z = -0.015.
    add_prism(P["Steel"], [(0.0, -0.012), (0.0075, -0.03), (0.0035, -0.10), (0.0, -0.115), (-0.002, -0.06),
                           (-0.003, -0.012)], 0.0005, 0.0005 + t)
    add_prism(P["Steel"], [(0.0, -0.012), (-0.0075, -0.03), (-0.0035, -0.10), (0.0, -0.115), (0.002, -0.06),
                           (0.003, -0.012)], -0.0005 - t, -0.0005)
    # Shanks from the pivot back to the handles.
    add_box(P["Steel"], (0.006, 0.0005 + t / 2, 0.0), (0.006, t, 0.03))
    add_box(P["Steel"], (-0.006, -0.0005 - t / 2, 0.0), (0.006, t, 0.03))
    # Pivot screw.
    add_transformed(P["Steel"], rot_x(math.pi / 2), (0, 0, -0.015),
                    lambda q: add_lathe(q, [(0.0035, -0.0035), (0.0035, 0.0035)], sides=16, cap_start=True, cap_end=True))
    # Plastic handle loops + sleeves over the shanks.
    add_round_tube_path(P["HandleRed"], ellipse(0.017, 0.040, 0.013, 0.021, 0.0012), 0.0042, sides=10, closed=True)
    add_round_tube_path(P["HandleRed"], ellipse(-0.015, 0.036, 0.011, 0.017, -0.0012), 0.0042, sides=10, closed=True)
    add_box(P["HandleRed"], (0.008, 0.0012, 0.012), (0.009, 0.0075, 0.016))
    add_box(P["HandleRed"], (-0.008, -0.0012, 0.012), (0.009, 0.0075, 0.016))
    shift_parts(P, (0, 0, 0.03))
    return P


def build_compass():
    P = parts_for("Chrome", "BlackPlastic", "Graphite")
    # Hinge head across X with a knurled handle knob behind it.
    add_transformed(P["Chrome"], rot_y(math.pi / 2), (0, 0, 0),
                    lambda q: add_lathe(q, [(0.0075, -0.009), (0.0075, 0.009)], sides=20, cap_start=True, cap_end=True))
    add_lathe(P["BlackPlastic"], [(0.0035, 0.004), (0.0035, 0.024), (0.0025, 0.026)], sides=16, cap_end=True)
    # Needle leg and pencil-holder leg, slightly apart like a closed compass.
    add_round_tube_path(P["Chrome"], [(0.004, 0, -0.004), (0.006, 0, -0.118)], 0.0028, sides=10)
    add_round_tube_path(P["Chrome"], [(-0.004, 0, -0.004), (-0.011, 0, -0.100)], 0.0028, sides=10)
    add_lathe(P["Chrome"], [(0.0012, -0.118), (0.0001, -0.134)], sides=10, center=(0.006, 0.0))  # needle
    add_lathe(P["Chrome"], [(0.0042, -0.098), (0.0042, -0.110)], sides=14, center=(-0.011, 0.0),
              cap_start=True, cap_end=True)  # lead clamp
    add_lathe(P["Graphite"], [(0.0011, -0.110), (0.0011, -0.118), (0.0002, -0.121)], sides=10, center=(-0.011, 0.0))
    shift_parts(P, (0, 0, 0.012))
    return P


def build_stapler():
    P = parts_for("BlackPlastic", "Chrome")
    soft = [(0.004, 0.0), (0.0, 0.003), (0.0, 0.007), (0.003, 0.011)]
    add_profiled_slab(P["BlackPlastic"], 0.038, 0.155, 0.012, soft, 0.0, seg=6)
    add_box(P["Chrome"], (0, 0.0118, -0.058), (0.026, 0.0012, 0.028))  # anvil
    add_box(P["Chrome"], (0, 0.0135, -0.004), (0.022, 0.006, 0.13))  # staple magazine
    arm = [(0.005, 0.0), (0.0, 0.005), (0.0, 0.014), (0.006, 0.021)]
    add_profiled_slab(P["BlackPlastic"], 0.034, 0.142, 0.01, arm, 0.0165, seg=6)
    add_transformed(P["Chrome"], rot_y(math.pi / 2), (0, 0.016, 0.07),
                    lambda q: add_lathe(q, [(0.0035, -0.02), (0.0035, 0.02)], sides=12, cap_start=True, cap_end=True))
    shift_parts(P, (0, 0.019, 0.04))
    return P


def build_eraser():
    P = parts_for("EraserWhite", "SleeveBlue")
    soft = [(0.0015, 0.0), (0.0, 0.0015), (0.0, 0.0105), (0.0015, 0.012)]
    add_profiled_slab(P["EraserWhite"], 0.022, 0.045, 0.004, soft, -0.006, seg=4)
    add_box(P["SleeveBlue"], (0, 0, 0.004), (0.0232, 0.0128, 0.026))
    return P


def build_pencil_case():
    P = parts_for("Fabric", "ZipperGrey", "LogoWhite")
    h, R = 0.05, 0.025
    pillow = [(R * (1 - math.cos(a)), R * (1 + math.sin(a))) for a in np.linspace(-math.pi / 2, math.pi / 2, 9)]
    add_profiled_slab(P["Fabric"], 0.075, 0.205, 0.03, pillow, -h / 2, seg=8)
    add_box(P["ZipperGrey"], (0, h / 2 + 0.0008, 0.0), (0.008, 0.002, 0.15))  # zipper teeth
    add_box(P["ZipperGrey"], (0, h / 2 + 0.0025, -0.06), (0.007, 0.004, 0.012))  # slider
    add_round_tube_path(P["ZipperGrey"], ellipse(0.0, -0.075, 0.004, 0.009, h / 2 + 0.003), 0.0012, sides=6,
                        closed=True)  # pull ring
    # White triangle logo on the side, like the one on the pouch in the video.
    add_transformed(P["LogoWhite"], rot_z(-math.pi / 2), (0.0373, 0.0, 0.05),
                    lambda q: add_prism(q, [(-0.006, -0.007), (0.0, 0.009), (0.006, -0.007)], 0.0, 0.0008))
    return P


# name, builder, mass (kg), weapon settings
ITEMS = [
    ("pencil", "Pencil", build_pencil, 0.05,
     dict(attack_style=0, melee_damage=12.0, melee_range=0.8, attack_cooldown=0.4, pointy=True,
          throw_speed=18.0, throw_spin=0.3, throw_damage_per_speed=1.0)),
    ("ballpoint_pen", "BallpointPen", build_pen, 0.05,
     dict(attack_style=0, melee_damage=10.0, melee_range=0.8, attack_cooldown=0.4, pointy=True,
          throw_speed=18.0, throw_spin=0.3, throw_damage_per_speed=0.9)),
    ("ruler", "Ruler", build_ruler, 0.08,
     dict(attack_style=1, melee_damage=8.0, melee_range=1.0, attack_cooldown=0.5, pointy=False,
          throw_speed=14.0, throw_spin=14.0, throw_damage_per_speed=0.7)),
    ("scissors", "Scissors", build_scissors, 0.15,
     dict(attack_style=0, melee_damage=18.0, melee_range=0.85, attack_cooldown=0.55, pointy=True,
          throw_speed=15.0, throw_spin=0.3, throw_damage_per_speed=1.2)),
    ("compass", "Compass", build_compass, 0.12,
     dict(attack_style=0, melee_damage=15.0, melee_range=0.85, attack_cooldown=0.5, pointy=True,
          throw_speed=16.0, throw_spin=0.3, throw_damage_per_speed=1.1)),
    ("stapler", "Stapler", build_stapler, 0.6,
     dict(attack_style=1, melee_damage=16.0, melee_range=0.9, attack_cooldown=0.7, pointy=False,
          throw_speed=12.0, throw_spin=6.0, throw_damage_per_speed=1.4)),
    ("eraser", "Eraser", build_eraser, 0.05,
     dict(attack_style=1, melee_damage=4.0, melee_range=0.8, attack_cooldown=0.35, pointy=False,
          throw_speed=16.0, throw_spin=8.0, throw_damage_per_speed=0.6)),
    ("pencil_case", "PencilCase", build_pencil_case, 0.35,
     dict(attack_style=1, melee_damage=7.0, melee_range=1.0, attack_cooldown=0.6, pointy=False,
          throw_speed=12.0, throw_spin=5.0, throw_damage_per_speed=0.8)),
]


def write_scene(fname: str, node: str, mass: float, lo, hi, settings: dict, out: Path = OUT,
                script: str = "stationery_weapon.gd", extra_synced: tuple = (), shape: str = "box",
                friction: float = 0.7, bounce: float = 0.2, min_size: float = 0.016,
                pad_up: bool = False) -> None:
    """Write a StationeryWeapon-style rigid body scene into out/scenes/.
    shape: "box" (fits the mesh bounds), "sphere", or "cylinder" (along Y).
    Box sides thinner than min_size are padded (thin, light boxes are unstable
    in Godot physics); pad_up grows a thin Y side upwards from the bottom so
    the item still sits flush on surfaces."""
    res = "res://" + out.relative_to(ROOT).as_posix()
    script_path = script if script.startswith("res://") else f"{res}/scripts/{script}"
    size = np.maximum(hi - lo, min_size)
    centre = (hi + lo) / 2
    if pad_up:
        centre[1] = lo[1] + size[1] / 2
    f = lambda v: f"{v + 0.0:.5g}"
    lines = [
        "[gd_scene load_steps=6 format=3]",
        "",
        f'[ext_resource type="Script" path="{script_path}" id="1_script"]',
        f'[ext_resource type="PackedScene" path="{res}/models/{fname}.glb" id="2_model"]',
        "",
        '[sub_resource type="PhysicsMaterial" id="PhysicsMaterial_item"]',
        f"friction = {friction}",
        f"bounce = {bounce}",
        "",
    ]
    if shape == "sphere":
        lines += ['[sub_resource type="SphereShape3D" id="BoxShape3D_item"]', f"radius = {f(size.max() / 2)}", ""]
    elif shape == "cylinder":
        lines += ['[sub_resource type="CylinderShape3D" id="BoxShape3D_item"]', f"height = {f(size[1])}",
                  f"radius = {f(max(size[0], size[2]) / 2)}", ""]
    else:
        lines += ['[sub_resource type="BoxShape3D" id="BoxShape3D_item"]',
                  f"size = Vector3({f(size[0])}, {f(size[1])}, {f(size[2])})", ""]
    lines += [
        '[sub_resource type="SceneReplicationConfig" id="SceneReplicationConfig_item"]',
    ]
    for i, p in enumerate(["net_position", "net_rotation", "net_linear_velocity", "holder_peer_id", *extra_synced]):
        lines += [f'properties/{i}/path = NodePath(".:{p}")', f"properties/{i}/spawn = true",
                  f"properties/{i}/replication_mode = 2"]
    lines += [
        "",
        f'[node name="{node}" type="RigidBody3D"]',
        f"mass = {mass}",
        'physics_material_override = SubResource("PhysicsMaterial_item")',
        "continuous_cd = false",  # switched on in flight by the script
        "contact_monitor = true",
        "max_contacts_reported = 4",
        'script = ExtResource("1_script")',
        "max_pickup_distance = 1.5",
        "damage_min_speed = 3.0",
    ]
    for k, v in settings.items():
        lines.append(f"{k} = {str(v).lower() if isinstance(v, bool) else v}")
    lines += [
        "",
        '[node name="Model" parent="." instance=ExtResource("2_model")]',
        "",
        '[node name="Collision" type="CollisionShape3D" parent="."]',
        f"transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, {f(centre[0])}, {f(centre[1])}, {f(centre[2])})",
        'shape = SubResource("BoxShape3D_item")',
        "",
        '[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="."]',
        "replication_interval = 0.033",
        "delta_interval = 0.033",
        'replication_config = SubResource("SceneReplicationConfig_item")',
        "",
    ]
    (out / "scenes").mkdir(parents=True, exist_ok=True)
    (out / "scenes" / f"{fname}.tscn").write_text("\n".join(lines))


def main() -> None:
    tex = make_textures()
    (OUT / "models").mkdir(parents=True, exist_ok=True)
    (OUT / "scenes").mkdir(parents=True, exist_ok=True)
    for fname, node, builder, mass, settings in ITEMS:
        parts = {k: v for k, v in builder().items() if v.count}
        write_glb(OUT / "models" / f"{fname}.glb", node, parts, tex, MATS)
        lo, hi = parts_aabb(parts)
        write_scene(fname, node, mass, lo, hi, settings)
        tris = sum(len(p.arrays()[3]) // 3 for p in parts.values())
        print(f"{fname}.glb: {tris} tris, {np.round((hi - lo) * 100, 1)} cm")


if __name__ == "__main__":
    main()
