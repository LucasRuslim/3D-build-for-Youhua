#!/usr/bin/env python3
"""Procedurally builds the classroom desk + chair used in the brawl game.

Outputs (relative to the repo root):
  assets/classroom_furniture/models/school_desk.glb
  assets/classroom_furniture/models/school_chair.glb
  assets/classroom_furniture/textures/*.png

The furniture is modelled on the reference video: light "apple green" moulded
plastic parts (desk top with a pen groove, one-piece chair shell with a pinched
waist and round-topped backrest) on grey powder-coated rectangular steel tubes
(single-post adjustable legs, floor foot bars with black rubber caps).

Units are metres, +Y up, the student-facing side is +Z, origin is on the floor
under the object's footprint centre (glTF / Godot convention).

Only needs numpy + Pillow:  python3 tools/generate_assets.py
"""

from __future__ import annotations

import json
import math
import struct
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "classroom_furniture"
TEX_SIZE = 1024

# Colours sampled from the reference video, white-balanced against the floor
# tiles and with the phone's desaturating filter compensated (sRGB 0-255).
PLASTIC_GREEN = (139, 199, 109)
STEEL_GREY = (142, 144, 148)
RUBBER_BLACK = (28, 28, 30)


# --------------------------------------------------------------------------
# Textures (all tileable: built from periodic FFT-filtered noise)
# --------------------------------------------------------------------------

def periodic_noise(size: int, sigma: float, seed: int) -> np.ndarray:
    """Tileable gaussian-filtered white noise normalised to [-1, 1]."""
    rng = np.random.default_rng(seed)
    white = rng.standard_normal((size, size))
    f = np.fft.fftfreq(size)
    fx, fy = np.meshgrid(f, f)
    kernel = np.exp(-(fx ** 2 + fy ** 2) * (2 * math.pi * sigma) ** 2 / 2)
    out = np.real(np.fft.ifft2(np.fft.fft2(white) * kernel))
    out -= out.mean()
    return out / (np.abs(out).max() + 1e-9)


def height_to_normal(h: np.ndarray, strength: float) -> np.ndarray:
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * strength
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * strength
    n = np.stack([-dx, dy, np.ones_like(h)], axis=-1)  # OpenGL (+Y) normal map
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return ((n * 0.5 + 0.5) * 255).astype(np.uint8)


def make_textures() -> dict[str, Path]:
    tex_dir = OUT / "textures"
    tex_dir.mkdir(parents=True, exist_ok=True)
    s = TEX_SIZE
    paths: dict[str, Path] = {}

    def save(name: str, arr: np.ndarray) -> None:
        p = tex_dir / f"{name}.png"
        Image.fromarray(arr).save(p, optimize=True)
        paths[name] = p

    # --- moulded plastic: soft mottling + fine orange-peel surface ---------
    mottling = periodic_noise(s, 40, 1) * 0.6 + periodic_noise(s, 10, 2) * 0.4
    speck = periodic_noise(s, 1.0, 3)
    base = np.array(PLASTIC_GREEN, dtype=float)
    shade = 1.0 + 0.035 * mottling + 0.012 * speck
    save("plastic_green_albedo", np.clip(base[None, None, :] * shade[..., None], 0, 255).astype(np.uint8))
    peel = periodic_noise(s, 2.5, 4) * 0.7 + periodic_noise(s, 6, 5) * 0.3
    save("plastic_green_normal", height_to_normal(peel, 0.8))
    rough = np.clip(0.42 + 0.06 * mottling + 0.03 * speck, 0, 1)
    orm = np.stack([np.full_like(rough, 1.0), rough, np.zeros_like(rough)], axis=-1)
    save("plastic_green_orm", (orm * 255).astype(np.uint8))

    # --- powder-coated steel: fine grain, slightly glossy ------------------
    grain = periodic_noise(s, 0.8, 6)
    blotch = periodic_noise(s, 30, 7)
    base = np.array(STEEL_GREY, dtype=float)
    shade = 1.0 + 0.03 * blotch + 0.025 * grain
    save("steel_grey_albedo", np.clip(base[None, None, :] * shade[..., None], 0, 255).astype(np.uint8))
    save("steel_grey_normal", height_to_normal(periodic_noise(s, 1.5, 8), 0.6))
    rough = np.clip(0.38 + 0.08 * blotch + 0.04 * grain, 0, 1)
    metal = np.full_like(rough, 0.35)
    orm = np.stack([np.full_like(rough, 1.0), rough, metal], axis=-1)
    save("steel_grey_orm", (orm * 255).astype(np.uint8))
    return paths


# --------------------------------------------------------------------------
# Mesh building helpers
# --------------------------------------------------------------------------

