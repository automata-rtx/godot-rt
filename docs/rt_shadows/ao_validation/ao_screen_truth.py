"""Reference B: the best a screen space method could do.

Reference A (ao_truth.py) traces the real geometry, so it measures the ceiling
of the technique. This one marches the SAME rays against a depth buffer built
from the camera's own view, so an occluder the camera cannot see does not
occlude. The gap between A and B is what screen space costs; the gap between B
and the shader is what the implementation gets wrong."""

import math
import os
import sys

import numpy as np
from scenes import active

BOXES, LO, HI, CAM_POS, CAM_TARGET = active()

FOV, W, H, STRIDE, SAMPLES, STEPS, EPS = 75.0, 720, 720, 4, 96, 24, 1e-3


def basis():
    f = CAM_TARGET - CAM_POS
    f /= np.linalg.norm(f)
    r = np.cross(f, np.array([0.0, 1.0, 0.0]))
    r /= np.linalg.norm(r)
    return f, r, np.cross(r, f)


F, R, U = basis()
TAN = math.tan(math.radians(FOV) * 0.5)


def intersect(o, d, tmax):
    inv = 1.0 / np.where(np.abs(d) < 1e-12, 1e-12, d)
    bt = np.full(len(d), np.inf)
    bi = np.full(len(d), -1, np.int32)
    for i in range(len(LO)):
        t0 = (LO[i] - o) * inv
        t1 = (HI[i] - o) * inv
        tn = np.maximum.reduce(np.minimum(t0, t1), axis=1)
        tf = np.minimum.reduce(np.maximum(t0, t1), axis=1)
        t = np.where(tn > EPS, tn, tf)
        ok = (tf > np.maximum(tn, EPS)) & (t > EPS) & (t < tmax) & (t < bt)
        bt = np.where(ok, t, bt)
        bi = np.where(ok, i, bi)
    return bt, bi


def box_normal(p, i):
    c = (LO[i] + HI[i]) * 0.5
    e = (HI[i] - LO[i]) * 0.5
    d = (p - c) / e
    n = np.zeros_like(d)
    ax = np.argmax(np.abs(d), axis=1)
    n[np.arange(len(d)), ax] = np.sign(d[np.arange(len(d)), ax])
    return n


def onb(n):
    a = np.where(np.abs(n[:, 2:3]) < 0.9, np.array([0.0, 0.0, 1.0]), np.array([1.0, 0.0, 0.0]))
    t = np.cross(n, a)
    t /= np.linalg.norm(t, axis=1, keepdims=True)
    return t, np.cross(n, t)


def to_screen(p):
    """World point -> (px, py, view depth). View depth is distance along the
    camera's forward axis, which is what the engine's depth buffer stores."""
    rel = p - CAM_POS
    z = rel @ F
    x = rel @ R
    y = rel @ U
    safe = np.maximum(z, 1e-6)
    px = ((x / (safe * TAN)) * 0.5 + 0.5) * W
    py = (0.5 - (y / (safe * TAN)) * 0.5) * H
    return px, py, z


def main(radius, thickness, out_path):
    # Full resolution depth buffer from the camera's own view.
    gx, gy = np.meshgrid(np.arange(W), np.arange(H))
    ndc_x = (gx.ravel() + 0.5) / W * 2 - 1
    ndc_y = 1 - (gy.ravel() + 0.5) / H * 2
    d = R * (ndc_x * TAN)[:, None] + U * (ndc_y * TAN)[:, None] + F
    d /= np.linalg.norm(d, axis=1, keepdims=True)
    t, bi = intersect(CAM_POS, d, 1e9)
    P_all = CAM_POS + d * t[:, None]
    zbuf = np.where(bi >= 0, (P_all - CAM_POS) @ F, np.inf).reshape(H, W)

    xs = np.arange(0, W, STRIDE)
    ys = np.arange(0, H, STRIDE)
    sx, sy = np.meshgrid(xs, ys)
    flat = sy.ravel() * W + sx.ravel()
    hit = (bi >= 0)[flat]
    P = P_all[flat]
    N = np.zeros_like(P)
    N[hit] = box_normal(P[hit], bi[flat][hit])

    ao = np.full(len(flat), np.nan)
    idx = np.flatnonzero(hit)
    rng = np.random.default_rng(99)
    CHUNK = 1500
    for s in range(0, len(idx), CHUNK):
        sel = idx[s : s + CHUNK]
        p = P[sel] + N[sel] * EPS
        n = N[sel]
        tg, bt = onb(n)
        m = len(sel)
        u1 = rng.random((m, SAMPLES))
        u2 = rng.random((m, SAMPLES))
        rr = np.sqrt(u1)
        th = 2 * np.pi * u2
        dirs = (
            tg[:, None, :] * (rr * np.cos(th))[:, :, None]
            + bt[:, None, :] * (rr * np.sin(th))[:, :, None]
            + n[:, None, :] * np.sqrt(np.maximum(1 - u1, 0))[:, :, None]
        ).reshape(-1, 3)
        orig = np.repeat(p, SAMPLES, axis=0)
        rad = np.full(len(orig), radius)
        if os.environ.get("AO_DIST_RADIUS"):
            zc = (P[sel] - CAM_POS) @ F
            rad = np.repeat(float(os.environ["AO_DIST_RADIUS"]) * 2.0 * TAN * zc, SAMPLES)
        blocked = np.zeros(len(orig), bool)
        for k in range(1, STEPS + 1):
            q = orig + dirs * (rad * (k / STEPS))[:, None]
            px, py, qz = to_screen(q)
            ix = np.clip(px.astype(np.int32), 0, W - 1)
            iy = np.clip(py.astype(np.int32), 0, H - 1)
            surf = zbuf[iy, ix]
            inside = (px >= 0) & (px < W) & (py >= 0) & (py < H) & np.isfinite(surf)
            # Behind the visible surface, but not so far behind that the ray has
            # passed out the back of it -- the same finite thickness the shader
            # assumes, so this compares estimators rather than thickness policy.
            blocked |= inside & (qz > surf + 1e-3) & (qz < surf + thickness * rad)
        ao[sel] = 1.0 - blocked.reshape(m, SAMPLES).mean(axis=1)
        print("  %d/%d" % (min(s + CHUNK, len(idx)), len(idx)), file=sys.stderr, flush=True)

    np.savez_compressed(
        out_path,
        ao=ao.reshape(len(ys), len(xs)),
        hit=hit.reshape(len(ys), len(xs)),
        stride=STRIDE,
        w=W,
        h=H,
        radius=radius,
    )
    v = ao[hit]
    print(
        "screen-space reference: radius %.2f thickness %.2f  AO mean %.4f min %.4f"
        % (radius, thickness, v.mean(), v.min())
    )


if __name__ == "__main__":
    main(float(sys.argv[1]), float(sys.argv[2]), sys.argv[3])
