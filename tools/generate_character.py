#!/usr/bin/env python3
"""Builds the student character: a rigged, PS3-era style low-poly young man
(messy black hair, black rectangular glasses, white tank top, black athletic
shorts with a grey side stripe, barefoot) whose clothes can be swapped.

Outputs (relative to the repo root):
  assets/characters/student/models/student_base.glb  body, head, hair, glasses,
                                                     skeleton + idle/walk/run animations
  assets/characters/student/models/<piece>.glb       one clothing piece each, skinned
                                                     to the same skeleton
  assets/characters/student/textures/*.png           small textures, nearest-filtered
                                                     (the chunky PS3 texel look)

Units are metres, +Y up, the character faces +Z and its left is +X (Godot's
model convention), feet on the floor at the origin, about 1.75 m tall with
hair. Bones use Godot's humanoid names (SkeletonProfileHumanoid) with
identity rest rotations, so other humanoid animations retarget with a BoneMap.

Textures are painted procedurally: each texel is mapped back to the 3D point
it covers ("baked"), so features like the eyes, the shorts' side stripe or
the tank top's trim are drawn where they belong on the model.

  python3 tools/generate_character.py
"""

from __future__ import annotations

import json
import math
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_assets import MeshPart, add_box, fix_winding, grid_indices  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "characters" / "student"

# --------------------------------------------------------------------------
# Skeleton
# --------------------------------------------------------------------------

ARM_ANGLE = math.radians(22.0)                       # A-pose: arms 22 deg out from the body
ARM_DIR = np.array([math.sin(ARM_ANGLE), -math.cos(ARM_ANGLE), 0.0])
ARM_OUT = np.array([math.cos(ARM_ANGLE), math.sin(ARM_ANGLE), 0.0])  # across the arm, up/out
SHOULDER = np.array([0.172, 1.398, -0.01])
ELBOW_S, WRIST_S = 0.28, 0.53                        # distances along the arm
HIP = np.array([0.09, 0.90, 0.0])
KNEE = np.array([0.103, 0.49, 0.005])
ANKLE = np.array([0.108, 0.085, -0.015])
TOES = np.array([0.118, 0.02, 0.115])


def _bones():
    centre = [("Root", None, (0, 0, 0)), ("Hips", "Root", (0, 0.93, 0)), ("Spine", "Hips", (0, 1.02, 0)),
              ("Chest", "Spine", (0, 1.14, 0)), ("UpperChest", "Chest", (0, 1.27, 0)),
              ("Neck", "UpperChest", (0, 1.45, -0.005)), ("Head", "Neck", (0, 1.53, 0))]
    arm = [("LeftShoulder", "UpperChest", (0.03, 1.39, -0.01)), ("LeftUpperArm", "LeftShoulder", SHOULDER),
           ("LeftLowerArm", "LeftUpperArm", SHOULDER + ARM_DIR * ELBOW_S),
           ("LeftHand", "LeftLowerArm", SHOULDER + ARM_DIR * WRIST_S)]
    leg = [("LeftUpperLeg", "Hips", HIP), ("LeftLowerLeg", "LeftUpperLeg", KNEE),
           ("LeftFoot", "LeftLowerLeg", ANKLE), ("LeftToes", "LeftFoot", TOES)]

    def mirror(chain):
        return [(n.replace("Left", "Right"), p.replace("Left", "Right"), (-q[0], q[1], q[2])) for n, p, q in chain]
    out = centre + arm + mirror(arm) + leg + mirror(leg)
    return [(n, p, np.array(q, float)) for n, p, q in out]


BONES = _bones()
NB = len(BONES)
BI = {b[0]: i for i, b in enumerate(BONES)}
MIRROR = np.array([BI.get(n.replace("Left", "#").replace("Right", "Left").replace("#", "Right"), i)
                   for i, (n, _, _) in enumerate(BONES)])


# --------------------------------------------------------------------------
# Skinned mesh building
# --------------------------------------------------------------------------

HEAD_SCALE, HEAD_DROP = 1.05, 0.010


class SkinPart:
    """Triangles + per-vertex bone weights (dense, NB columns) for one material."""

    def __init__(self) -> None:
        self.chunks: list = []
        self.count = 0

    def add(self, pos, nrm, uv, w, idx, wind=True) -> None:
        pos = np.asarray(pos, np.float32).reshape(-1, 3)
        nrm = np.asarray(nrm, np.float32).reshape(-1, 3)
        nrm = nrm / np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
        idx = np.asarray(idx, np.uint32).reshape(-1)
        if wind:
            idx = fix_winding(pos, nrm, idx)
        self.chunks.append((pos, nrm, np.asarray(uv, np.float32).reshape(-1, 2),
                            np.asarray(w, np.float32).reshape(-1, NB), idx + self.count))
        self.count += len(pos)

    def add_mirrored(self, pos, nrm, uv, w, idx) -> None:
        """The same piece on the right side of the body."""
        flip = np.array([-1.0, 1.0, 1.0])
        self.add(np.asarray(pos) * flip, np.asarray(nrm) * flip, uv, np.asarray(w)[:, MIRROR], idx)

    def add_both(self, pos, nrm, uv, w, idx) -> None:
        self.add(pos, nrm, uv, w, idx)
        self.add_mirrored(pos, nrm, uv, w, idx)

    def add_rigid(self, part: MeshPart, bone: str) -> None:
        if part.count == 0:
            return
        pos, nrm, uv, idx = part.arrays()
        self.add(pos, nrm, uv, one_bone(len(pos), bone), idx)

    def transform(self, scale, pivot, offset) -> None:
        self.chunks = [(((c[0] - pivot) * scale + pivot + offset).astype(np.float32),) + c[1:] for c in self.chunks]

    def arrays(self):
        pos, nrm, uv, w, idx = (np.concatenate(a) for a in zip(*self.chunks))
        order = np.argsort(-w, axis=1)[:, :4]
        top = np.take_along_axis(w, order, axis=1)
        top = top / np.maximum(top.sum(axis=1, keepdims=True), 1e-9)
        order[top == 0] = 0
        return pos, nrm, uv, order.astype(np.uint16), top.astype(np.float32), idx.astype(np.uint32)


def one_bone(n: int, bone: str) -> np.ndarray:
    w = np.zeros((n, NB))
    w[:, BI[bone]] = 1.0
    return w


def clip01(x):
    return np.clip(x, 0.0, 1.0)


def norm(v):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-9)


def loft(centers, ax, bx, ra, rb, n, start=-math.pi / 2, expo=2.0) -> np.ndarray:
    """Rings of n points: centers[i] + ax*ra*cos(t) + bx*rb*sin(t) (super-ellipse
    when expo > 2). Returns an (R, n, 3) grid."""
    centers = np.asarray(centers, float)
    R = len(centers)
    ax = np.broadcast_to(np.asarray(ax, float), (R, 3))
    bx = np.broadcast_to(np.asarray(bx, float), (R, 3))
    ra = np.broadcast_to(np.asarray(ra, float), (R,))
    rb = np.broadcast_to(np.asarray(rb, float), (R,))
    e = 2.0 / np.broadcast_to(np.asarray(expo, float), (R,))[:, None]
    t = start + 2 * math.pi * np.arange(n) / n
    c, s = np.cos(t)[None, :], np.sin(t)[None, :]
    cc = np.sign(c) * np.abs(c) ** e
    ss = np.sign(s) * np.abs(s) ** e
    return (centers[:, None, :] + ax[:, None, :] * (ra[:, None] * cc)[..., None]
            + bx[:, None, :] * (rb[:, None] * ss)[..., None])


def grid_normals(G: np.ndarray) -> np.ndarray:
    dU = np.roll(G, -1, axis=1) - np.roll(G, 1, axis=1)
    dV = np.empty_like(G)
    dV[1:-1] = G[2:] - G[:-2]
    dV[0] = G[1] - G[0]
    dV[-1] = G[-1] - G[-2]
    n = np.cross(dU, dV)
    out = G - G.mean(axis=1, keepdims=True)
    if (n * out).sum() < 0:
        n = -n
    bad = np.linalg.norm(n, axis=-1) < 1e-12   # collapsed rings (tips)
    n[bad] = out[bad] if np.any(out[bad]) else 0
    return norm(n)


def path_frames(pts, ref):
    """Tangents and two perpendicular axes along a polyline (ref picks the first axis)."""
    pts = np.asarray(pts, float)
    T = np.gradient(pts, axis=0)
    T = norm(T)
    a = norm(ref - (T @ ref)[:, None] * T)
    b = np.cross(T, a)
    return T, a, b