class MeshPart:
    """Triangle soup with per-vertex normals and UVs for one material."""

    def __init__(self) -> None:
        self.pos: list[np.ndarray] = []
        self.nrm: list[np.ndarray] = []
        self.uv: list[np.ndarray] = []
        self.idx: list[np.ndarray] = []
        self.count = 0

    def add(self, pos, nrm, uv, idx) -> None:
        pos = np.asarray(pos, np.float32).reshape(-1, 3)
        nrm = np.asarray(nrm, np.float32).reshape(-1, 3)
        nrm = nrm / np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
        self.pos.append(pos)
        self.nrm.append(nrm)
        self.uv.append(np.asarray(uv, np.float32).reshape(-1, 2))
        self.idx.append(np.asarray(idx, np.uint32).reshape(-1) + self.count)
        self.count += len(pos)

    def arrays(self):
        return (np.concatenate(self.pos), np.concatenate(self.nrm),
                np.concatenate(self.uv), np.concatenate(self.idx))


UV_SCALE = 2.0  # texture repeats every 0.5 m


def grid_indices(rows: int, cols: int, flip: bool = False) -> np.ndarray:
    """Quads for a (rows x cols) vertex grid, two CCW triangles each."""
    out = []
    for r in range(rows - 1):
        for c in range(cols - 1):
            a, b = r * cols + c, r * cols + c + 1
            d, e = (r + 1) * cols + c, (r + 1) * cols + c + 1
            tri = [a, d, b, b, d, e] if not flip else [a, b, d, b, e, d]
            out.extend(tri)
    return np.array(out, np.uint32)


def fix_winding(part_pos, part_nrm, idx):
    """Flip triangles whose geometric normal disagrees with vertex normals."""
    idx = idx.reshape(-1, 3).copy()
    p = part_pos[idx]
    gn = np.cross(p[:, 1] - p[:, 0], p[:, 2] - p[:, 0])
    vn = part_nrm[idx].sum(axis=1)
    bad = (gn * vn).sum(axis=1) < 0
    idx[bad] = idx[bad][:, [0, 2, 1]]
    return idx.reshape(-1)


def add_box(part: MeshPart, center, size, round_axis_uv=False) -> None:
    """Axis aligned box with hard edges (24 verts)."""
    c = np.asarray(center, float)
    h = np.asarray(size, float) / 2
    faces = [
        ((1, 0, 0), (0, 1, 2)), ((-1, 0, 0), (0, 1, 2)),
        ((0, 1, 0), (1, 0, 2)), ((0, -1, 0), (1, 0, 2)),
        ((0, 0, 1), (2, 0, 1)), ((0, 0, -1), (2, 0, 1)),
    ]
    for n, (ax, u_ax, v_ax) in faces:
        n = np.array(n, float)
        sgn = n[ax]
        corners = []
        uvs = []
        for du, dv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            p = c.copy()
            p[ax] += sgn * h[ax]
            p[u_ax] += du * h[u_ax]
            p[v_ax] += dv * h[v_ax]
            corners.append(p)
            uvs.append((p[u_ax] * UV_SCALE, p[v_ax] * UV_SCALE))
        corners = np.array(corners)
        idx = np.array([0, 1, 2, 0, 2, 3])
        idx = fix_winding(corners, np.tile(n, (4, 1)), idx)
        part.add(corners, np.tile(n, (4, 1)), uvs, idx)


def rounded_rect_outline(w: float, d: float, r: float, seg: int = 8):
    """Closed CCW (seen from +Y) outline in XZ with outward normals."""
    pts, nrms = [], []
    centers = [(w / 2 - r, d / 2 - r, 0.0), (-w / 2 + r, d / 2 - r, 0.5 * math.pi),
               (-w / 2 + r, -d / 2 + r, math.pi), (w / 2 - r, -d / 2 + r, 1.5 * math.pi)]
    for cx, cz, a0 in centers:
        for i in range(seg + 1):
            a = a0 + 0.5 * math.pi * i / seg
            nx, nz = math.cos(a), math.sin(a)
            pts.append((cx + r * nx, cz + r * nz))
            nrms.append((nx, nz))
    return np.array(pts), np.array(nrms)


