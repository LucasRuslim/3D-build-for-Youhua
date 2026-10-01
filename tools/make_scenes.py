#!/usr/bin/env python3
"""Writes the Godot prop scenes (RigidBody3D + collision + net sync).

Collision boxes are hand-fitted to the meshes built by generate_assets.py:
a few boxes are much cheaper and more stable than trimesh collision, which
matters when a whole classroom of furniture is flying around.
"""
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCENES = ROOT / "assets" / "classroom_furniture" / "scenes"


def xform(pos, rot_x_deg=0.0):
    c, s = math.cos(math.radians(rot_x_deg)), math.sin(math.radians(rot_x_deg))
    b = (1, 0, 0, 0, c, -s, 0, s, c)  # .tscn stores the basis row by row
    vals = list(b) + list(pos)
    return "Transform3D(" + ", ".join(f"{v + 0.0:.6g}" for v in vals) + ")"


def scene(name, model, mass, hold_pos, boxes):
    lines = [
        f'[gd_scene load_steps={4 + len(boxes)} format=3]',
        "",
        '[ext_resource type="Script" path="res://assets/classroom_furniture/scripts/networked_prop.gd" id="1_script"]',
        f'[ext_resource type="PackedScene" path="res://assets/classroom_furniture/models/{model}" id="2_model"]',
        "",
        '[sub_resource type="PhysicsMaterial" id="PhysicsMaterial_prop"]',
        "friction = 0.6",
        "bounce = 0.15",
        "",
    ]
    for i, (_, size, _, _) in enumerate(boxes):
        lines += [f'[sub_resource type="BoxShape3D" id="BoxShape3D_{i}"]',
                  f"size = Vector3({size[0]:.4g}, {size[1]:.4g}, {size[2]:.4g})", ""]
    props = ["net_position", "net_rotation", "net_linear_velocity", "holder_peer_id"]
    lines.append('[sub_resource type="SceneReplicationConfig" id="SceneReplicationConfig_prop"]')
    for i, p in enumerate(props):
        lines += [f'properties/{i}/path = NodePath(".:{p}")',
                  f"properties/{i}/spawn = true",
                  # 2 = REPLICATION_MODE_ON_CHANGE: props at rest cost no bandwidth.
                  f"properties/{i}/replication_mode = 2"]
    lines += [
        "",
        f'[node name="{name}" type="RigidBody3D"]',
        "collision_layer = 1",
        "collision_mask = 1",
        f"mass = {mass}",
        'physics_material_override = SubResource("PhysicsMaterial_prop")',
        "continuous_cd = true",
        "contact_monitor = true",
        "max_contacts_reported = 4",
        'script = ExtResource("1_script")',
        f"hold_offset = {xform(hold_pos)}",
        "",
        '[node name="Model" parent="." instance=ExtResource("2_model")]',
        "",
    ]
    for i, (label, _, pos, rx) in enumerate(boxes):
        lines += [f'[node name="Col{label}" type="CollisionShape3D" parent="."]',
                  f"transform = {xform(pos, rx)}",
                  f'shape = SubResource("BoxShape3D_{i}")', ""]
    lines += [
        '[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="."]',
        "replication_interval = 0.033",
        "delta_interval = 0.033",
        'replication_config = SubResource("SceneReplicationConfig_prop")',
        "",
    ]
    SCENES.mkdir(parents=True, exist_ok=True)
    (SCENES / f"{model.replace('.glb', '')}.tscn").write_text("\n".join(lines))


# (label, size, centre, rotation about X in degrees)
top_y = 0.76 - 0.032 / 2
scene("SchoolDesk", "school_desk.glb", 9.0, (0, -0.55, -0.15), [
    ("Top", (0.70, 0.032, 0.48), (0, top_y, 0), 0),
    ("BookTray", (0.57, 0.12, 0.35), (0, 0.638, -0.02), 0),
    ("LegL", (0.05, 0.70, 0.05), (-0.30, 0.38, 0), 0),
    ("LegR", (0.05, 0.70, 0.05), (0.30, 0.38, 0), 0),
    ("FootL", (0.03, 0.035, 0.44), (-0.30, 0.0175, 0), 0),
    ("FootR", (0.03, 0.035, 0.44), (0.30, 0.0175, 0), 0),
    ("Stretcher", (0.60, 0.02, 0.04), (0, 0.16, 0), 0),
])
scene("SchoolChair", "school_chair.glb", 4.5, (0, -0.45, -0.2), [
    ("Seat", (0.41, 0.035, 0.41), (0, 0.437, 0.005), 0),
    ("Back", (0.37, 0.44, 0.035), (0, 0.735, -0.24), -10),
    ("LegL", (0.045, 0.40, 0.04), (-0.17, 0.22, -0.02), 0),
    ("LegR", (0.045, 0.40, 0.04), (0.17, 0.22, -0.02), 0),
    ("FootL", (0.054, 0.032, 0.43), (-0.17, 0.016, 0), 0),
    ("FootR", (0.054, 0.032, 0.43), (0.17, 0.016, 0), 0),
    ("Basket", (0.41, 0.135, 0.31), (0, 0.11, -0.02), 0),
])
print("scenes written")