class Grid:
    """A lofted surface ready to emit and to bake a texture for."""

    def __init__(self, G, uvrect, base=None, cap_start=False, cap_end=False):
        self.G = np.asarray(G, float)
        self.base = self.G if base is None else np.asarray(base, float)  # for skin weights
        self.N = grid_normals(self.G)
        self.uvrect = uvrect
        self.cap_start, self.cap_end = cap_start, cap_end

    def mesh(self, keep=None):
        G, N = self.G, self.N
        R, n = G.shape[:2]
        close = lambda a: np.concatenate([a, a[:, :1]], axis=1)  # noqa: E731
        pos, nrm, base = close(G).reshape(-1, 3), close(N).reshape(-1, 3), close(self.base).reshape(-1, 3)
        u0, v0, u1, v1 = self.uvrect
        U, V = np.meshgrid(u0 + (u1 - u0) * np.arange(n + 1) / n, v0 + (v1 - v0) * np.arange(R) / (R - 1))
        uv = np.stack([U, V], -1).reshape(-1, 2)
        idx = grid_indices(R, n + 1).reshape(-1, 3)
        if keep is not None:
            idx = idx[keep(pos[idx].mean(axis=1))]
        idx = [idx]
        extra = []
        for flag, row, nxt, v in ((self.cap_start, 0, 1, v0), (self.cap_end, R - 1, R - 2, v1)):
            if not flag:
                continue
            c = G[row].mean(axis=0)
            cn = norm(c - G[nxt].mean(axis=0))
            ci = len(pos) + sum(len(e[0]) for e in extra)
            extra.append((c[None], cn[None], np.array([[(u0 + u1) / 2, v]]), self.base[row].mean(axis=0)[None]))
            ring = row * (n + 1) + np.arange(n + 1)
            idx.append(np.stack([np.full(n, ci), ring[:-1], ring[1:]], axis=1))
        for e in extra:
            pos, nrm, uv, base = (np.concatenate([a, b]) for a, b in zip((pos, nrm, uv, base), e))
        return pos, nrm, uv, base, np.concatenate(idx).reshape(-1)

    def bake(self, img: np.ndarray, paint) -> None:
        """Fill this grid's UV rect of img by painting the 3D point under each texel.
        paint(P, N, t, a) gets positions, normals, t (0..1 along the loft) and a
        (0..1 around it); it returns RGB or RGBA."""
        size = img.shape[0]
        G, N = self.G, self.N
        R, n = G.shape[:2]
        close = lambda a: np.concatenate([a, a[:, :1]], axis=1)  # noqa: E731
        Gs, Ns = close(G), close(N)
        u0, v0, u1, v1 = self.uvrect
        xs = np.arange(int(round(u0 * size)), int(round(u1 * size)))
        ys = np.arange(int(round(v0 * img.shape[0])), int(round(v1 * img.shape[0])))
        kf = np.clip(((xs + 0.5) / size - u0) / (u1 - u0) * n, 0, n - 1e-6)
        rf = np.clip(((ys + 0.5) / img.shape[0] - v0) / (v1 - v0) * (R - 1), 0, R - 1 - 1e-6)
        KF, RF = np.meshgrid(kf, rf)
        k0, r0 = KF.astype(int), RF.astype(int)
        fk, fr = (KF - k0)[..., None], (RF - r0)[..., None]

        def bil(A):
            return ((A[r0, k0] * (1 - fk) + A[r0, k0 + 1] * fk) * (1 - fr)
                    + (A[r0 + 1, k0] * (1 - fk) + A[r0 + 1, k0 + 1] * fk) * fr)
        P, Nn = bil(Gs).reshape(-1, 3), norm(bil(Ns).reshape(-1, 3))
        col = np.asarray(paint(P, Nn, (RF / (R - 1)).reshape(-1), (KF / n).reshape(-1)))
        img[ys[0]:ys[-1] + 1, xs[0]:xs[-1] + 1, :col.shape[1]] = col.reshape(len(ys), len(xs), -1)


def emit(part: SkinPart, grid: Grid, weights, mirrored=True, keep=None) -> None:
    pos, nrm, uv, base, idx = grid.mesh(keep)
    w = weights(base)
    (part.add_both if mirrored else part.add)(pos, nrm, uv, w, idx)


# --------------------------------------------------------------------------
# Skin weights
# --------------------------------------------------------------------------

SPINE_Y = [0.90, 1.02, 1.14, 1.28, 1.47, 1.56]
SPINE_B = ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head"]


def w_torso(P):
    y, ax = P[:, 1], np.abs(P[:, 0])
    W = np.zeros((len(P), NB))
    for j, b in enumerate(SPINE_B):
        W[:, BI[b]] = np.interp(y, SPINE_Y, np.eye(len(SPINE_B))[j])
    left = P[:, 0] >= 0
    sh = 0.85 * clip01((ax - 0.085) / 0.07) * clip01((y - 1.27) / 0.09)
    W *= (1 - sh)[:, None]
    W[left, BI["LeftShoulder"]] += sh[left]
    W[~left, BI["RightShoulder"]] += sh[~left]
    lg = 0.7 * clip01((0.94 - y) / 0.12) * clip01((ax - 0.02) / 0.07)
    W *= (1 - lg)[:, None]
    W[left, BI["LeftUpperLeg"]] += lg[left]
    W[~left, BI["RightUpperLeg"]] += lg[~left]
    return W


def w_leg(P):
    y = P[:, 1]
    W = np.zeros((len(P), NB))
    hips = 0.6 * clip01((y - 0.84) / 0.13)
    t = clip01((0.555 - y) / 0.11)
    f = clip01((0.15 - y) / 0.07)
    W[:, BI["Hips"]] = hips * (1 - t)
    W[:, BI["LeftUpperLeg"]] = (1 - hips) * (1 - t)
    W[:, BI["LeftLowerLeg"]] = t * (1 - f)
    W[:, BI["LeftFoot"]] = t * f
    return W


def arm_s(P):
    return (P - SHOULDER) @ ARM_DIR


def w_arm(P):
    s = arm_s(P)
    W = np.zeros((len(P), NB))
    sh = 0.55 * clip01(-s / 0.07)
    t = clip01((s - 0.235) / 0.09)
    h = clip01((s - 0.50) / 0.05)
    W[:, BI["LeftShoulder"]] = sh
    W[:, BI["LeftUpperArm"]] = (1 - sh) * (1 - t)
    W[:, BI["LeftLowerArm"]] = t * (1 - h)
    W[:, BI["LeftHand"]] = t * h
    return W


def w_foot(P):
    W = np.zeros((len(P), NB))
    toes = clip01((P[:, 2] - 0.085) / 0.05)
    W[:, BI["LeftToes"]] = toes
    W[:, BI["LeftFoot"]] = 1 - toes
    return W


def w_head(P):
    return one_bone(len(P), "Head")


# --------------------------------------------------------------------------
# Body shape
# --------------------------------------------------------------------------

# y, half width, half depth, depth offset (+ = forward), squareness
TORSO_KEYS = np.array([
    (0.790, 0.060, 0.050, -0.005, 2.0),
    (0.830, 0.122, 0.086, -0.008, 2.2),
    (0.880, 0.152, 0.097, -0.014, 2.4),
    (0.940, 0.146, 0.092, -0.006, 2.4),
    (1.000, 0.129, 0.086, 0.000, 2.3),
    (1.070, 0.129, 0.087, 0.004, 2.3),
    (1.140, 0.140, 0.094, 0.009, 2.4),
    (1.210, 0.157, 0.102, 0.013, 2.6),
    (1.270, 0.167, 0.105, 0.011, 2.6),
    (1.320, 0.174, 0.100, 0.004, 2.6),
    (1.370, 0.171, 0.090, -0.006, 2.4),
    (1.410, 0.140, 0.073, -0.012, 2.2),
    (1.440, 0.090, 0.060, -0.012, 2.0),
    (1.470, 0.053, 0.047, -0.008, 2.0),
    (1.520, 0.046, 0.045, 0.000, 2.0),
    (1.570, 0.043, 0.043, 0.006, 2.0),
])


def _smooth_profile():
    ys = np.linspace(TORSO_KEYS[0, 0], TORSO_KEYS[-1, 0], 400)
    cols = [np.interp(ys, TORSO_KEYS[:, 0], TORSO_KEYS[:, c]) for c in range(1, 5)]
    k = np.exp(-0.5 * (np.arange(-12, 13) / 5.0) ** 2)
    k /= k.sum()
    out = []
    for c in cols:
        pad = np.concatenate([np.full(12, c[0]), c, np.full(12, c[-1])])
        out.append(np.convolve(pad, k, mode="valid"))
    return ys, out


_PY, _PROF = _smooth_profile()


def torso_rings(ys, n, inflate=0.0):
    ys = np.asarray(ys, float)
    hx, hz, cz, ex = (np.interp(ys, _PY, c) for c in _PROF)
    inflate = np.broadcast_to(np.asarray(inflate, float), ys.shape)
    centers = np.stack([np.zeros_like(ys), ys, cz], axis=1)
    return loft(centers, (1, 0, 0), (0, 0, 1), hx + inflate, hz + inflate, n, expo=ex)


