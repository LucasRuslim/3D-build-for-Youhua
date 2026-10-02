#!/usr/bin/env python3
"""Builds the sports items: ping pong paddle/ball/ball bucket, badminton
racket and shuttlecock (models + Godot scenes).

Outputs (relative to the repo root):
  assets/sports/models/*.glb
  assets/sports/scenes/*.tscn

Paddle/racket: origin at the grip, head straight up (+Y), hitting face
towards -Z. Shuttlecock: cork nose along -Z. Bucket: origin at the handle.

  python3 tools/generate_sports.py
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_assets import add_box, add_round_tube_path, write_glb  # noqa: E402
from generate_stationery import (add_lathe, add_prism, add_transformed, add_uv_sphere, parts_aabb,  # noqa: E402
                                 parts_for, rot_x, shift_parts, write_scene)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "sports"
UP = rot_x(-math.pi / 2)        # lathe along +Z -> along +Y
FACE = rot_x(math.pi / 2)       # prism in XZ (thick along Y) -> in XY (thick along Z)
WEAPON_SCRIPT = "res://assets/stationery/scripts/stationery_weapon.gd"

MATS = {
    "PaddleWood": {"color": (205, 160, 105), "roughness": 0.6},
    "RubberRed": {"color": (200, 30, 35), "roughness": 0.7},
    "RubberBlack": {"color": (25, 25, 28), "roughness": 0.75},
    "GripBlue": {"color": (40, 110, 200), "roughness": 0.8},
    "FrameNavy": {"color": (30, 50, 120), "metallic": 0.3, "roughness": 0.35},
    "ShaftSteel": {"color": (190, 195, 200), "metallic": 0.8, "roughness": 0.3},
    "Strings": {"color": (240, 240, 235), "roughness": 0.6},
    "Cork": {"color": (238, 236, 228), "roughness": 0.7},
    "BandBlue": {"color": (40, 90, 200), "roughness": 0.5},
    "Feather": {"color": (248, 248, 244), "roughness": 0.8, "double_sided": True},
    "Thread": {"color": (60, 60, 70), "roughness": 0.8},
    "BallOrange": {"color": (242, 134, 46), "roughness": 0.35},
    "BucketBlue": {"color": (45, 111, 214), "roughness": 0.45},
    "BlackPlastic": {"color": (28, 28, 30), "roughness": 0.5},
    "BucketBallsOrange": {"color": (242, 134, 46), "roughness": 0.35},
    "BucketBallsWhite": {"color": (245, 245, 242), "roughness": 0.35},
}


def ellipse_xz(rx, rz, n=32):
    return [(rx * math.cos(2 * math.pi * k / n), rz * math.sin(2 * math.pi * k / n)) for k in range(n)]


def build_paddle():
    P = parts_for("PaddleWood", "RubberRed", "RubberBlack")
    blade = ellipse_xz(0.075, 0.079)
    centre = (0, 0.13, 0)
    add_transformed(P["PaddleWood"], FACE, centre, lambda q: add_prism(q, blade, -0.003, 0.003))
    add_transformed(P["RubberRed"], FACE, centre, lambda q: add_prism(q, blade, -0.005, -0.003))  # hits towards -Z
    add_transformed(P["RubberBlack"], FACE, centre, lambda q: add_prism(q, blade, 0.003, 0.005))
    add_transformed(P["PaddleWood"], UP, (0, 0, 0), lambda q: add_lathe(
        q, [(0.012, -0.05), (0.0135, -0.03), (0.012, 0.0), (0.0115, 0.03), (0.016, 0.056)],
        sides=10, cap_start=True))
    return P


def build_racket():
    P = parts_for("GripBlue", "BlackPlastic", "ShaftSteel", "FrameNavy", "Strings")
    add_transformed(P["GripBlue"], UP, (0, 0, 0), lambda q: add_lathe(
        q, [(0.0125, -0.1), (0.0135, -0.095), (0.0135, 0.08), (0.011, 0.1)], sides=12))
    add_transformed(P["BlackPlastic"], UP, (0, 0, 0), lambda q: add_lathe(
        q, [(0.0138, -0.106), (0.0138, -0.099)], sides=12, cap_start=True, cap_end=True))
    add_transformed(P["ShaftSteel"], UP, (0, 0, 0), lambda q: add_lathe(q, [(0.0038, 0.1), (0.0038, 0.40)], sides=8))
    cy, rx, ry = 0.515, 0.098, 0.118
    frame = [(rx * math.cos(a), cy + ry * math.sin(a), 0.0) for a in np.linspace(0, 2 * math.pi, 40, endpoint=False)]
    add_round_tube_path(P["FrameNavy"], frame, 0.0045, sides=8, closed=True)
    for sx in (-1, 1):  # throat
        add_round_tube_path(P["FrameNavy"], [(0, 0.39, 0), (sx * 0.02, 0.402, 0), (sx * 0.035, 0.408, 0)], 0.004, sides=8)
    s = 0.0105
    for x in np.arange(-0.088, 0.0885, s):
        h = ry * math.sqrt(max(1 - (x / rx) ** 2, 0)) - 0.004
        add_box(P["Strings"], (x, cy, 0), (0.0008, 2 * h, 0.0008))
    for y in np.arange(cy - 0.108, cy + 0.1085, s):
        w = rx * math.sqrt(max(1 - ((y - cy) / ry) ** 2, 0)) - 0.004
        add_box(P["Strings"], (0, y, 0), (2 * w, 0.0008, 0.0008))
    return P


def build_shuttlecock():
    P = parts_for("Cork", "BandBlue", "Feather", "Thread")
    add_lathe(P["Cork"], [(0.0002, -0.045), (0.006, -0.0435), (0.0105, -0.039), (0.0125, -0.033), (0.0125, -0.027)],
              sides=16, cap_end=True)
    add_lathe(P["BandBlue"], [(0.0128, -0.0292), (0.0128, -0.026)], sides=16)
    add_lathe(P["Feather"], [(0.0115, -0.027), (0.033, 0.045)], sides=16, flat=True)
    for z in (-0.01, 0.01):
        r = 0.0115 + (z + 0.027) / 0.072 * 0.0215 + 0.0004
        add_lathe(P["Thread"], [(r, z - 0.0015), (r, z + 0.0015)], sides=16)
    shift_parts(P, (0, 0, -0.015))  # balance point is near the heavy cork
    return P


def build_ping_pong_ball():
    P = parts_for("BallOrange")
    add_uv_sphere(P["BallOrange"], 0.02, rings=10, segs=16)
    return P


def build_bucket():
    P = parts_for("BucketBlue", "ShaftSteel", "BlackPlastic", "BucketBallsOrange", "BucketBallsWhite")
    add_transformed(P["BucketBlue"], UP, (0, 0, 0), lambda q: add_lathe(q, [
        (0.095, 0.0), (0.12, 0.2), (0.126, 0.205), (0.126, 0.215), (0.116, 0.215), (0.09, 0.012), (0.0002, 0.012)],
        sides=28, cap_start=True, profile_normals=True))
    handle = [(0.124 * math.cos(a), 0.19 + 0.14 * math.sin(a), 0.0) for a in np.linspace(0, math.pi, 16)]
    add_round_tube_path(P["ShaftSteel"], handle, 0.003, sides=6)
    add_transformed(P["BlackPlastic"], np.array([[0, 0, 1], [0, 1, 0], [-1, 0, 0]]), (0, 0.33, 0),
                    lambda q: add_lathe(q, [(0.008, -0.04), (0.008, 0.04)], sides=10, cap_start=True, cap_end=True))
    rng = np.random.default_rng(7)
    for k in range(30):  # a heap of balls filling the top
        a, rr = rng.uniform(0, 2 * math.pi), 0.1 * math.sqrt(rng.uniform(0, 1))
        y = 0.175 + 0.035 * (1 - (rr / 0.1) ** 2) + rng.uniform(-0.01, 0.01)
        mat = "BucketBallsOrange" if k % 2 else "BucketBallsWhite"
        add_uv_sphere(P[mat], 0.02, (rr * math.cos(a), y, rr * math.sin(a)), rings=6, segs=10)
    shift_parts(P, (0, 0.33, 0))  # carried by the handle
    return P


# fname, node, builder, mass, settings, write_scene kwargs
ITEMS = [
    ("ping_pong_paddle", "PingPongPaddle", build_paddle, 0.18,
     dict(attack_style=1, melee_damage=7.0, melee_range=1.0, attack_cooldown=0.45, melee_knockback=2.0,
          bat_power=16.0, throw_speed=14.0, throw_spin=10.0, throw_damage_per_speed=0.8), {}),
    ("badminton_racket", "BadmintonRacket", build_racket, 0.09,
     dict(attack_style=1, melee_damage=6.0, melee_range=1.25, attack_cooldown=0.45, melee_knockback=2.0,
          bat_power=24.0, throw_speed=14.0, throw_spin=8.0, throw_damage_per_speed=0.6), {}),
    ("shuttlecock", "Shuttlecock", build_shuttlecock, 0.02,
     dict(attack_style=1, melee_damage=1.0, melee_range=0.8, attack_cooldown=0.4, aerodynamic=True,
          linear_damp=1.6, throw_speed=16.0, throw_spin=0.0, throw_damage_per_speed=0.3), {}),
    ("ping_pong_ball", "PingPongBall", build_ping_pong_ball, 0.02,
     dict(attack_style=1, melee_damage=1.0, melee_range=0.8, attack_cooldown=0.4, ccd_always=True,
          throw_speed=18.0, throw_spin=20.0, throw_damage_per_speed=0.15),
     dict(script="res://assets/sports/scripts/ping_pong_ball.gd", extra_synced=("absorbed",),
          shape="sphere", bounce=1.0, friction=0.4)),
    ("ball_bucket", "BallBucket", build_bucket, 1.2,
     dict(attack_style=1, melee_damage=8.0, melee_range=1.0, attack_cooldown=0.8, melee_knockback=3.0,
          throw_speed=10.0, throw_spin=3.0, throw_damage_per_speed=1.0,
          hold_offset="Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -0.3)"),
     dict(script="res://assets/sports/scripts/ball_bucket.gd", extra_synced=("balls",))),
]


def main() -> None:
    (OUT / "models").mkdir(parents=True, exist_ok=True)
    for fname, node, builder, mass, settings, kw in ITEMS:
        parts = {k: v for k, v in builder().items() if v.count}
        write_glb(OUT / "models" / f"{fname}.glb", node, parts, {}, MATS)
        lo, hi = parts_aabb(parts)
        write_scene(fname, node, mass, lo, hi, settings, out=OUT, **{"script": WEAPON_SCRIPT, **kw})
        tris = sum(len(p.arrays()[3]) // 3 for p in parts.values())
        print(f"{fname}.glb: {tris} tris, {np.round((hi - lo) * 100, 1)} cm")


if __name__ == "__main__":
    main()
