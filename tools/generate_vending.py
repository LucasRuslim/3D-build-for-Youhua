#!/usr/bin/env python3
"""Builds the vending machine and the drinks it sells (models, textures,
Godot scenes).

Outputs (relative to the repo root):
  assets/vending/models/*.glb
  assets/vending/textures/*.png
  assets/vending/scenes/*.tscn

The machine is a generic drinks machine in the style of the reference photo
(white cabinet, big glass front with stocked shelves, payment panel on the
right, pickup tray at the bottom, lit sign on top). It deliberately carries
no real store's name, logo or colour stripes.

Drinks: origin in the middle, upright (+Y). Machine: origin on the floor
under its middle, front towards +Z.

  python3 tools/generate_vending.py
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_assets import MeshPart, add_box, fix_winding, write_glb  # noqa: E402
from generate_stationery import (add_lathe, add_transformed, parts_aabb, parts_for, rot_x,  # noqa: E402
                                 shift_parts, write_scene)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "vending"
UP = rot_x(-math.pi / 2)
RES = "res://assets/vending"


def font(size):
    return ImageFont.load_default(size=size)


# --------------------------------------------------------------------------
# Drinks
# --------------------------------------------------------------------------

# key, node name, label text, label colour, text colour, container, liquid colour, cap colour,
# drink settings, weight in the machine
DRINKS = [
    ("water_bottle_plastic", "PlasticWaterBottle", "WATER", (235, 245, 252), (30, 110, 200), "pet",
     (150, 205, 245), (40, 110, 220),
     dict(heal_amount=15.0, makes_puddle=True), 4.0),
    ("potion_health", "HealthPotion", "HP+", (210, 30, 40), (255, 255, 255), "sport",
     (220, 40, 50), (240, 240, 240),
     dict(heal_amount=50.0, splash_heal=25.0), 2.0),
    ("potion_speed", "SpeedPotion", "ZOOM!", (250, 210, 30), (30, 30, 30), "can",
     None, None,
     dict(effect='&"speed"', effect_duration=8.0, effect_strength=1.6,
          splash_effect='&"speed"', splash_duration=4.0, splash_strength=1.6), 1.5),
    ("potion_strength", "StrengthPotion", "POWER", (245, 125, 30), (255, 255, 255), "pet",
     (250, 140, 40), (30, 30, 30),
     dict(effect='&"strength"', effect_duration=10.0, effect_strength=1.5,
          splash_effect='&"strength"', splash_duration=5.0, splash_strength=1.5), 1.2),
    ("potion_shield", "ShieldPotion", "GUARD", (40, 90, 210), (255, 255, 255), "can",
     None, None,
     dict(effect='&"shield"', effect_duration=10.0, effect_strength=0.5,
          splash_effect='&"shield"', splash_duration=5.0, splash_strength=0.5), 1.2),
    ("potion_sleep", "SleepPotion", "DREAM", (120, 70, 170), (255, 240, 200), "wide",
     (200, 170, 140), (120, 70, 170),
     dict(effect='&"sleep"', effect_duration=4.0, splash_effect='&"sleep"', splash_duration=3.0), 1.0),
    ("potion_jump", "JumpPotion", "HOP!", (60, 175, 75), (255, 255, 255), "pet",
     (120, 210, 90), (240, 240, 240),
     dict(effect='&"jump"', effect_duration=10.0, effect_strength=1.5,
          splash_effect='&"jump"', splash_duration=5.0, splash_strength=1.5), 1.2),
]


def make_label(key, text, bg, fg) -> Image.Image:
    w, h = 1024, 224
    img = Image.new("RGB", (w, h), bg)
    d = ImageDraw.Draw(img)
    f = font(58)
    # Printed four times around, so a whole word faces you from any side.
    for cx in (w * 0.125, w * 0.375, w * 0.625, w * 0.875):
        tw = d.textlength(text, font=f)
        d.text((cx - tw / 2, h / 2 - 56), text, font=f, fill=fg)
        y = h / 2 + 42
        if key == "potion_health":  # a cross
            d.rectangle([cx - 9, y - 22, cx + 9, y + 22], fill=fg)
            d.rectangle([cx - 22, y - 9, cx + 22, y + 9], fill=fg)
        elif key == "potion_speed":  # lightning bolt
            d.polygon([(cx + 8, y - 26), (cx - 14, y + 4), (cx, y + 4), (cx - 8, y + 28), (cx + 14, y - 4),
                       (cx, y - 4)], fill=(220, 40, 30))
        elif key == "potion_shield":
            d.polygon([(cx - 18, y - 22), (cx + 18, y - 22), (cx + 18, y + 2), (cx, y + 24), (cx - 18, y + 2)],
                      fill=fg)
        elif key == "potion_sleep":
            d.text((cx - 20, y - 26), "z Z", font=font(34), fill=fg)
        elif key == "potion_jump":
            d.polygon([(cx, y - 26), (cx + 20, y - 2), (cx + 8, y - 2), (cx + 8, y + 24), (cx - 8, y + 24),
                       (cx - 8, y - 2), (cx - 20, y - 2)], fill=fg)
        elif key == "potion_strength":
            d.ellipse([cx - 20, y - 20, cx + 20, y + 20], outline=fg, width=7)
        else:  # water: waves
            for k in range(2):
                d.arc([cx - 30, y - 18 + k * 14, cx, y + 2 + k * 14], 200, 340, fill=fg, width=5)
                d.arc([cx, y - 18 + k * 14, cx + 30, y + 2 + k * 14], 200, 340, fill=fg, width=5)
    return img


def drink_mats(key, label_tex, liquid, cap):
    m = {
        "BottlePlastic": {"color": (225, 238, 248), "alpha": 0.28, "alpha_mode": "BLEND", "roughness": 0.05},
        "Label": {"color": (255, 255, 255), "albedo_tex": label_tex, "roughness": 0.35},
        "CanMetal": {"color": (205, 208, 212), "metallic": 0.85, "roughness": 0.3},
    }
    if liquid:
        m["Liquid"] = {"color": liquid, "alpha": 0.88, "alpha_mode": "BLEND", "roughness": 0.1}
    if cap:
        m["Cap"] = {"color": cap, "roughness": 0.45}
    return m


def build_drink(kind):
    P = parts_for("BottlePlastic", "Liquid", "Label", "Cap", "CanMetal")

    def upright(name, prof, **kw):
        add_transformed(P[name], UP, (0, 0, 0), lambda q: add_lathe(q, prof, **kw))

    if kind == "can":
        r, h = 0.0325, 0.121
        upright("CanMetal", [(0.026, 0.0), (r, 0.012)], sides=24, cap_start=True)
        upright("Label", [(r, 0.012), (r, 0.104)], sides=24, uv_band=(0.104, 0.012))
        upright("CanMetal", [(r, 0.104), (0.027, 0.118), (0.026, h)], sides=24, cap_end=True)
        add_box(P["CanMetal"], (0, h + 0.001, 0.008), (0.012, 0.002, 0.018))  # pull tab
        shift_parts(P, (0, h / 2, 0))
        return P
    if kind == "wide":  # milk-tea style bottle
        r, h, neck = 0.037, 0.16, 0.018
    elif kind == "sport":
        r, h, neck = 0.031, 0.21, 0.016
    else:  # "pet": a plain plastic water bottle
        r, h, neck = 0.033, 0.21, 0.0125
    body = [(r * 0.93, 0.0), (r, 0.01), (r, 0.5 * h), (r * 0.94, 0.56 * h), (r, 0.62 * h), (r, 0.76 * h),
            (r * 0.62, 0.88 * h), (neck, 0.95 * h), (neck, h)]
    upright("BottlePlastic", body, sides=20, cap_start=True)
    upright("Liquid", [(r * 0.93, 0.006), (r * 0.93, 0.74 * h)], sides=20, cap_start=True, cap_end=True)
    upright("Label", [(r * 1.006, 0.28 * h), (r * 1.006, 0.6 * h)], sides=20, uv_band=(0.6 * h, 0.28 * h))
    cap_r = neck + 0.002
    if kind == "sport":  # pull-up sports cap
        upright("Cap", [(cap_r, h - 0.002), (cap_r, h + 0.014), (0.008, h + 0.018), (0.008, h + 0.03)],
                sides=16, cap_end=True)
    else:
        upright("Cap", [(cap_r, h - 0.002), (cap_r, h + 0.016)], sides=16, cap_end=True)
    shift_parts(P, (0, h / 2, 0))
    return P


# --------------------------------------------------------------------------
# Vending machine
# --------------------------------------------------------------------------

W, D, H, SIGN_H = 0.95, 0.80, 1.80, 0.22
WIN_X0, WIN_X1, WIN_Y0, WIN_Y1 = -0.44, 0.17, 0.56, 1.66
FZ = D / 2  # front face


def make_machine_textures(tex_dir: Path) -> dict[str, Path]:
    paths = {}
    # Generic lit sign: no store name, logo or stripes from the photo.
    img = Image.new("RGB", (1024, 236), (250, 250, 248))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 1024, 26], fill=(20, 150, 170))
    d.rectangle([0, 210, 1024, 236], fill=(20, 150, 170))
    f = font(92)
    t = "SNACKS & DRINKS"
    d.text((512 - d.textlength(t, font=f) / 2, 66), t, font=f, fill=(25, 60, 120))
    p = tex_dir / "machine_sign.png"
    img.save(p, optimize=True)
    paths["machine_sign"] = p
    # Promo sticker on the payment panel (yellow/orange like the photo's).
    img = Image.new("RGB", (256, 384), (250, 200, 50))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 250, 256, 384], fill=(240, 120, 40))
    for i, line in enumerate(["ICE", "COLD"]):
        d.text((128 - d.textlength(line, font=font(64)) / 2, 30 + i * 74), line, font=font(64), fill=(200, 30, 30))
    for i, line in enumerate(["PRESS USE", "TO BUY"]):
        d.text((128 - d.textlength(line, font=font(34)) / 2, 268 + i * 44), line, font=font(34),
               fill=(255, 255, 255))
    p = tex_dir / "machine_promo.png"
    img.save(p, optimize=True)
    paths["machine_promo"] = p
    return paths


MACHINE_MATS = {
    "CabinetWhite": {"color": (240, 240, 236), "roughness": 0.35},
    "PlinthGrey": {"color": (90, 92, 96), "roughness": 0.6},
    "Glass": {"color": (200, 225, 235), "alpha": 0.16, "alpha_mode": "BLEND", "roughness": 0.02,
              "double_sided": True},
    "InteriorGrey": {"color": (210, 212, 214), "roughness": 0.6},
    "LightStrip": {"color": (255, 255, 250), "emissive": (255, 255, 245)},
    "ShelfSteel": {"color": (170, 174, 180), "metallic": 0.7, "roughness": 0.35},
    "PriceRail": {"color": (250, 210, 60), "roughness": 0.5},
    "Sign": {"color": (255, 255, 255), "albedo_tex": "machine_sign", "emissive": (80, 80, 80),
             "emissive_tex": "machine_sign", "roughness": 0.4},
    "Promo": {"color": (255, 255, 255), "albedo_tex": "machine_promo", "roughness": 0.45},
    "ScreenBlue": {"color": (20, 40, 70), "emissive": (30, 70, 130), "roughness": 0.1},
    "KeyGrey": {"color": (200, 202, 206), "metallic": 0.5, "roughness": 0.35},
    "Black": {"color": (25, 25, 28), "roughness": 0.5},
    "Chrome": {"color": (216, 220, 224), "metallic": 0.8, "roughness": 0.2},
    "TrayDark": {"color": (30, 32, 36), "roughness": 0.7},
    **{f"Prod{i}": {"color": c, "roughness": 0.4} for i, c in enumerate([
        (220, 40, 50), (40, 110, 220), (250, 210, 30), (60, 175, 75), (245, 125, 30), (235, 235, 235),
        (120, 70, 170), (30, 30, 30)])},
}


def quad(part, corners, uvs):
    corners = np.asarray(corners, float)
    n = np.cross(corners[1] - corners[0], corners[3] - corners[0])
    n = np.tile(n / np.linalg.norm(n), (4, 1))
    part.add(corners, n, uvs, fix_winding(corners, n, np.array([0, 1, 2, 0, 2, 3])))


def build_machine():
    P = {k: MeshPart() for k in MACHINE_MATS}
    w = P["CabinetWhite"]
    t = 0.03
    # Cabinet shell.
    add_box(P["PlinthGrey"], (0, 0.03, -0.01), (W - 0.04, 0.06, D - 0.04))
    add_box(w, (-W / 2 + t / 2, H / 2 + 0.03, 0), (t, H - 0.06, D))
    add_box(w, (W / 2 - t / 2, H / 2 + 0.03, 0), (t, H - 0.06, D))
    add_box(w, (0, H - t / 2, 0), (W, t, D))
    add_box(w, (0, H / 2 + 0.03, -D / 2 + t / 2), (W - 2 * t, H - 0.06, t))
    # Front: frame around the window, payment panel on the right, lower panel.
    fz = FZ - t / 2
    add_box(w, ((-W / 2 + t + WIN_X0) / 2, (WIN_Y0 + WIN_Y1) / 2, fz), (WIN_X0 - (-W / 2 + t), WIN_Y1 - WIN_Y0, t))
    add_box(w, ((WIN_X1 + W / 2 - t) / 2, (0.06 + H - t) / 2, fz), (W / 2 - t - WIN_X1, H - t - 0.06, t))
    add_box(w, ((-W / 2 + t + WIN_X1) / 2, (WIN_Y1 + H - t) / 2, fz), (WIN_X1 + W / 2 - t, H - t - WIN_Y1, t))
    add_box(w, ((-W / 2 + t + WIN_X1) / 2, (0.06 + WIN_Y0) / 2, fz), (WIN_X1 + W / 2 - t, WIN_Y0 - 0.06, t))
    # Glass and the lit interior.
    add_box(P["Glass"], ((WIN_X0 + WIN_X1) / 2, (WIN_Y0 + WIN_Y1) / 2, FZ - 0.022),
            (WIN_X1 - WIN_X0, WIN_Y1 - WIN_Y0, 0.005))
    add_box(P["InteriorGrey"], ((WIN_X0 + WIN_X1) / 2, (WIN_Y0 + WIN_Y1) / 2, -D / 2 + t + 0.01),
            (WIN_X1 - WIN_X0, WIN_Y1 - WIN_Y0, 0.02))
    add_box(P["LightStrip"], ((WIN_X0 + WIN_X1) / 2, WIN_Y1 - 0.012, FZ - 0.06), (WIN_X1 - WIN_X0 - 0.02, 0.01, 0.02))
    # Shelves stocked like the photo: snacks on top, cans in the middle,
    # bottles at the bottom.
    rng = np.random.default_rng(11)
    shelf_ys = [0.585 + k * 0.178 for k in range(6)]
    xs = np.linspace(WIN_X0 + 0.045, WIN_X1 - 0.045, 7)
    for k, sy in enumerate(shelf_ys):
        add_box(P["ShelfSteel"], ((WIN_X0 + WIN_X1) / 2, sy, 0.0), (WIN_X1 - WIN_X0 - 0.01, 0.008, D - 0.12))
        add_box(P["PriceRail"], ((WIN_X0 + WIN_X1) / 2, sy + 0.004, FZ - 0.065), (WIN_X1 - WIN_X0 - 0.01, 0.022, 0.004))
        for row, z in enumerate((FZ - 0.14, FZ - 0.30)):
            for x in xs:
                m = P[f"Prod{rng.integers(0, 8)}"]
                if k <= 1:     # bottles
                    hgt = 0.15
                    add_transformed(m, UP, (x, sy + 0.004, z), lambda q, h=hgt: add_lathe(
                        q, [(0.026, 0.0), (0.028, 0.01), (0.028, 0.6 * h), (0.012, 0.85 * h), (0.012, h)],
                        sides=8, cap_start=True, cap_end=True))
                elif k <= 3:   # cans
                    add_transformed(m, UP, (x, sy + 0.004, z), lambda q: add_lathe(
                        q, [(0.03, 0.0), (0.03, 0.115)], sides=10, cap_start=True, cap_end=True))
                else:          # snack boxes and bags
                    bh = rng.uniform(0.08, 0.13)
                    add_box(m, (x, sy + 0.004 + bh / 2, z), (0.06, bh, rng.uniform(0.03, 0.06)))
    # Payment panel.
    px = (WIN_X1 + W / 2 - t) / 2
    quad(P["Promo"], [(WIN_X1 + 0.03, 1.42, FZ + 0.001), (W / 2 - 0.05, 1.42, FZ + 0.001),
                      (W / 2 - 0.05, 1.72, FZ + 0.001), (WIN_X1 + 0.03, 1.72, FZ + 0.001)],
         [(0, 1), (1, 1), (1, 0), (0, 0)])
    add_box(P["ScreenBlue"], (px, 1.29, FZ + 0.004), (0.16, 0.12, 0.008))
    for row in range(4):
        for col in range(3):
            add_box(P["KeyGrey"], (px - 0.045 + col * 0.045, 1.17 - row * 0.042, FZ + 0.006), (0.032, 0.03, 0.012))
    add_box(P["Black"], (px, 0.94, FZ + 0.008), (0.1, 0.05, 0.016))     # card reader
    add_box(P["Chrome"], (px, 0.86, FZ + 0.006), (0.05, 0.03, 0.012))   # coin slot
    add_box(P["Black"], (px, 0.86, FZ + 0.0125), (0.006, 0.02, 0.002))
    add_box(P["TrayDark"], (px, 0.70, FZ + 0.004), (0.07, 0.05, 0.008))  # coin return
    # Pickup tray with a frame around it.
    tx0, tx1, ty0, ty1 = -0.36, 0.08, 0.15, 0.34
    add_box(P["TrayDark"], ((tx0 + tx1) / 2, (ty0 + ty1) / 2, FZ + 0.002), (tx1 - tx0, ty1 - ty0, 0.004))
    for (cx, cy, sx, sy) in [((tx0 + tx1) / 2, ty1 + 0.012, tx1 - tx0 + 0.05, 0.024),
                             ((tx0 + tx1) / 2, ty0 - 0.012, tx1 - tx0 + 0.05, 0.024),
                             (tx0 - 0.013, (ty0 + ty1) / 2, 0.026, ty1 - ty0),
                             (tx1 + 0.013, (ty0 + ty1) / 2, 0.026, ty1 - ty0)]:
        add_box(P["Black"], (cx, cy, FZ + 0.01), (sx, sy, 0.02))
    # Lit sign on top.
    add_box(w, (0, H + SIGN_H / 2, 0.01), (W, SIGN_H, D - 0.02))
    quad(P["Sign"], [(-W / 2 + 0.01, H + 0.01, FZ + 0.001), (W / 2 - 0.01, H + 0.01, FZ + 0.001),
                     (W / 2 - 0.01, H + SIGN_H - 0.01, FZ + 0.001), (-W / 2 + 0.01, H + SIGN_H - 0.01, FZ + 0.001)],
         [(0, 1), (1, 1), (1, 0), (0, 0)])
    return P


def write_machine_scene():
    prods = [(k, w) for k, *_rest in DRINKS for w in [_rest[-1]]]
    n = len(prods)
    lines = [f"[gd_scene load_steps={n + 5} format=3]", "",
             f'[ext_resource type="Script" path="{RES}/scripts/vending_machine.gd" id="1_script"]',
             f'[ext_resource type="PackedScene" path="{RES}/models/vending_machine.glb" id="2_model"]']
    for i, (k, _) in enumerate(prods):
        lines.append(f'[ext_resource type="PackedScene" path="{RES}/scenes/{k}.tscn" id="p{i}"]')
    lines += ["", '[sub_resource type="BoxShape3D" id="BoxShape3D_body"]',
              f"size = Vector3({W}, {H + SIGN_H}, {D})", "",
              '[sub_resource type="SceneReplicationConfig" id="SceneReplicationConfig_stock"]',
              'properties/0/path = NodePath(".:stock")', "properties/0/spawn = true",
              "properties/0/replication_mode = 2", "",
              '[node name="VendingMachine" type="StaticBody3D"]',
              'script = ExtResource("1_script")',
              "products = Array[PackedScene]([" + ", ".join(f'ExtResource("p{i}")' for i in range(n)) + "])",
              "weights = Array[float]([" + ", ".join(f"{w}" for _, w in prods) + "])",
              "stock = 24", "",
              '[node name="Model" parent="." instance=ExtResource("2_model")]', "",
              '[node name="Collision" type="CollisionShape3D" parent="."]',
              f"transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, {(H + SIGN_H) / 2}, 0)",
              'shape = SubResource("BoxShape3D_body")', "",
              '[node name="Dispensed" type="Node3D" parent="."]', "",
              '[node name="Spawner" type="MultiplayerSpawner" parent="."]',
              "_spawnable_scenes = PackedStringArray(" + ", ".join(f'"{RES}/scenes/{k}.tscn"' for k, _ in prods) + ")",
              'spawn_path = NodePath("../Dispensed")', "",
              '[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="."]',
              'replication_config = SubResource("SceneReplicationConfig_stock")', ""]
    (OUT / "scenes" / "vending_machine.tscn").write_text("\n".join(lines))


def main() -> None:
    tex_dir = OUT / "textures"
    tex_dir.mkdir(parents=True, exist_ok=True)
    (OUT / "models").mkdir(parents=True, exist_ok=True)
    tex = make_machine_textures(tex_dir)
    for key, node, text, bg, fg, kind, liquid, cap, settings, _w in DRINKS:
        lbl = f"label_{key}"
        p = tex_dir / f"{lbl}.png"
        make_label(key, text, bg, fg).save(p, optimize=True)
        tex[lbl] = p
        parts = {k: v for k, v in build_drink(kind).items() if v.count}
        write_glb(OUT / "models" / f"{key}.glb", node, parts, tex, drink_mats(key, lbl, liquid, cap))
        lo, hi = parts_aabb(parts)
        lc = liquid or bg
        s = dict(attack_style=1, melee_damage=4.0, melee_range=0.8, attack_cooldown=0.45,
                 throw_speed=13.0, throw_spin=7.0, throw_damage_per_speed=0.6,
                 liquid_color=f"Color({lc[0] / 255:.3f}, {lc[1] / 255:.3f}, {lc[2] / 255:.3f}, 1)", **settings)
        write_scene(key, node, 0.5 if kind != "can" else 0.35, lo, hi, s, out=OUT, script="drink.gd",
                    extra_synced=("full",))
        tris = sum(len(q.arrays()[3]) // 3 for q in parts.values())
        print(f"{key}.glb: {tris} tris, {np.round((hi - lo) * 100, 1)} cm")
    parts = {k: v for k, v in build_machine().items() if v.count}
    write_glb(OUT / "models" / "vending_machine.glb", "VendingMachine", parts, tex, MACHINE_MATS)
    write_machine_scene()
    tris = sum(len(q.arrays()[3]) // 3 for q in parts.values())
    print(f"vending_machine.glb: {tris} tris")


if __name__ == "__main__":
    main()