# y, half width (x), half depth (z), z offset
LEG_KEYS = np.array([
    (0.970, 0.060, 0.074, 0.000),
    (0.880, 0.071, 0.082, 0.002),
    (0.780, 0.072, 0.077, 0.004),
    (0.680, 0.066, 0.070, 0.004),
    (0.580, 0.056, 0.060, 0.004),
    (0.500, 0.050, 0.053, 0.008),
    (0.440, 0.048, 0.052, 0.002),
    (0.380, 0.051, 0.058, -0.008),
    (0.300, 0.047, 0.053, -0.008),
    (0.220, 0.038, 0.042, -0.006),
    (0.140, 0.030, 0.034, -0.010),
    (0.095, 0.032, 0.036, -0.012),
    (0.060, 0.030, 0.034, -0.012),
])


def leg_x(y):
    return np.interp(y, [ANKLE[1], KNEE[1], HIP[1], 1.0], [ANKLE[0], KNEE[0], HIP[0], 0.086])


def leg_rings(ys, n, inflate=0.0):
    ys = np.asarray(ys, float)
    k = LEG_KEYS[::-1]
    hx, hz, cz = (np.interp(ys, k[:, 0], k[:, c]) for c in (1, 2, 3))
    bulk = 1.0 + 0.08 * clip01((0.9 - ys) / 0.1) * clip01((ys - 0.16) / 0.1)   # athletic thighs and calves
    hx, hz = hx * bulk, hz * bulk
    inflate = np.broadcast_to(np.asarray(inflate, float), ys.shape)
    centers = np.stack([leg_x(ys), ys, cz], axis=1)
    return loft(centers, (1, 0, 0), (0, 0, 1), hx + inflate, hz + inflate, n, start=math.pi)


# distance along the arm, radius across (ARM_OUT), radius front/back (Z)
ARM_KEYS = np.array([
    (-0.040, 0.016, 0.016),
    (-0.032, 0.032, 0.032),
    (-0.018, 0.045, 0.045),
    (0.005, 0.053, 0.051),
    (0.050, 0.050, 0.050),
    (0.110, 0.046, 0.049),
    (0.170, 0.043, 0.045),
    (0.235, 0.038, 0.039),
    (0.280, 0.036, 0.038),
    (0.330, 0.040, 0.043),
    (0.400, 0.034, 0.038),
    (0.470, 0.027, 0.032),
    (0.530, 0.021, 0.028),
    (0.560, 0.019, 0.027),
])


def arm_rings(ss, n, inflate=0.0):
    ss = np.asarray(ss, float)
    ra, rb = (np.interp(ss, ARM_KEYS[:, 0], ARM_KEYS[:, c]) for c in (1, 2))
    inflate = np.broadcast_to(np.asarray(inflate, float), ss.shape)
    centers = SHOULDER + ss[:, None] * ARM_DIR
    return loft(centers, ARM_OUT, (0, 0, 1), ra + inflate, rb + inflate, n, start=math.pi)


# Body texture atlas (UV rects: u0, v0, u1, v1)
UV_TORSO = (0.0, 0.0, 0.5, 0.56)
UV_ARM = (0.5, 0.0, 0.72, 0.62)
UV_LEG = (0.72, 0.0, 1.0, 1.0)
UV_FOOT = (0.0, 0.56, 0.3, 0.86)
UV_PALM = (0.3, 0.56, 0.5, 0.76)
UV_FINGER = (0.3, 0.76, 0.4, 0.88)
UV_THUMB = (0.4, 0.76, 0.5, 0.88)

FINGERS = [  # z offset at the knuckle, length, radius
    (0.026, 0.074, 0.0090),
    (0.009, 0.082, 0.0092),
    (-0.009, 0.077, 0.0088),
    (-0.025, 0.062, 0.0080),
]


def finger_path(z0, length, s0=0.615, curl=0.55, steps=5, start=None, direction=None):
    """A gently curling finger: starts along the arm, bends towards the palm."""
    p = SHOULDER + ARM_DIR * s0 + np.array([0, 0, z0]) if start is None else np.asarray(start, float)
    d = ARM_DIR if direction is None else norm(np.asarray(direction, float))
    pts = [p - d * 0.012]
    seg = length / (steps - 1)
    for i in range(steps - 1):
        a = curl * (i + 1) / (steps - 1)
        di = norm(d * math.cos(a) - ARM_OUT * math.sin(a))
        p = p + di * seg
        pts.append(p)
    return np.array(pts)


def build_body():
    grids = {}
    part = SkinPart()
    torso = Grid(torso_rings(np.linspace(0.79, 1.57, 28), 22), UV_TORSO, cap_start=True, cap_end=True)
    emit(part, torso, w_torso, mirrored=False)
    grids["torso"] = torso

    leg = Grid(leg_rings(np.linspace(0.97, 0.06, 24), 14), UV_LEG, cap_end=True)
    emit(part, leg, w_leg)
    grids["leg"] = leg

    arm = Grid(arm_rings(np.linspace(-0.040, 0.56, 22), 12), UV_ARM, cap_start=True)
    emit(part, arm, w_arm)
    grids["arm"] = arm

    # Hand: a flat palm, four curling fingers and a thumb; palm faces the thigh.
    ps = np.linspace(0.515, 0.625, 6)
    t = (ps - ps[0]) / (ps[-1] - ps[0])
    pc = SHOULDER + ps[:, None] * ARM_DIR - ARM_OUT * 0.003
    palm = Grid(loft(pc, ARM_OUT, (0, 0, 1), 0.014 - 0.003 * t, 0.029 + 0.010 * np.sin(t * 2.2), 12,
                     start=math.pi, expo=2.6), UV_PALM, cap_end=True)
    emit(part, palm, lambda P: one_bone(len(P), "LeftHand"))
    grids["palm"] = palm
    for z0, length, r in FINGERS:
        pts = finger_path(z0, length)
        T, a, b = path_frames(pts, ARM_OUT)
        rr = r * np.linspace(1.0, 0.8, len(pts))
        g = Grid(loft(pts, a, b, rr * 0.9, rr, 6, start=math.pi), UV_FINGER, cap_end=True)
        emit(part, g, lambda P: one_bone(len(P), "LeftHand"))
        grids.setdefault("finger", g)
    tstart = SHOULDER + ARM_DIR * 0.535 + np.array([0, 0, 0.024]) - ARM_OUT * 0.008
    pts = finger_path(0, 0.058, curl=0.35, steps=4, start=tstart, direction=ARM_DIR * 0.75 + np.array([0, 0, 0.6]))
    T, a, b = path_frames(pts, ARM_OUT)
    thumb = Grid(loft(pts, a, b, np.linspace(0.011, 0.008, len(pts)), np.linspace(0.012, 0.009, len(pts)), 6,
                      start=math.pi), UV_THUMB, cap_end=True)
    emit(part, thumb, lambda P: one_bone(len(P), "LeftHand"))
    grids["thumb"] = thumb

    # Foot: heel to toes along +Z, flat sole, toes slightly turned out.
    fk = np.array([  # z, centre y, half width, half height
        (-0.072, 0.040, 0.024, 0.030),
        (-0.060, 0.045, 0.032, 0.044),
        (-0.030, 0.052, 0.037, 0.054),
        (0.010, 0.050, 0.040, 0.052),
        (0.050, 0.040, 0.045, 0.040),
        (0.090, 0.028, 0.049, 0.028),
        (0.125, 0.020, 0.050, 0.020),
        (0.155, 0.015, 0.046, 0.015),
        (0.178, 0.012, 0.036, 0.011),
        (0.190, 0.011, 0.020, 0.008),
    ])
    zs = np.linspace(fk[0, 0], fk[-1, 0], 14)
    cy, hw, hh = (np.interp(zs, fk[:, 0], fk[:, c]) for c in (1, 2, 3))
    cx = ANKLE[0] + 0.12 * zs + 0.006 * clip01(zs / 0.1)
    G = loft(np.stack([cx, cy, zs], 1), (1, 0, 0), (0, 1, 0), hw, hh, 14, start=-math.pi / 2, expo=2.5)
    G[..., 1] = np.maximum(G[..., 1], 0.0015)  # flat sole
    foot = Grid(G, UV_FOOT, cap_start=True, cap_end=True)
    emit(part, foot, w_foot)
    grids["foot"] = foot
    return part, grids


# --------------------------------------------------------------------------
# Head, hair, glasses
# --------------------------------------------------------------------------

HEAD_C = np.array([0.0, 1.615, 0.012])
HEAD_R = np.array([0.081, 0.111, 0.099])