def add_profiled_slab(part: MeshPart, w, d, r, profile, y0, seg=8,
                      top_hole=None, hole_depth=0.0):
    """Sweep a cross-section profile around a rounded rectangle.

    profile: list of (inset, y) from the bottom-centre edge up to the top edge.
    top_hole: optional (outline_pts) convex polygon cut into the top cap,
              recessed by hole_depth (used for the pen groove).
    """
    outline, onrm = rounded_rect_outline(w, d, r, seg)
    n = len(outline)
    prof = np.array(profile, float)
    # Smooth profile normals in the (outward, up) plane: rotate the tangent of
    # the (outward = -inset, y) curve clockwise.
    tang = np.gradient(np.c_[-prof[:, 0], prof[:, 1]], axis=0)
    pn = np.stack([tang[:, 1], -tang[:, 0]], axis=1)
    pn /= np.linalg.norm(pn, axis=1, keepdims=True)
    rows = len(prof)
    pos = np.zeros((rows, n + 1, 3))
    nrm = np.zeros((rows, n + 1, 3))
    uv = np.zeros((rows, n + 1, 2))
    seglen = np.r_[0, np.cumsum(np.linalg.norm(np.diff(outline, axis=0), axis=1))]
    seglen = np.r_[seglen, seglen[-1] + np.linalg.norm(outline[0] - outline[-1])]
    for ri, (inset, y) in enumerate(prof):
        for ci in range(n + 1):
            k = ci % n
            o, on = outline[k], onrm[k]
            pos[ri, ci] = (o[0] - on[0] * inset, y0 + y, o[1] - on[1] * inset)
            nrm[ri, ci] = (on[0] * pn[ri, 0], pn[ri, 1], on[1] * pn[ri, 0])
            uv[ri, ci] = (seglen[ci] * UV_SCALE, y * UV_SCALE * 4)
    idx = grid_indices(rows, n + 1)
    pos, nrm = pos.reshape(-1, 3), nrm.reshape(-1, 3)
    part.add(pos, nrm, uv.reshape(-1, 2), fix_winding(pos, nrm, idx))

    # Bottom cap (fan).
    ins, yb = prof[0]
    ring = np.array([(o[0] - on[0] * ins, y0 + yb, o[1] - on[1] * ins) for o, on in zip(outline, onrm)])
    cap_pos = np.vstack([[0, y0 + yb, 0], ring])
    cap_nrm = np.tile([0, -1, 0], (n + 1, 1))
    cap_idx = []
    for i in range(n):
        cap_idx += [0, 1 + i, 1 + (i + 1) % n]
    part.add(cap_pos, cap_nrm, cap_pos[:, [0, 2]] * UV_SCALE,
             fix_winding(cap_pos, cap_nrm, np.array(cap_idx)))

    # Top cap, optionally with a recessed convex hole (zipper triangulation of
    # two star-shaped rings around the hole centre).
    ins, yt = prof[-1]
    top_y = y0 + yt
    ring = np.array([(o[0] - on[0] * ins, o[1] - on[1] * ins) for o, on in zip(outline, onrm)])
    up = np.array([0, 1, 0])
    if top_hole is None:
        cap = np.vstack([[0, 0], ring])
        cap_pos = np.c_[cap[:, 0], np.full(len(cap), top_y), cap[:, 1]]
        cap_idx = []
        for i in range(n):
            cap_idx += [0, 1 + i, 1 + (i + 1) % n]
        part.add(cap_pos, np.tile(up, (len(cap), 1)), cap * UV_SCALE,
                 fix_winding(cap_pos, np.tile(up, (len(cap), 1)), np.array(cap_idx)))
        return
    hole = np.asarray(top_hole, float)
    hc = hole.mean(axis=0)
    ang = lambda p: np.mod(np.arctan2(p[:, 1] - hc[1], p[:, 0] - hc[0]), 2 * math.pi)
    oa, ha = ang(ring), ang(hole)
    oo, ho = np.argsort(oa), np.argsort(ha)
    ring, oa = ring[oo], oa[oo]
    hole, ha = hole[ho], ha[ho]
    m = len(hole)
    allp = np.vstack([ring, hole])
    tris = []
    i = j = 0
    while i < n or j < m:
        a_next = oa[(i + 1) % n] + (2 * math.pi if i + 1 >= n else 0)
        b_next = ha[(j + 1) % m] + (2 * math.pi if j + 1 >= m else 0)
        oi, hj = i % n, n + j % m
        if j >= m or (i < n and a_next <= b_next):
            tris += [oi, (i + 1) % n, hj]
            i += 1
        else:
            tris += [oi, n + (j + 1) % m, hj]
            j += 1
    cap_pos = np.c_[allp[:, 0], np.full(len(allp), top_y), allp[:, 1]]
    cap_nrm = np.tile(up, (len(allp), 1))
    part.add(cap_pos, cap_nrm, allp * UV_SCALE, fix_winding(cap_pos, cap_nrm, np.array(tris)))
    # Groove walls + floor.
    hole_closed = np.vstack([hole, hole[:1]])
    walls_pos, walls_nrm, walls_uv = [], [], []
    for k in range(m + 1):
        p = hole_closed[k]
        inward = hc - p
        inward /= np.linalg.norm(inward) + 1e-9
        for yy in (top_y, top_y - hole_depth):
            walls_pos.append((p[0], yy, p[1]))
            walls_nrm.append((inward[0], 0, inward[1]))
            walls_uv.append((k * 0.01, yy * UV_SCALE))
    wp, wn = np.array(walls_pos), np.array(walls_nrm)
    part.add(wp, wn, walls_uv, fix_winding(wp, wn, grid_indices(m + 1, 2)))
    floor = np.vstack([hc, hole])
    fp = np.c_[floor[:, 0], np.full(len(floor), top_y - hole_depth), floor[:, 1]]
    fidx = []
    for k in range(m):
        fidx += [0, 1 + k, 1 + (k + 1) % m]
    part.add(fp, np.tile(up, (len(fp), 1)), floor * UV_SCALE,
             fix_winding(fp, np.tile(up, (len(fp), 1)), np.array(fidx)))


