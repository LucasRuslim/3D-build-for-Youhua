#!/usr/bin/env python3
"""Builds the archery set: a recurve bow and an arrow (models + Godot scenes).

Outputs (relative to the repo root):
  assets/archery/models/{bow,arrow}.glb
  assets/archery/scenes/{bow,arrow}.tscn

Bow: origin at the grip, held upright (limbs along +-Y), arrows fly along -Z,
the string is on the +Z (archer) side. The string itself is drawn at runtime
by bow.gd so it can be pulled back.
Arrow: origin at the middle of the shaft, tip along -Z, nock at +Z.

  python3 tools/generate_archery.py
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_assets import MeshPart, add_box, catmull_rom, fix_winding, grid_indices, write_glb  # noqa: E402
from generate_stationery import (add_lathe, add_prism, add_transformed, parts_aabb,  # noqa: E402
                                 parts_for, rot_z, write_scene)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "archery"

MATS = {
    "BowWood": {"color": (122, 62, 34), "roughness": 0.35},
    "GripLeather": {"color": (28, 26, 25), "roughness": 0.8},
    "TipIvory": {"color": (236, 228, 208), "roughness": 0.5},
    "ShaftWood": {"color": (201, 163, 107), "roughness": 0.6},
    "PointSteel": {"color": (190, 195, 200), "metallic": 0.8, "roughness": 0.3},
    "NockOrange": {"color": (240, 120, 30), "roughness": 0.4},
    "VaneRed": {"color": (210, 40, 40), "roughness": 0.6, "double_sided": True},
    "VaneWhite": {"color": (240, 240, 236), "roughness": 0.6, "double_sided": True},
}


def add_ellipse_sweep(part: MeshPart, pts, rx, rz, sides=10):
    """Sweep an ellipse along a path lying in the YZ plane. rx is the half
    width along X; rz the half thickness across the path within YZ."""
    pts = np.asarray(pts, float)
    n = len(pts)
    tang = np.gradient(pts, axis=0)
    tang /= np.linalg.norm(tang, axis=1, keepdims=True)
    ux = np.array([1.0, 0.0, 0.0])
    pos, nrm, uv = [], [], []
    for i in range(n):
        v = np.cross(tang[i], ux)
        v /= np.linalg.norm(v)
        for k in range(sides + 1):
            a = 2 * math.pi * k / sides
            c, s = math.cos(a), math.sin(a)
            pos.append(pts[i] + ux * c * rx[i] + v * s * rz[i])
            nn = ux * c / max(rx[i], 1e-6) + v * s / max(rz[i], 1e-6)  # ellipse normal
            nrm.append(nn / np.linalg.norm(nn))
            uv.append((k / sides, i / (n - 1) * 4))
    pos, nrm = np.array(pos), np.array(nrm)
    part.add(pos, nrm, uv, fix_winding(pos, nrm, grid_indices(n, sides + 1)))
    # Close both ends.
    for i, sign in ((0, -1), (n - 1, 1)):
        ring = pos[i * (sides + 1):(i + 1) * (sides + 1) - 1]
        cap = np.vstack([pts[i], ring])
        cn = np.tile(tang[i] * sign, (len(cap), 1))
        idx = []
        for k in range(sides):
            idx += [0, 1 + k, 1 + (k + 1) % sides]
        part.add(cap, cn, np.zeros((len(cap), 2)), fix_winding(cap, cn, np.array(idx)))


def build_bow():
    P = parts_for("BowWood", "GripLeather", "TipIvory")
    # Upper limb profile (y, z); the lower limb mirrors it. The tips curl
    # forward (-Z): a recurve.
    half = [(0.0, 0.0), (0.08, 0.0), (0.2, 0.025), (0.32, 0.06), (0.42, 0.095), (0.5, 0.118),
            (0.545, 0.124), (0.568, 0.108)]
    prof = [(-y, z) for y, z in reversed(half[1:])] + half
    curve = catmull_rom(np.array(prof), 6)
    pts = np.c_[np.zeros(len(curve)), curve[:, 0], curve[:, 1]]
    ay = np.abs(pts[:, 1])
    # Thick riser at the grip, tapering limbs.
    rx = np.interp(ay, [0.0, 0.07, 0.12, 0.3, 0.57], [0.016, 0.016, 0.014, 0.011, 0.006])
    rz = np.interp(ay, [0.0, 0.07, 0.12, 0.2, 0.57], [0.022, 0.022, 0.009, 0.006, 0.004])
    add_ellipse_sweep(P["BowWood"], pts, rx, rz, sides=12)
    # Leather grip wrap.
    g = np.c_[np.zeros(9), np.linspace(-0.06, 0.06, 9), np.zeros(9)]
    add_ellipse_sweep(P["GripLeather"], g, np.full(9, 0.0172), np.full(9, 0.0235), sides=14)
    # String nocks at the tips.
    for sy in (1, -1):
        add_box(P["TipIvory"], (0, sy * 0.552, 0.121), (0.014, 0.012, 0.012))
    # Arrow rest on the left of the riser.
    add_box(P["BowWood"], (0.017, 0.075, 0.0), (0.012, 0.006, 0.02))
    return P


def build_arrow():
    P = parts_for("ShaftWood", "PointSteel", "NockOrange", "VaneRed", "VaneWhite")
    r = 0.0042
    add_lathe(P["ShaftWood"], [(r, 0.335), (r, -0.33)], sides=12)
    add_lathe(P["VaneRed"], [(r * 1.08, 0.18), (r * 1.08, 0.165)], sides=12)  # cresting band
    add_lathe(P["PointSteel"], [(r, -0.33), (r * 1.1, -0.333), (r * 1.1, -0.348), (0.0003, -0.372)], sides=12)
    add_lathe(P["NockOrange"], [(r * 0.95, 0.335), (r * 1.05, 0.34), (r * 0.9, 0.35)], sides=12, cap_end=True)
    vane = [(r, 0.30), (r, 0.19), (0.011, 0.215), (0.0155, 0.265), (0.014, 0.29)]
    for k in range(3):
        mat = "VaneRed" if k == 0 else "VaneWhite"
        add_transformed(P[mat], rot_z(math.pi / 2 + k * 2 * math.pi / 3), (0, 0, 0),
                        lambda q: add_prism(q, vane, -0.0005, 0.0005))
    return P


ITEMS = [
    ("bow", "Bow", "bow.gd", build_bow, 0.9, ("arrow_count", "draw_amount"),
     dict(attack_style=1, melee_damage=9.0, melee_range=1.0, attack_cooldown=0.6, pointy=False,
          throw_speed=10.0, throw_spin=5.0, throw_damage_per_speed=0.8,
          hold_offset="Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -0.25)")),
    ("arrow", "Arrow", "arrow.gd", build_arrow, 0.03, ("bow_state",),
     dict(attack_style=0, melee_damage=8.0, melee_range=0.85, attack_cooldown=0.4, pointy=True,
          throw_speed=16.0, throw_spin=0.3, throw_damage_per_speed=0.8)),
]


def main() -> None:
    (OUT / "models").mkdir(parents=True, exist_ok=True)
    for fname, node, script, builder, mass, synced, settings in ITEMS:
        parts = {k: v for k, v in builder().items() if v.count}
        write_glb(OUT / "models" / f"{fname}.glb", node, parts, {}, MATS)
        lo, hi = parts_aabb(parts)
        write_scene(fname, node, mass, lo, hi, settings, out=OUT, script=script, extra_synced=synced)
        tris = sum(len(p.arrays()[3]) // 3 for p in parts.values())
        print(f"{fname}.glb: {tris} tris, {np.round((hi - lo) * 100, 1)} cm")


if __name__ == "__main__":
    main()