def head_point(u, v, inflate=0.0):
    """u around (0.5 = facing +Z), v from the crown (0) to under the chin (1)."""
    u, v = np.asarray(u, float), np.asarray(v, float)
    th, ph = 2 * math.pi * (u - 0.5), math.pi * v
    sx, sy, sz = np.sin(ph) * np.sin(th), np.cos(ph), np.sin(ph) * np.cos(th)
    x, y, z = sx * HEAD_R[0], sy * HEAD_R[1], sz * HEAD_R[2]
    low, up = clip01(-sy), clip01(sy)
    x = x * (1 - 0.30 * low ** 1.3) * (1 + 0.03 * np.sin(ph) ** 8)   # jaw narrows, cheekbones
    z = np.where(z > 0, z * (1 - 0.10 * low ** 2) * (1 - 0.05 * (1 - np.abs(sy))),
                 z * (1 - 0.42 * low ** 1.2) * (1 + 0.07 * up))       # chin forward, skull back
    p = np.stack([x, y, z], axis=-1)
    if np.any(inflate):
        p = p * (1 + np.asarray(inflate)[..., None] / np.maximum(np.linalg.norm(p, axis=-1, keepdims=True), 1e-9))
    return p + HEAD_C


def head_uv(P):
    """Inverse of head_point (approximate) for small parts stuck on the head."""
    d = P - HEAD_C
    u = 0.5 + np.arctan2(d[:, 0], d[:, 2]) / (2 * math.pi)
    v = np.arccos(np.clip(d[:, 1] / HEAD_R[1], -1, 1)) / math.pi
    return np.stack([u, v], 1)


# Hairline height by angle from the front (0) to the back (1): forehead,
# temples, sideburns in front of the ear, over the ear, nape.
HAIRLINE = np.array([(0.0, 1.668), (0.16, 1.664), (0.28, 1.640), (0.36, 1.596), (0.42, 1.600),
                     (0.47, 1.628), (0.58, 1.612), (0.78, 1.555), (1.0, 1.532)])


def hairline_v(u):
    a = np.abs(np.asarray(u) - 0.5) * 2
    y = np.interp(a, HAIRLINE[:, 0], HAIRLINE[:, 1])
    return np.arccos(np.clip((y - HEAD_C[1]) / HEAD_R[1], -1, 1)) / math.pi


def build_head():
    part = SkinPart()
    R, n = 21, 32
    U, V = np.meshgrid(np.arange(n) / n, np.linspace(0, 1, R))
    G = head_point(U, V)
    grid = Grid(G, (0, 0, 1, 1))
    grid.N[0], grid.N[-1] = (0, 1, 0), (0, -1, 0)
    emit(part, grid, w_head, mirrored=False)

    extra = MeshPart()
    # Nose: a small wedge.
    top, tip = (0, 1.628, 0.106), (0, 1.589, 0.127)
    bl, br, bc = (-0.0145, 1.584, 0.107), (0.0145, 1.584, 0.107), (0, 1.581, 0.117)
    for tri in ((top, bl, tip), (top, tip, br), (bl, bc, tip), (bc, br, tip)):
        p = np.array(tri, float)
        nrm = np.cross(p[1] - p[0], p[2] - p[0])
        if nrm[2] + 0.2 * nrm[1] < 0:
            nrm = -nrm
        extra.add(p, np.tile(nrm, (3, 1)), head_uv(p), [0, 1, 2])
    # Ears: flattened ovals tilted back.
    for sx in (-1, 1):
        ear = MeshPart()
        rings, segs = 6, 10
        ph, th = np.meshgrid(np.linspace(0, math.pi, rings), np.linspace(0, 2 * math.pi, segs + 1), indexing="ij")
        loc = np.stack([np.sin(ph) * np.cos(th) * 0.011, np.cos(ph) * 0.030, np.sin(ph) * np.sin(th) * 0.019], -1)
        nl = norm(loc / np.array([0.011, 0.030, 0.019]) ** 2)
        c, s = math.cos(0.25), math.sin(0.25)
        rot = np.array([[1, 0, 0], [0, c, -s], [0, s, c]])
        pos = loc.reshape(-1, 3) @ rot.T + (sx * 0.081, 1.600, -0.005)
        nrm = nl.reshape(-1, 3) @ rot.T
        ear.add(pos, nrm, head_uv(pos), grid_indices(rings, segs + 1))
        pos, nrm, uv, idx = ear.arrays()
        extra.add(pos, nrm, uv, idx)
    part.add_rigid(extra, "Head")
    return part, grid


def build_hair(rng):
    """A full cap over the skull plus layered clumps that follow the hair's
    flow (crown -> down and forward), lifted off the head for messy volume."""
    part = SkinPart()
    R, n = 10, 32
    u = np.arange(n) / n
    t = np.linspace(0, 1, R)[:, None]
    U = np.broadcast_to(u, (R, n))
    V = t * hairline_v(u)[None, :]
    G = head_point(U, V, 0.022 * (1 - t) + 0.008 * t)
    cap = Grid(G, (0, 0, 1, 1))
    cap.N[0] = (0, 1, 0)
    pos, nrm, uv, base, idx = cap.mesh()
    uv = np.stack([np.broadcast_to(np.arange(n + 1) / n, (R, n + 1)).reshape(-1) * 6,
                   np.repeat(np.linspace(0, 1, R), n + 1) * 2], 1)
    part.add(pos, nrm, uv, w_head(pos), idx)

    clumps = []
    for _ in range(64):                       # top and crown: lifted, messy
        clumps.append((rng.uniform(0, 1), rng.uniform(0.04, 0.72), "top"))
    for uu in np.linspace(0.385, 0.615, 10):  # bangs down to the brows
        clumps.append((uu + rng.uniform(-0.01, 0.01), rng.uniform(0.55, 0.75), "bang"))
    for uu in np.linspace(0.0, 1.0, 40, endpoint=False):  # sides and back, lying down
        if abs(uu - 0.5) * 2 > 0.3:
            clumps.append((uu + rng.uniform(-0.01, 0.01), rng.uniform(0.55, 0.9), "side"))
    for uu, tt, kind in clumps:
        uu = uu % 1.0
        vv = tt * float(hairline_v(uu))
        b = head_point(uu, vv, 0.018 * (1 - tt) + 0.008)
        nb = norm(b - HEAD_C)
        flow = head_point(uu, vv + 0.02) - head_point(uu, vv)
        flow = norm(flow + np.array([0, 0, 0.012 if kind == "top" else 0.0]))
        if kind == "top":
            lift, L, r = rng.uniform(0.3, 0.8), rng.uniform(0.055, 0.09), rng.uniform(0.022, 0.032)
        elif kind == "bang":
            lift, r = rng.uniform(0.05, 0.2), rng.uniform(0.014, 0.019)
            L = max(b[1] - (1.649 + rng.uniform(-0.006, 0.004)), 0.02) * 1.15
        else:
            lift, L, r = rng.uniform(0.1, 0.3), rng.uniform(0.04, 0.065), rng.uniform(0.018, 0.026)
        d = norm(flow + lift * nb + rng.normal(0, 0.18, 3))
        pts = [b - nb * 0.012]
        p, di = b.copy(), d
        for k in range(3):                      # bend down towards the tip
            p = p + di * L / 3
            pts.append(p.copy())
            di = norm(di + np.array([0, -0.35, 0]) + 0.15 * flow)
        pts = np.array(pts)
        T, a1, a2 = path_frames(pts, nb)
        ra = r * np.array([1.0, 0.95, 0.6, 0.06])
        Gs = loft(pts, a2, a1, ra, ra * 0.42, 5)   # wide across the scalp, thin away from it
        g = Grid(Gs, (0, 0, 0.6, 1))
        p2, n2, uv2, _, idx2 = g.mesh()
        idx2 = fix_winding(p2, n2, idx2)
        n2 = norm(n2 + 0.8 * nb)                    # soft, clumpy shading
        part.add(p2, n2, uv2 + np.array([rng.uniform(0, 1), 0]), w_head(p2), idx2, wind=False)
    return part


def build_glasses():
    frame, lens = MeshPart(), MeshPart()
    w, h, bar, depth, zc, yc = 0.050, 0.025, 0.0045, 0.005, 0.117, 1.622
    for sx in (-1, 1):
        cx = sx * 0.031
        pieces = MeshPart()
        add_box(pieces, (0, h / 2 - bar / 2, 0), (w, bar, depth))
        add_box(pieces, (0, -h / 2 + bar * 0.35, 0), (w, bar * 0.7, depth))
        add_box(pieces, (-w / 2 + bar / 2, 0, 0), (bar, h, depth))
        add_box(pieces, (w / 2 - bar / 2, 0, 0), (bar, h, depth))
        pos, nrm, uv, idx = pieces.arrays()
        a = -sx * math.radians(9)  # wrap around the face
        rot = np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])
        frame.add(pos @ rot.T + (cx, yc, zc), nrm @ rot.T, uv, idx)
        q = np.array([[-1, -1, 0], [1, -1, 0], [1, 1, 0], [-1, 1, 0]]) * (w / 2 - bar, h / 2 - bar * 0.6, 0)
        lens.add(q @ rot.T + (cx, yc, zc - 0.0005), np.tile(rot @ (0, 0, 1), (4, 1)),
                 [(0, 1), (1, 1), (1, 0), (0, 0)], [0, 1, 2, 0, 2, 3])
        # Temple arm from the hinge back over the ear.
        hinge = np.array([sx * 0.0545, yc + h / 2 - 0.004, zc - 0.006])
        pts = np.array([hinge, (sx * 0.078, yc + 0.007, 0.085), (sx * 0.089, yc + 0.004, 0.03),
                        (sx * 0.089, yc - 0.002, -0.012), (sx * 0.083, yc - 0.022, -0.03)])
        T, a1, a2 = path_frames(pts, np.array([0, 1.0, 0]))
        g = loft(pts, a1, a2, 0.0028, 0.0018, 4, start=math.pi / 4)
        gg = Grid(g, (0, 0, 1, 1), cap_start=True, cap_end=True)
        p2, n2, uv2, _, idx2 = gg.mesh()
        frame.add(p2, n2, uv2, idx2)
    add_box(frame, (0, yc + h / 2 - 0.006, zc + 0.002), (0.013, 0.0035, 0.004))  # bridge
    return frame, lens