def stadium(cx, cz, length, width, seg=8):
    """Convex slot outline (rounded ends) along X."""
    r = width / 2
    pts = []
    for i in range(seg + 1):
        a = -math.pi / 2 + math.pi * i / seg
        pts.append((cx + length / 2 - r + r * math.cos(a), cz + r * math.sin(a)))
    for i in range(seg + 1):
        a = math.pi / 2 + math.pi * i / seg
        pts.append((cx - length / 2 + r + r * math.cos(a), cz + r * math.sin(a)))
    return pts


def add_tube(part, a, b, w, h, cap=None):
    """Rectangular tube between points a and b (axis aligned), w/h section."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    axis = int(np.argmax(np.abs(b - a)))
    size = np.zeros(3)
    size[axis] = abs(b[axis] - a[axis])
    others = [i for i in range(3) if i != axis]
    size[others[0]], size[others[1]] = w, h
    add_box(part, (a + b) / 2, size)


def add_round_tube_path(part, pts, radius, sides=8, closed=False):
    """Round tube (wire / bent steel tube) swept along a polyline."""
    pts = np.asarray(pts, float)
    if closed:
        pts = np.vstack([pts, pts[:1]])
    n = len(pts)
    tang = np.gradient(pts, axis=0)
    if closed:
        tang[0] = tang[-1] = pts[1] - pts[-2]
    tang /= np.linalg.norm(tang, axis=1, keepdims=True)
    # Parallel-transport a reference vector along the path (no twisting).
    ref = np.array([0.0, 1.0, 0.0]) if abs(tang[0][1]) < 0.9 else np.array([1.0, 0.0, 0.0])
    u = np.cross(tang[0], ref)
    u /= np.linalg.norm(u)
    frames = []
    for t in tang:
        u = u - t * np.dot(u, t)
        u /= np.linalg.norm(u)
        frames.append((u, np.cross(t, u)))
    arc = np.r_[0, np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))]
    pos, nrm, uv = [], [], []
    for i in range(n):
        u, v = frames[i]
        for k in range(sides + 1):
            a = 2 * math.pi * k / sides
            d = u * math.cos(a) + v * math.sin(a)
            pos.append(pts[i] + d * radius)
            nrm.append(d)
            uv.append((k / sides * 0.1, arc[i] * UV_SCALE))
    pos, nrm = np.array(pos), np.array(nrm)
    part.add(pos, nrm, uv, fix_winding(pos, nrm, grid_indices(n, sides + 1)))


def rounded_rect_path(cx, cz, w, d, r, y, seg=5):
    pts = []
    for (px, pz, a0) in ((cx + w / 2 - r, cz + d / 2 - r, 0.0), (cx - w / 2 + r, cz + d / 2 - r, 0.5 * math.pi),
                         (cx - w / 2 + r, cz - d / 2 + r, math.pi), (cx + w / 2 - r, cz - d / 2 + r, 1.5 * math.pi)):
        for i in range(seg + 1):
            a = a0 + 0.5 * math.pi * i / seg
            pts.append((px + r * math.cos(a), y, pz + r * math.sin(a)))
    return pts


def add_wire_basket(part, cx, cz, w, d, y_rim, y_bottom, rim_r=0.009, wire_r=0.0025, spacing=0.045,
                    avoid_x=(), avoid_gap=0.03):
    """Book basket like the ones on the reference furniture: a bent round-tube
    rim with U-shaped wires hanging from it, plus a few wires along the floor."""
    add_round_tube_path(part, rounded_rect_path(cx, cz, w, d, 0.04, y_rim), rim_r, sides=10, closed=True)
    taper = 0.02  # the basket narrows towards the bottom
    n = max(int((w - 0.06) / spacing), 1)
    xs = np.linspace(cx - w / 2 + 0.03, cx + w / 2 - 0.03, n + 1)
    # No wires through the frame posts the rim is welded to.
    xs = np.array([x for x in xs if all(abs(x - a) >= avoid_gap for a in avoid_x)])
    bend = 0.012
    zf, zb = cz + d / 2 - rim_r, cz - d / 2 + rim_r
    for x in xs:
        path = [(x, y_rim, zb), (x, y_bottom + bend, zb + taper - 0.002),
                (x, y_bottom + wire_r, zb + taper + bend), (x, y_bottom + wire_r, zf - taper - bend),
                (x, y_bottom + bend, zf - taper + 0.002), (x, y_rim, zf)]
        add_round_tube_path(part, path, wire_r, sides=6)
    for z in np.linspace(zb + taper + bend, zf - taper - bend, 3):
        add_round_tube_path(part, [(xs[0] - 0.01, y_bottom + 3 * wire_r, z), (xs[-1] + 0.01, y_bottom + 3 * wire_r, z)],
                            wire_r, sides=6)


# --------------------------------------------------------------------------
# Desk
# --------------------------------------------------------------------------

DESK_W, DESK_D, DESK_H = 0.70, 0.48, 0.76


def build_desk():
    plastic, steel, rubber = MeshPart(), MeshPart(), MeshPart()
    top_t = 0.032
    y0 = DESK_H - top_t
    # Rounded rim: bulged edge like the moulded desk tops in the video.
    profile = [(0.018, 0.0), (0.006, 0.004), (0.001, 0.010), (0.0, 0.018),
               (0.001, 0.025), (0.004, 0.0295), (0.009, 0.0315), (0.016, top_t)]
    groove = stadium(0.0, -DESK_D / 2 + 0.045, 0.46, 0.016, seg=6)
    add_profiled_slab(plastic, DESK_W, DESK_D, 0.035, profile, y0, seg=8,
                      top_hole=groove, hole_depth=0.007)

    # Steel frame -------------------------------------------------------
    leg_x = DESK_W / 2 - 0.05
    tube = 0.05, 0.025
    for sx in (-1, 1):
        x = sx * leg_x
        # Under-top support rail (front-back).
        add_tube(steel, (x, y0 - 0.0125, -0.20), (x, y0 - 0.0125, 0.20), 0.025, 0.025)
        # Outer post (lower) and adjustable inner post (upper).
        add_tube(steel, (x, 0.03, 0.0), (x, 0.46, 0.0), 0.05, 0.03)
        add_tube(steel, (x, 0.46, 0.0), (x, y0 - 0.025, 0.0), 0.040, 0.022)
        # Height-adjust clamp collar.
        add_box(steel, (x, 0.45, 0.0), (0.06, 0.03, 0.04))
        # Floor foot bar with black rubber end caps.
        add_tube(steel, (x, 0.0175, -0.21), (x, 0.0175, 0.21), tube[1] + 0.005, 0.035)
        for sz in (-1, 1):
            add_box(rubber, (x, 0.0175, sz * 0.2165), (0.032, 0.037, 0.013))
        # Diagonal-ish gusset from post to top rail (two short boxes).
        add_tube(steel, (x, y0 - 0.06, -0.14), (x, y0 - 0.06, 0.14), 0.02, 0.02)
    # Low stretcher between the two side frames (has the sticker in the video).
    add_tube(steel, (-leg_x, 0.16, 0.0), (leg_x, 0.16, 0.0), 0.04, 0.02)
    # Sheet-steel book tray under the top, open towards the student (+Z).
    tray_y = y0 - 0.15
    add_box(steel, (0, tray_y, -0.02), (2 * leg_x - 0.03, 0.006, 0.34))
    add_box(steel, (0, tray_y + 0.06, -0.19), (2 * leg_x - 0.03, 0.12, 0.006))
    for sx in (-1, 1):
        add_box(steel, (sx * (leg_x - 0.018), tray_y + 0.06, -0.02), (0.006, 0.12, 0.34))
    return {"GreenPlastic": plastic, "SteelGrey": steel, "BlackRubber": rubber}


# --------------------------------------------------------------------------
# Chair
# --------------------------------------------------------------------------

SEAT_H = 0.44


def catmull_rom(pts: np.ndarray, samples: int) -> np.ndarray:
    pts = np.asarray(pts, float)
    p = np.vstack([2 * pts[0] - pts[1], pts, 2 * pts[-1] - pts[-2]])
    out = []
    segs = len(pts) - 1
    for s in range(segs):
        p0, p1, p2, p3 = p[s], p[s + 1], p[s + 2], p[s + 3]
        for i in range(samples):
            t = i / samples
            t2, t3 = t * t, t * t * t
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                              + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    out.append(pts[-1])
    return np.array(out)


def build_chair():
    plastic, steel, rubber = MeshPart(), MeshPart(), MeshPart()
    # Side profile of the one-piece shell, (z, y), from the front lip to the
    # top of the backrest. +Z is the front of the seat.
    ctrl = np.array([
        (0.218, SEAT_H - 0.020),   # front waterfall lip
        (0.208, SEAT_H + 0.002),
        (0.170, SEAT_H + 0.012),
        (0.060, SEAT_H + 0.004),
        (-0.070, SEAT_H - 0.006),  # lowest point of the seat pan
        (-0.160, SEAT_H + 0.020),
        (-0.205, SEAT_H + 0.090),  # pinched waist
        (-0.215, SEAT_H + 0.200),
        (-0.225, SEAT_H + 0.320),
        (-0.250, SEAT_H + 0.430),
        (-0.275, SEAT_H + 0.475),  # top of the round backrest
    ])
    curve = catmull_rom(ctrl, 7)
    seg_len = np.linalg.norm(np.diff(curve, axis=0), axis=1)
    arc = np.r_[0, np.cumsum(seg_len)]
    s = arc / arc[-1]
    rows = len(curve)
    tang = np.gradient(curve, axis=0)
    tang /= np.linalg.norm(tang, axis=1, keepdims=True)
    # Normal pointing to the sitting side (up on the seat, forward on the back).
    pn = np.stack([-tang[:, 1], tang[:, 0]], axis=1)  # (z, y)
    if pn[rows // 4, 1] < 0:
        pn = -pn

    def half_width(t: float) -> float:
        seat_w, waist_w, back_w = 0.205, 0.125, 0.185
        waist_t, back_t, round_t = 0.50, 0.66, 0.82
        if t < 0.03:
            return seat_w - 0.02 * (1 - t / 0.03)  # rounded front corners
        if t < 0.38:
            return seat_w
        if t < waist_t:
            k = (t - 0.38) / (waist_t - 0.38)
            return seat_w + (waist_w - seat_w) * (0.5 - 0.5 * math.cos(math.pi * k))
        if t < back_t:
            k = (t - waist_t) / (back_t - waist_t)
            return waist_w + (back_w - waist_w) * (0.5 - 0.5 * math.cos(math.pi * k))
        if t < round_t:
            return back_w
        k = (t - round_t) / (1 - round_t)  # semicircular top
        return max(back_w * math.sqrt(max(1 - k * k, 0)), 0.004)

    def dish(t: float) -> float:
        # How far the sides curl towards the sitter (bucket shape).
        if t < 0.4:
            return 0.018
        if t < 0.6:
            return 0.018 + 0.03 * (t - 0.4) / 0.2
        return 0.048

    cols = 17
    xs = np.linspace(-1, 1, cols)
    thickness = 0.010
    front = np.zeros((rows, cols, 3))
    for r in range(rows):
        hw = half_width(s[r])
        dz, dy = pn[r]
        for c, u in enumerate(xs):
            off = dish(s[r]) * u * u
            front[r, c] = (u * hw, curve[r, 1] + dy * off, curve[r, 0] + dz * off)

    def grid_normals(g):
        du = np.gradient(g, axis=1)
        dv = np.gradient(g, axis=0)
        n = np.cross(du, dv)
        n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-9)
        # orient to sitting side
        ref = np.zeros_like(n)
        ref[..., 1], ref[..., 2] = pn[:, None, 1], pn[:, None, 0]
        flip = (n * ref).sum(axis=2) < 0
        n[flip] = -n[flip]
        return n

    nf = grid_normals(front)
    back = front - nf * thickness
    uv = np.zeros((rows, cols, 2))
    uv[..., 0] = front[..., 0] * UV_SCALE
    uv[..., 1] = (arc[:, None] * UV_SCALE)
    idx = grid_indices(rows, cols)
    fp, fn = front.reshape(-1, 3), nf.reshape(-1, 3)
    plastic.add(fp, fn, uv.reshape(-1, 2), fix_winding(fp, fn, idx))
    bp, bn = back.reshape(-1, 3), -nf.reshape(-1, 3)
    plastic.add(bp, bn, uv.reshape(-1, 2), fix_winding(bp, bn, idx))
    # Rim around the shell edge (left side, top, right side, front lip).
    loop = ([(r, 0) for r in range(rows)] + [(rows - 1, c) for c in range(1, cols)]
            + [(r, cols - 1) for r in range(rows - 2, -1, -1)] + [(0, c) for c in range(cols - 2, 0, -1)])
    loop.append(loop[0])
    rim_p, rim_n, rim_uv = [], [], []
    centre = front.reshape(-1, 3).mean(axis=0)
    for k, (r, c) in enumerate(loop):
        a, b = front[r, c], back[r, c]
        out = (a + b) / 2 - centre
        out -= nf[r, c] * np.dot(out, nf[r, c])
        out /= np.linalg.norm(out) + 1e-9
        for p in (a, b):
            rim_p.append(p)
            rim_n.append(out)
            rim_uv.append((k * 0.02, 0 if p is a else 0.02))
    rp, rn = np.array(rim_p), np.array(rim_n)
    plastic.add(rp, rn, rim_uv, fix_winding(rp, rn, grid_indices(len(loop), 2)))

    # Steel frame -------------------------------------------------------
    leg_x = 0.17
    seat_bottom = SEAT_H - 0.02
    for sx in (-1, 1):
        x = sx * leg_x
        # Seat support rail under the shell.
        add_tube(steel, (x, seat_bottom - 0.0125, -0.17), (x, seat_bottom - 0.0125, 0.17), 0.025, 0.025)
        # Single adjustable post.
        add_tube(steel, (x, 0.03, -0.02), (x, 0.28, -0.02), 0.045, 0.028)
        add_tube(steel, (x, 0.28, -0.02), (x, seat_bottom - 0.025, -0.02), 0.036, 0.022)
        add_box(steel, (x, 0.27, -0.02), (0.055, 0.03, 0.04))
        # Foot bar + rubber caps.
        add_tube(steel, (x, 0.015, -0.19), (x, 0.015, 0.19), 0.05, 0.03)
        for sz in (-1, 1):
            add_box(rubber, (x, 0.016, sz * 0.2025), (0.054, 0.032, 0.025))
    # Wire basket under the seat, its rim welded to both posts (it also acts
    # as the frame's cross brace).
    # Like the reference photo, the rim runs a little past the posts at both
    # ends, so the basket is longer than the gap between them.
    add_wire_basket(steel, 0.0, -0.02, 2 * (leg_x + 0.025), 0.30, 0.17, 0.045, avoid_x=(-leg_x, leg_x))
    # Backrest support strut: rear cross bar + upright bolted to the shell.
    add_tube(steel, (-leg_x, seat_bottom - 0.0125, -0.16), (leg_x, seat_bottom - 0.0125, -0.16), 0.02, 0.025)
    shell_back = curve[np.argmin(np.abs(curve[:, 1] - (SEAT_H + 0.24)))]
    strut_z = shell_back[0] - thickness - 0.012
    add_tube(steel, (0, seat_bottom - 0.0125, -0.16), (0, seat_bottom - 0.0125, strut_z), 0.03, 0.02)
    add_tube(steel, (0, seat_bottom - 0.025, strut_z), (0, SEAT_H + 0.24, strut_z), 0.03, 0.01)
    return {"GreenPlastic": plastic, "SteelGrey": steel, "BlackRubber": rubber}


# --------------------------------------------------------------------------
# Minimal glTF 2.0 (.glb) writer
# --------------------------------------------------------------------------

def write_glb(path: Path, name: str, parts: dict[str, MeshPart], tex: dict[str, Path],
              materials: dict[str, dict] | None = None) -> None:
    """Write a .glb. `materials` maps a part name to a spec dict with any of:
    color (sRGB 0-255), alpha, metallic, roughness, albedo_tex, normal_tex,
    normal_scale, alpha_mode ("BLEND"/"MASK"), double_sided, emissive (sRGB 0-255),
    emissive_tex. Parts without a
    spec use the furniture materials below."""
    gltf: dict = {
        "asset": {"version": "2.0", "generator": "3D-build-for-Youhua/tools/generate_assets.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": name, "mesh": 0}],
        "meshes": [{"name": name, "primitives": []}],
        "materials": [], "textures": [], "images": [], "samplers": [
            {"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "accessors": [], "bufferViews": [], "buffers": [],
    }
    blob = bytearray()

    def view(data: bytes, target: int | None = None) -> int:
        while len(blob) % 4:
            blob.append(0)
        v = {"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)}
        if target:
            v["target"] = target
        blob.extend(data)
        gltf["bufferViews"].append(v)
        return len(gltf["bufferViews"]) - 1

    def accessor(arr: np.ndarray, kind: str, target: int, minmax: bool = False) -> int:
        comp = 5125 if arr.dtype == np.uint32 else 5126
        acc = {"bufferView": view(arr.tobytes(), target), "componentType": comp,
               "count": len(arr), "type": kind}
        if minmax:
            acc["min"] = arr.min(axis=0).tolist()
            acc["max"] = arr.max(axis=0).tolist()
        gltf["accessors"].append(acc)
        return len(gltf["accessors"]) - 1

    image_ids: dict[str, int] = {}

    def texture(key: str) -> int:
        if key not in image_ids:
            # Textures are referenced, not embedded, so both models share the
            # same PNGs (Godot resolves the path relative to the .glb).
            gltf["images"].append({"name": key, "uri": f"../textures/{tex[key].name}"})
            gltf["textures"].append({"sampler": 0, "source": len(gltf["images"]) - 1})
            image_ids[key] = len(gltf["textures"]) - 1
        return image_ids[key]

    def srgb_to_linear(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    for mat_name, part in parts.items():
        if part.count == 0:
            continue
        spec = (materials or {}).get(mat_name)
        if spec is not None:
            pbr = {"baseColorFactor": [srgb_to_linear(c) for c in spec.get("color", (255, 255, 255))]
                   + [spec.get("alpha", 1.0)],
                   "metallicFactor": spec.get("metallic", 0.0),
                   "roughnessFactor": spec.get("roughness", 0.5)}
            if "albedo_tex" in spec:
                pbr["baseColorTexture"] = {"index": texture(spec["albedo_tex"])}
            mat = {"name": mat_name, "pbrMetallicRoughness": pbr}
            if "normal_tex" in spec:
                mat["normalTexture"] = {"index": texture(spec["normal_tex"]), "scale": spec.get("normal_scale", 0.3)}
            if "alpha_mode" in spec:
                mat["alphaMode"] = spec["alpha_mode"]
            if spec.get("double_sided"):
                mat["doubleSided"] = True
            if "emissive" in spec:
                mat["emissiveFactor"] = [srgb_to_linear(c) for c in spec["emissive"]]
                if "emissive_tex" in spec:
                    mat["emissiveTexture"] = {"index": texture(spec["emissive_tex"])}
        elif mat_name == "GreenPlastic":
            mat = {"name": mat_name, "pbrMetallicRoughness": {
                "baseColorTexture": {"index": texture("plastic_green_albedo")},
                "metallicRoughnessTexture": {"index": texture("plastic_green_orm")},
                "metallicFactor": 1.0, "roughnessFactor": 1.0},
                "normalTexture": {"index": texture("plastic_green_normal"), "scale": 0.25}}
        elif mat_name == "SteelGrey":
            mat = {"name": mat_name, "pbrMetallicRoughness": {
                "baseColorTexture": {"index": texture("steel_grey_albedo")},
                "metallicRoughnessTexture": {"index": texture("steel_grey_orm")},
                "metallicFactor": 1.0, "roughnessFactor": 1.0},
                "normalTexture": {"index": texture("steel_grey_normal"), "scale": 0.2}}
        else:
            mat = {"name": mat_name, "pbrMetallicRoughness": {
                "baseColorFactor": [srgb_to_linear(c) for c in RUBBER_BLACK] + [1.0],
                "metallicFactor": 0.0, "roughnessFactor": 0.9}}
        gltf["materials"].append(mat)
        pos, nrm, uv, idx = part.arrays()
        gltf["meshes"][0]["primitives"].append({
            "attributes": {
                "POSITION": accessor(pos, "VEC3", 34962, minmax=True),
                "NORMAL": accessor(nrm, "VEC3", 34962),
                "TEXCOORD_0": accessor(uv, "VEC2", 34962),
            },
            "indices": accessor(idx, "SCALAR", 34963),
            "material": len(gltf["materials"]) - 1,
        })

    while len(blob) % 4:
        blob.append(0)
    gltf["buffers"].append({"byteLength": len(blob)})
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    total = 12 + 8 + len(js) + 8 + len(blob)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A))
        f.write(js)
        f.write(struct.pack("<II", len(blob), 0x004E4942))
        f.write(blob)


def main() -> None:
    tex = make_textures()
    models = OUT / "models"
    models.mkdir(parents=True, exist_ok=True)
    for fname, name, builder in (("school_desk.glb", "SchoolDesk", build_desk),
                                 ("school_chair.glb", "SchoolChair", build_chair)):
        parts = builder()
        write_glb(models / fname, name, parts, tex)
        tris = sum(len(p.arrays()[3]) // 3 for p in parts.values() if p.count)
        print(f"{fname}: {tris} triangles")


if __name__ == "__main__":
    main()