# --------------------------------------------------------------------------
# Clothes
# --------------------------------------------------------------------------
# Clothes sit a little outside the body and reuse its skin weights. Openings
# (neck, armholes) are cut by the texture's alpha (alpha-scissor), which
# gives clean, slightly stepped PS3-style edges.

def tank_hole(P):
    """>1 outside the holes; neck scoop front/back and deep armholes."""
    x, y, z = np.abs(P[:, 0]), P[:, 1], P[:, 2]
    front = (x / 0.079) ** 2 + ((y - 1.47) / 0.133) ** 2
    back = (x / 0.076) ** 2 + ((y - 1.48) / 0.078) ** 2
    neck = np.where(z > 0, front, back)
    arm = ((x - 0.207) / 0.086) ** 2 + ((y - 1.372) / 0.114) ** 2
    return np.minimum(neck, arm)


def soft(d, w):
    return np.exp(-(np.asarray(d) / w) ** 2)


def top_inflate(ys):
    """Fitted at the chest, loose at the hem (and always outside the bottoms)."""
    return 0.011 + 0.021 * clip01((1.07 - ys) / 0.16)


def cloth_shade(P, N, col, seed, fold_scale=13, fold=0.09):
    f = vnoise(P * np.array([1.0, 3.2, 1.0]), fold_scale, seed)
    col = col * (1 - fold * clip01((f - 0.55) / 0.35))[:, None]
    return col * (1 - 0.05 * clip01(-N[:, 1] * 2))[:, None]


def build_tank(img):
    part = SkinPart()
    ys = np.linspace(0.90, 1.47, 40)
    G0, G = torso_rings(ys, 56), torso_rings(ys, 56, top_inflate(ys))
    g = Grid(G, (0, 0, 1, 1), base=G0)
    emit(part, g, w_torso, mirrored=False, keep=lambda C: (tank_hole(C) > 0.6) & (C[:, 1] < 1.475))
    white = np.array([236, 236, 233], float)

    def paint(P, N, t, a):
        col = white * (0.955 + 0.06 * fbm(P, 9, 3, 11)[:, None])
        col = cloth_shade(P, N, col, 5, fold=0.08)
        col *= (1 - 0.05 * clip01((1.0 - P[:, 1]) / 0.08))[:, None]
        h = tank_hole(P)
        trim = (h > 1.0) & (h < 1.25)
        col[trim] = white * 0.9
        col[P[:, 1] < 0.915] = white * 0.9                       # hem
        alpha = np.where((h > 1.0) & (P[:, 1] < 1.468), 255.0, 0.0)
        return np.concatenate([col + pixel_noise(len(P), 1.5), alpha[:, None]], 1)
    g.bake(img, paint)
    return part


def build_tshirt(img):
    part = SkinPart()
    ys = np.linspace(0.885, 1.475, 36)
    G0, G = torso_rings(ys, 44), torso_rings(ys, 44, top_inflate(ys) + 0.002)
    torso = Grid(G, (0, 0, 1, 0.68), base=G0)

    def neck(P):
        x, y, z = np.abs(P[:, 0]), P[:, 1], P[:, 2]
        return np.where(z > 0, (x / 0.064) ** 2 + ((y - 1.49) / 0.075) ** 2,
                        (x / 0.064) ** 2 + ((y - 1.50) / 0.055) ** 2)
    emit(part, torso, w_torso, mirrored=False, keep=lambda C: neck(C) > 0.6)
    ss = np.linspace(-0.040, 0.15, 10)
    S0 = arm_rings(ss, 14)
    S = arm_rings(ss, 14, 0.008 + 0.016 * clip01((ss - 0.02) / 0.12))
    sleeve = Grid(S, (0, 0.68, 1, 1), base=S0, cap_start=True)
    emit(part, sleeve, w_arm)
    navy = np.array([38, 48, 92], float)

    def paint(P, N, t, a):
        col = cloth_shade(P, N, navy * (0.95 + 0.08 * fbm(P, 9, 3, 21)[:, None]), 9)
        nk = neck(P)
        col[(nk > 1.0) & (nk < 1.3)] = navy * 0.8
        col[P[:, 1] < 0.9] *= 0.85
        alpha = np.where(nk > 1.0, 255.0, 0.0)
        return np.concatenate([col + pixel_noise(len(P), 1.5), alpha[:, None]], 1)

    def paint_sleeve(P, N, t, a):
        col = paint(P, N, t, a)
        col[arm_s(P) > 0.128, :3] = navy * 0.8
        col[:, 3] = 255
        return col
    torso.bake(img, paint)
    sleeve.bake(img, paint_sleeve)
    return part


def build_bottoms(img, length):
    """Shorts (length 'short') or trousers ('long'): a pelvis piece + two legs."""
    part = SkinPart()
    short = length == "short"
    ys = np.linspace(0.975, 0.785, 9)
    infl = 0.010 + 0.012 * clip01((0.95 - ys) / 0.08)
    pelvis = Grid(torso_rings(ys, 36, infl), (0, 0, 1, 0.3), base=torso_rings(ys, 36), cap_end=True)
    emit(part, pelvis, w_torso, mirrored=False)
    if short:
        ly = np.linspace(0.93, 0.635, 12)
        linf = 0.009 + 0.027 * clip01((0.90 - ly) / 0.24)
    else:
        ly = np.linspace(0.93, 0.07, 28)
        linf = 0.009 + 0.007 * clip01((0.90 - ly) / 0.1) + 0.008 * clip01((0.45 - ly) / 0.35) + 0.006 * clip01((0.2 - ly) / 0.12)
    leg = Grid(leg_rings(ly, 18, linf), (0, 0.3, 1, 1), base=leg_rings(ly, 18))
    emit(part, leg, w_leg)

    base = np.array([31, 31, 34], float) if short else np.array([108, 110, 116], float)
    piping = np.array([125, 125, 130], float) if short else base * 0.82

    def common(P, N, seed):
        col = base * (0.93 + 0.12 * fbm(P, 10, 3, 31)[:, None])
        col = cloth_shade(P, N, col, seed, fold=0.16 if short else 0.07)
        col[P[:, 1] > 0.94] *= 0.78 if short else 0.88     # waistband
        return col

    def paint_pelvis(P, N, t, a):
        col = common(P, N, 13)
        side = (np.minimum(np.abs(a - 0.25), np.abs(a - 0.75)) < 0.011) & (P[:, 1] < 0.94)
        col[side] = piping
        return col + pixel_noise(len(P), 1.5)

    def paint_leg(P, N, t, a):
        col = common(P, N, 17)
        out = np.abs(a - 0.5)                                   # 0 = outer side seam
        col[out < 0.014] = piping
        if short:
            slit = out < 0.03 * clip01((0.685 - P[:, 1]) / 0.05)
            col[slit] = base * 0.45
            col[P[:, 1] < 0.65] *= 1.25                       # hem
        else:
            col[P[:, 1] < 0.095] *= 0.8
        return col + pixel_noise(len(P), 1.5)
    pelvis.bake(img, paint_pelvis)
    leg.bake(img, paint_leg)
    return part


# --------------------------------------------------------------------------
# Textures
# --------------------------------------------------------------------------

def vnoise(P, scale, seed=0):
    """Smooth 3D value noise in 0..1 (consistent across UV seams)."""
    Q = np.asarray(P, float) * scale
    I = np.floor(Q).astype(np.int64)
    F = Q - I
    F = F * F * (3 - 2 * F)

    def h(dx, dy, dz):
        x = ((I[:, 0] + dx) * 73856093) ^ ((I[:, 1] + dy) * 19349663) ^ ((I[:, 2] + dz) * 83492791) ^ (seed * 2654435)
        x &= 0xFFFFFFFF
        x = ((x ^ (x >> 13)) * 1274126177) & 0xFFFFFFFF
        x ^= x >> 16
        return (x & 0xFFFF) / 65535.0
    out = 0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                wgt = ((F[:, 0] if dx else 1 - F[:, 0]) * (F[:, 1] if dy else 1 - F[:, 1])
                       * (F[:, 2] if dz else 1 - F[:, 2]))
                out = out + wgt * h(dx, dy, dz)
    return out


def fbm(P, scale, octaves, seed):
    total, amp, norm_ = 0, 1.0, 0
    for o in range(octaves):
        total = total + amp * vnoise(P, scale * 2 ** o, seed + o)
        norm_ += amp
        amp *= 0.5
    return total / norm_ * 2 - 1


_PIX = np.random.default_rng(99)


def pixel_noise(n, amp):
    return _PIX.normal(0, amp, (n, 1))


SKIN = np.array([218, 164, 120], float)
FACE_SKIN = np.array([224, 172, 130], float)
BRIEFS = np.array([52, 55, 64], float)
HAIR_COL = np.array([30, 25, 22], float)


def skin_base(P, N, seed=1):
    col = SKIN * (0.965 + 0.05 * fbm(P, 8, 3, seed)[:, None])
    col *= (1 + 0.035 * N[:, 1])[:, None]           # faint top light / under shade
    return col


def ellipse(P, c, rx, ry):
    return ((P[:, 0] - c[0]) / rx) ** 2 + ((P[:, 1] - c[1]) / ry) ** 2


def shade(col, amount):
    return col * (1 + np.asarray(amount))[:, None]


def paint_torso(P, N, t, a):
    col = skin_base(P, N)
    x, y = np.abs(P[:, 0]), P[:, 1]
    front = clip01(N[:, 2] * 3)
    col = shade(col, -0.12 * soft(x - 0.165, 0.025) * soft(y - 1.29, 0.04) * clip01(np.abs(N[:, 0]) * 2))  # armpits
    col = shade(col, -0.08 * front * soft(y - (1.195 - 0.15 * (x - 0.08) ** 2), 0.012) * clip01((0.15 - x) / 0.03)
                * clip01((x - 0.01) / 0.02))                                                            # pecs
    col = shade(col, 0.05 * front * soft(y - (1.418 + 0.06 * (x - 0.02)), 0.006) * clip01((0.13 - x) / 0.03))  # collarbones
    col = shade(col, -0.1 * front * clip01((y - 1.47) / 0.04))                                         # under the chin
    for c in ((0.084, 1.233), (-0.084, 1.233)):
        nip = (N[:, 2] > 0.2) & (ellipse(P, c, 0.007, 0.006) < 1)
        col[nip] = [182, 120, 96]
    col[(N[:, 2] > 0.2) & (ellipse(P, (0, 1.035), 0.006, 0.009) < 1)] = SKIN * 0.72          # navel
    brief = y < 0.965
    col[brief] = BRIEFS * (0.95 + 0.08 * fbm(P[brief], 12, 2, 4)[:, None])
    col[(y > 0.944) & (y < 0.965)] = [150, 150, 158]
    return col + pixel_noise(len(P), 1.5)


def paint_leg(P, N, t, a):
    col = skin_base(P, N, 2)
    y = P[:, 1]
    lx = P[:, 0] - leg_x(y)
    front = clip01(N[:, 2] * 2)
    col = shade(col, 0.05 * front * soft(y - 0.50, 0.025) * soft(lx, 0.03))     # kneecap
    col = shade(col, -0.06 * front * soft(y - 0.455, 0.012))                    # under it
    col = shade(col, -0.10 * clip01(-N[:, 2] * 2) * soft(y - 0.49, 0.02))        # back of the knee
    col = shade(col, -0.05 * clip01(-N[:, 2] * 2) * soft(y - 0.37, 0.05))        # calf underside
    col = shade(col, 0.05 * soft(y - 0.105, 0.012) * clip01(np.abs(N[:, 0]) * 2 - 1))  # ankle bones
    col[y > 0.87 - 0.06 * clip01(-lx / 0.04)] = BRIEFS                  # trunks, lower inside
    return col + pixel_noise(len(P), 1.5)


def paint_arm(P, N, t, a):
    col = skin_base(P, N, 3)
    s = arm_s(P)
    col = shade(col, -0.09 * clip01(-N[:, 2] * 2) * soft(s - 0.28, 0.025))      # elbow
    col = shade(col, -0.06 * clip01(N @ -ARM_OUT * 2) * soft(s - 0.27, 0.03))  # inside of the elbow
    col = shade(col, 0.04 * clip01(N[:, 1] * 2) * clip01(-s / 0.03))            # shoulder highlight
    col = shade(col, -0.05 * soft(s - 0.13, 0.05) * clip01(N @ -ARM_OUT * 2))   # under the biceps
    return col + pixel_noise(len(P), 1.5)


def paint_hand(P, N, t, a, nails=False):
    col = skin_base(P, N, 4)
    palm_side = clip01((N @ -ARM_OUT) * 2)[:, None]
    col = col * (1 - 0.45 * palm_side) + np.array([232, 172, 142]) * 0.45 * palm_side
    if nails:
        nail = (t > 0.78) & ((N @ ARM_OUT) > 0.2)
        col[nail] = [236, 204, 186]
    else:
        col = shade(col, -0.06 * soft(t - 0.92, 0.06) * clip01((N @ ARM_OUT) * 2))  # knuckles
    return col + pixel_noise(len(P), 1.5)


def paint_foot(P, N, t, a):
    col = skin_base(P, N, 5)
    z = P[:, 2]
    lx = P[:, 0] - (ANKLE[0] + 0.12 * z + 0.006 * clip01(z / 0.1))   # across the foot, + = outside
    top = N[:, 1] > 0.2
    col[N[:, 1] < -0.5] = [226, 176, 142]                              # sole
    for sep in (-0.022, -0.006, 0.010, 0.025):                        # big toe inside, four small ones
        col[top & (z > 0.130) & (np.abs(lx - sep) < 0.0022)] *= 0.82
    for c, r in ((-0.034, 0.010), (-0.014, 0.0065), (0.002, 0.006), (0.017, 0.0055), (0.032, 0.005)):
        col[top & (np.abs(lx - c) < r * 0.75) & (z > 0.165) & (z < 0.184)] = [236, 200, 178]
    col = shade(col, 0.05 * soft(z + 0.01, 0.012) * clip01(np.abs(N[:, 0]) * 2 - 1) * (P[:, 1] > 0.05))
    return col + pixel_noise(len(P), 1.5)


def make_skin_texture(grids, size=256):
    img = np.zeros((size, size, 3))
    img[:] = SKIN
    grids["torso"].bake(img, paint_torso)
    grids["leg"].bake(img, paint_leg)
    grids["arm"].bake(img, paint_arm)
    grids["palm"].bake(img, paint_hand)
    grids["finger"].bake(img, lambda P, N, t, a: paint_hand(P, N, t, a, nails=True))
    grids["thumb"].bake(img, lambda P, N, t, a: paint_hand(P, N, t, a, nails=True))
    grids["foot"].bake(img, paint_foot)
    return img


def make_face_texture(size=512):
    v, u = np.meshgrid((np.arange(size) + 0.5) / size, (np.arange(size) + 0.5) / size, indexing="ij")
    P = head_point(u.reshape(-1), v.reshape(-1))
    eps = 1.0 / size
    du = head_point(u.reshape(-1) + eps, v.reshape(-1)) - P
    dv = head_point(u.reshape(-1), v.reshape(-1) + eps) - P
    N = norm(np.cross(dv, du))
    N[np.sum(N * (P - HEAD_C), 1) < 0] *= -1
    x, y, z = P[:, 0], P[:, 1], P[:, 2]
    ax = np.abs(x)
    col = FACE_SKIN * (0.975 + 0.04 * fbm(P, 30, 2, 41)[:, None])
    col *= (1 + 0.04 * N[:, 1])[:, None]
    front = z > 0.03
    # Soft shading: under the jaw, cheek hollows, sides of the nose, eye sockets.
    col = shade(col, -0.13 * clip01((-N[:, 1] - 0.25) / 0.4) * clip01((1.565 - y) / 0.03))
    col = shade(col, -0.04 * front * soft(ax - 0.055, 0.012) * soft(y - 1.575, 0.015))
    col = shade(col, -0.06 * front * soft(ax - 0.014, 0.004) * soft(y - 1.600, 0.012))
    col = shade(col, -0.05 * front * soft(ax - 0.031, 0.016) * soft(y - 1.632, 0.008))
    col = shade(col, -0.04 * front * soft(ax - 0.06, 0.012) * soft(y - 1.64, 0.025))   # temples
    # Under the hairline: hair colour so no skin shows between clumps.
    hl = hairline_v(u.reshape(-1))
    col[v.reshape(-1) < hl - 0.01] = HAIR_COL * 1.2
    for sx in (-1, 1):
        bx = sx * x
        # Brows: thick and straight, slightly arched.
        yb = 1.6485 + 0.004 * (1 - ((bx - 0.033) / 0.022) ** 2)
        thick = 0.0034 + 0.0016 * clip01((0.05 - bx) / 0.03)
        col[front & (bx > 0.011) & (bx < 0.056) & (np.abs(y - yb) < thick)] = [42, 32, 27]
        # Eyes: almond shape with lash line, iris and a catch light.
        ex, ey, hw, hh = 0.0315, 1.6225, 0.0135, 0.0058
        dx, dy = bx - ex, y - ey
        hh_x = hh * np.sqrt(clip01(1 - (dx / hw) ** 2)) + 1e-6
        inside = front & (np.abs(dx) < hw) & (np.abs(dy) < hh_x)
        col[inside] = [228, 220, 212]
        iris = inside & (dx ** 2 + (dy + 0.0005) ** 2 < 0.0052 ** 2)
        col[iris] = [52, 36, 28]
        col[inside & (dx ** 2 + (dy + 0.0005) ** 2 < 0.0024 ** 2)] = [14, 10, 10]
        col[inside & ((dx + 0.0018) ** 2 + (dy - 0.0018) ** 2 < 0.0011 ** 2)] = [240, 236, 232]
        col[front & (np.abs(dx) < hw * 1.08) & (dy > hh_x * 0.55) & (dy < hh_x + 0.0019)] = [34, 24, 20]
        col[front & (np.abs(dx) < hw * 0.9) & (np.abs(dy - hh_x - 0.0045) < 0.0009)] *= 0.86   # crease
        col[front & (np.abs(dx) < hw * 0.9) & (dy < -hh_x) & (dy > -hh_x - 0.0012)] *= 0.84   # lower lid
        # Nostrils (they project onto the underside of the nose).
        col[front & (((bx - 0.0075) / 0.0042) ** 2 + ((y - 1.5845) / 0.0022) ** 2 < 1)] = [120, 72, 60]
    # Mouth.
    mx = ax / 0.0195
    curve = 1.5665 - 0.0012 * mx ** 2
    col[front & (mx < 1) & (y > curve) & (y < curve + 0.0042 * (1 - mx ** 2) + 0.0008)] = [176, 108, 92]
    col[front & (mx < 0.92) & (y < curve) & (y > curve - 0.0058 * (1 - mx ** 2))] = [192, 122, 104]
    col[front & (mx < 1.05) & (np.abs(y - curve) < 0.0008)] = [108, 58, 52]
    col = shade(col, -0.05 * front * soft(ax, 0.004) * soft(y - 1.577, 0.004))      # philtrum
    col = shade(col, -0.06 * front * soft(ax, 0.012) * soft(y - 1.548, 0.004))      # under the lip
    col = col + pixel_noise(len(P), 1.2)
    return col.reshape(size, size, 3)


def make_hair_texture(size=64):
    rng = np.random.default_rng(5)
    y, x = np.mgrid[0:size, 0:size]
    strands = rng.uniform(0.8, 1.3, size)
    col = HAIR_COL[None, None, :] * strands[None, x[0], None]
    col = col * (0.85 + 0.25 * (1 - y / size))[..., None]
    col += rng.normal(0, 1.5, col.shape)
    return col


def save(img, name):
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(OUT / "textures" / name, optimize=True)


# --------------------------------------------------------------------------
# Animations
# --------------------------------------------------------------------------

def quat(rx=0.0, ry=0.0, rz=0.0):
    """Rotation applied X, then Y, then Z (q = qz * qy * qx), as (x, y, z, w)."""
    def q(axis, a):
        s = math.sin(a / 2)
        return np.array([axis[0] * s, axis[1] * s, axis[2] * s, math.cos(a / 2)])

    def mul(a, b):
        ax, ay, az, aw = a
        bx, by, bz, bw = b
        return np.array([aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
                         aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz])
    return mul(q((0, 0, 1), rz), mul(q((0, 1, 0), ry), q((1, 0, 0), rx)))


def relaxed_arms(p, swing=0.0, elbow=0.18, out=0.24):
    """Arms down from the A-pose (rest is 22 deg out)."""
    return {"LeftUpperArm": (swing, 0, -out), "RightUpperArm": (-swing, 0, out),
            "LeftLowerArm": (-elbow, 0, 0), "RightLowerArm": (-elbow, 0, 0)}


def pose_idle(p):
    b = math.sin(2 * math.pi * p)
    pose = relaxed_arms(p, 0.0, 0.16 + 0.02 * b)
    pose["LeftUpperArm"] = (0.03 * b, 0, -0.25 - 0.012 * b)
    pose["RightUpperArm"] = (0.03 * b, 0, 0.25 + 0.012 * b)
    pose.update({"Chest": (-0.012 * b, 0, 0), "UpperChest": (-0.018 * b, 0, 0),
                 "Neck": (0.02 * b, 0, 0), "Head": (0.01 * b, 0.03 * math.sin(2 * math.pi * p + 1), 0),
                 "LeftShoulder": (0, 0, 0.01 * b), "RightShoulder": (0, 0, -0.01 * b),
                 "LeftHand": (0, 0, -0.05), "RightHand": (0, 0, 0.05)})
    return pose, (0.003 * math.sin(2 * math.pi * p), -0.004 - 0.002 * b, 0)


def _gait(p, hip_amp, knee_amp, knee_base, arm_amp, elbow, bob, lean, twist):
    pose = {}
    for side, ph in (("Left", 0.0), ("Right", 0.5)):
        a = 2 * math.pi * (p + ph)
        h = hip_amp * math.sin(a)                                  # + = leg forward
        k = knee_base + knee_amp * max(0.0, math.cos(a)) ** 1.5      # bends while swinging forward
        k += 0.25 * knee_amp * max(0.0, -math.sin(a)) * 0.6          # push off
        pose[side + "UpperLeg"] = (-h - lean * 0.5, 0, 0)
        pose[side + "LowerLeg"] = (k, 0, 0)
        pose[side + "Foot"] = (0.75 * (h - k) + lean * 0.4 + 0.25 * max(0.0, -math.sin(a)), 0, 0)
        sgn = 1 if side == "Left" else -1
        pose[side + "UpperArm"] = (arm_amp * math.sin(a), 0, -sgn * 0.26)
        pose[side + "LowerArm"] = (-elbow - 0.25 * elbow * max(0.0, -math.sin(a)), 0, 0)
    s = math.sin(2 * math.pi * p)
    pose["Hips"] = (lean * 0.3, 0.09 * twist * s, 0)
    pose["Spine"] = (lean * 0.5, -0.05 * twist * s, 0)
    pose["Chest"] = (lean * 0.3, -0.07 * twist * s, 0)
    pose["Head"] = (-lean * 0.6, 0.04 * twist * s, 0)
    y = -bob * (0.4 + 0.6 * abs(math.sin(2 * math.pi * p))) - knee_base * 0.03
    return pose, (0, y, 0)


def pose_walk(p):
    return _gait(p, hip_amp=0.42, knee_amp=0.75, knee_base=0.08, arm_amp=0.38, elbow=0.22, bob=0.022, lean=0.04,
                 twist=1.0)


def pose_run(p):
    return _gait(p, hip_amp=0.72, knee_amp=1.45, knee_base=0.25, arm_amp=0.55, elbow=1.5, bob=0.045, lean=0.22,
                 twist=1.6)


ANIMATIONS = [("idle", pose_idle, 3.0), ("walk", pose_walk, 1.0), ("run", pose_run, 0.64)]


def sample_animation(fn, length, fps=24):
    frames = max(int(round(length * fps)), 2)
    times = np.linspace(0, length, frames + 1).astype(np.float32)
    rot = {b[0]: [] for b in BONES}
    hips = []
    for t in times:
        pose, off = fn(float(t) / length % 1.0 if t < length else 0.0)
        for name in rot:
            rot[name].append(quat(*pose.get(name, (0, 0, 0))))
        hips.append(np.array(BONES[BI["Hips"]][2] - BONES[BI["Root"]][2]) + off)
    # Every bone is keyed so switching animations never leaves a bone posed.
    return times, {k: np.array(v, np.float32) for k, v in rot.items()}, np.array(hips, np.float32)


# --------------------------------------------------------------------------
# glTF writer (skinned)
# --------------------------------------------------------------------------

def srgb_to_linear(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def write_skinned_glb(path: Path, root_name: str, meshes, materials: dict, animations=None) -> None:
    """meshes: [(node name, material name, SkinPart)]. materials: name -> spec
    (color, alpha, metallic, roughness, albedo_tex, alpha_mode, double_sided)."""
    gltf: dict = {
        "asset": {"version": "2.0", "generator": "3D-build-for-Youhua/tools/generate_character.py"},
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [], "meshes": [], "skins": [],
        "materials": [], "textures": [], "images": [],
        # Nearest filtering: big crisp texels like a PS3-era game.
        "samplers": [{"magFilter": 9728, "minFilter": 9986, "wrapS": 10497, "wrapT": 10497}],
        "accessors": [], "bufferViews": [], "buffers": [],
    }
    blob = bytearray()

    def view(data: bytes, target=None) -> int:
        while len(blob) % 4:
            blob.append(0)
        v = {"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)}
        if target:
            v["target"] = target
        blob.extend(data)
        gltf["bufferViews"].append(v)
        return len(gltf["bufferViews"]) - 1

    def accessor(arr, kind, target=None, minmax=False) -> int:
        comp = {np.dtype(np.uint32): 5125, np.dtype(np.uint16): 5123, np.dtype(np.float32): 5126}[arr.dtype]
        acc = {"bufferView": view(np.ascontiguousarray(arr).tobytes(), target), "componentType": comp,
               "count": len(arr), "type": kind}
        if minmax:
            a2 = arr.reshape(len(arr), -1)
            acc["min"], acc["max"] = a2.min(axis=0).tolist(), a2.max(axis=0).tolist()
        gltf["accessors"].append(acc)
        return len(gltf["accessors"]) - 1

    tex_ids: dict[str, int] = {}

    def texture(fname: str) -> int:
        if fname not in tex_ids:
            gltf["images"].append({"name": Path(fname).stem, "uri": f"../textures/{fname}"})
            gltf["textures"].append({"sampler": 0, "source": len(gltf["images"]) - 1})
            tex_ids[fname] = len(gltf["textures"]) - 1
        return tex_ids[fname]

    root = {"name": root_name, "children": []}
    gltf["nodes"].append(root)
    bone_node = {}
    for name, parent, gpos in BONES:
        bone_node[name] = len(gltf["nodes"])
        local = gpos - (BONES[BI[parent]][2] if parent else 0)
        gltf["nodes"].append({"name": name, "translation": [float(c) for c in local]})
    for name, parent, _ in BONES:
        if parent:
            gltf["nodes"][bone_node[parent]].setdefault("children", []).append(bone_node[name])
    root["children"].append(bone_node["Root"])
    ibm = np.stack([np.eye(4, dtype=np.float32) for _ in BONES])
    for i, (_, _, gpos) in enumerate(BONES):
        ibm[i, :3, 3] = -gpos
    ibm = np.ascontiguousarray(ibm.transpose(0, 2, 1)).reshape(-1, 16).astype(np.float32)  # column-major
    gltf["skins"].append({"name": "Skeleton", "joints": [bone_node[b[0]] for b in BONES],
                          "skeleton": bone_node["Root"], "inverseBindMatrices": accessor(ibm, "MAT4")})

    mat_ids: dict[str, int] = {}
    for node_name, mat_name, part in meshes:
        if mat_name not in mat_ids:
            spec = materials[mat_name]
            pbr = {"baseColorFactor": [srgb_to_linear(c) for c in spec.get("color", (255, 255, 255))]
                   + [spec.get("alpha", 1.0)],
                   "metallicFactor": spec.get("metallic", 0.0), "roughnessFactor": spec.get("roughness", 0.8)}
            if "albedo_tex" in spec:
                pbr["baseColorTexture"] = {"index": texture(spec["albedo_tex"])}
            mat = {"name": mat_name, "pbrMetallicRoughness": pbr}
            if "alpha_mode" in spec:
                mat["alphaMode"] = spec["alpha_mode"]
                if spec["alpha_mode"] == "MASK":
                    mat["alphaCutoff"] = 0.5
            if spec.get("double_sided"):
                mat["doubleSided"] = True
            gltf["materials"].append(mat)
            mat_ids[mat_name] = len(gltf["materials"]) - 1
        pos, nrm, uv, joints, weights, idx = part.arrays()
        gltf["meshes"].append({"name": node_name, "primitives": [{
            "attributes": {"POSITION": accessor(pos, "VEC3", 34962, True), "NORMAL": accessor(nrm, "VEC3", 34962),
                           "TEXCOORD_0": accessor(uv, "VEC2", 34962), "JOINTS_0": accessor(joints, "VEC4", 34962),
                           "WEIGHTS_0": accessor(weights, "VEC4", 34962)},
            "indices": accessor(idx, "SCALAR", 34963), "material": mat_ids[mat_name]}]})
        root["children"].append(len(gltf["nodes"]))
        gltf["nodes"].append({"name": node_name, "mesh": len(gltf["meshes"]) - 1, "skin": 0})

    if animations:
        gltf["animations"] = []
        for anim_name, fn, length in animations:
            times, rots, hips = sample_animation(fn, length)
            t_acc = accessor(times, "SCALAR", minmax=True)
            samplers, channels = [], []
            for bone, q in rots.items():
                samplers.append({"input": t_acc, "output": accessor(q, "VEC4"), "interpolation": "LINEAR"})
                channels.append({"sampler": len(samplers) - 1, "target": {"node": bone_node[bone], "path": "rotation"}})
            samplers.append({"input": t_acc, "output": accessor(hips, "VEC3"), "interpolation": "LINEAR"})
            channels.append({"sampler": len(samplers) - 1, "target": {"node": bone_node["Hips"], "path": "translation"}})
            gltf["animations"].append({"name": anim_name, "samplers": samplers, "channels": channels})

    while len(blob) % 4:
        blob.append(0)
    gltf["buffers"].append({"byteLength": len(blob)})
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob)))
        f.write(struct.pack("<II", len(js), 0x4E4F534A))
        f.write(js)
        f.write(struct.pack("<II", len(blob), 0x004E4942))
        f.write(blob)


# --------------------------------------------------------------------------

MATERIALS = {
    "Skin": {"albedo_tex": "student_skin.png", "roughness": 0.72},
    "Face": {"albedo_tex": "student_face.png", "roughness": 0.7},
    "Hair": {"albedo_tex": "student_hair.png", "roughness": 0.85},
    "GlassesFrame": {"color": (22, 22, 24), "roughness": 0.35},
    "GlassesLens": {"color": (210, 225, 235), "alpha": 0.12, "roughness": 0.08, "alpha_mode": "BLEND"},
    "TankTopWhite": {"albedo_tex": "top_tank_white.png", "roughness": 0.9, "double_sided": True,
                     "alpha_mode": "MASK"},
    "TShirtNavy": {"albedo_tex": "top_tshirt_navy.png", "roughness": 0.9, "double_sided": True,
                   "alpha_mode": "MASK"},
    "ShortsBlack": {"albedo_tex": "bottom_shorts_black.png", "roughness": 0.85, "double_sided": True},
    "TrousersGrey": {"albedo_tex": "bottom_trousers_grey.png", "roughness": 0.9, "double_sided": True},
}


def main() -> None:
    (OUT / "models").mkdir(parents=True, exist_ok=True)
    (OUT / "textures").mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(1234)

    body, grids = build_body()
    head, _ = build_head()
    hair = build_hair(rng)
    frame, lens = build_glasses()
    glasses, glass_lens = SkinPart(), SkinPart()
    glasses.add_rigid(frame, "Head")
    glass_lens.add_rigid(lens, "Head")
    for part in (head, hair, glasses, glass_lens):
        part.transform(HEAD_SCALE, BONES[BI["Head"]][2], np.array([0, -HEAD_DROP, 0]))
    save(make_skin_texture(grids), "student_skin.png")
    save(make_face_texture(), "student_face.png")
    save(make_hair_texture(), "student_hair.png")
    write_skinned_glb(OUT / "models" / "student_base.glb", "Student",
                      [("BodyMesh", "Skin", body), ("HeadMesh", "Face", head), ("HairMesh", "Hair", hair),
                       ("GlassesMesh", "GlassesFrame", glasses), ("GlassesLensMesh", "GlassesLens", glass_lens)],
                      MATERIALS, ANIMATIONS)

    clothes = [
        ("top_tank_white", "TankTop", "TankTopWhite", build_tank, 256),
        ("top_tshirt_navy", "TShirt", "TShirtNavy", build_tshirt, 128),
        ("bottom_shorts_black", "Shorts", "ShortsBlack", lambda img: build_bottoms(img, "short"), 128),
        ("bottom_trousers_grey", "Trousers", "TrousersGrey", lambda img: build_bottoms(img, "long"), 256),
    ]
    for fname, node, mat, builder, size in clothes:
        img = np.full((size, size, 4), 255.0)
        part = builder(img)
        if not MATERIALS[mat].get("alpha_mode"):
            img = img[..., :3]
        save(img, f"{fname}.png")
        write_skinned_glb(OUT / "models" / f"{fname}.glb", node, [(node + "Mesh", mat, part)], MATERIALS)

    for name, part in (("body", body), ("head", head), ("hair", hair), ("glasses", glasses)):
        print(f"{name}: {len(part.arrays()[5]) // 3} tris")
    pos = body.arrays()[0]
    print("body height", pos[:, 1].max(), "hair top", hair.arrays()[0][:, 1].max())


if __name__ == "__main__":
    main()
