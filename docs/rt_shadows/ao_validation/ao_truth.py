"""Ray traced ambient occlusion for the validation scene, computed from the
geometry alone. Nothing here reads the engine: the boxes, the camera and the
sampling are all restated independently, so agreement with a render is evidence
and not a tautology."""
import numpy as np, sys, math

BOXES = np.array([
    [ 0.0, -0.1,  0.0, 20.0,  0.2, 20.0],
    [-1.2,  0.35, 0.0,  0.7,  0.7,  0.7],
    [-0.25, 0.35, 0.0,  0.7,  0.7,  0.7],
    [ 0.7,  0.35, 0.0,  0.7,  0.7,  0.7],
    [ 1.65, 0.35, 0.0,  0.7,  0.7,  0.7],
    [ 0.0,  0.8, -1.2,  4.0,  1.6,  0.15],
    [ 1.6,  0.9,  0.9,  1.6,  0.06, 1.0],
])
LO = BOXES[:, :3] - BOXES[:, 3:] * 0.5
HI = BOXES[:, :3] + BOXES[:, 3:] * 0.5

CAM_POS = np.array([3.2, 2.4, 3.2])
CAM_TARGET = np.array([0.0, 0.4, 0.0])
FOV = 75.0
W = H = 720
STRIDE = 4
SAMPLES = 256
EPS = 1e-3

import os as _os
if _os.environ.get("AO_SCENE") == "thin":
    from scene_thin import BOXES as _B, CAM_POS as _CP, CAM_TARGET as _CT
    BOXES = _B
    LO, HI = BOXES[:, :3] - BOXES[:, 3:] * 0.5, BOXES[:, :3] + BOXES[:, 3:] * 0.5
    CAM_POS, CAM_TARGET = _CP, _CT


def basis():
    f = CAM_TARGET - CAM_POS
    f /= np.linalg.norm(f)
    r = np.cross(f, np.array([0.0, 1.0, 0.0]))
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    return f, r, u


def intersect(orig, dirs, tmax):
    """Nearest hit t and box index for each ray; t = inf where nothing is hit."""
    inv = 1.0 / np.where(np.abs(dirs) < 1e-12, 1e-12, dirs)
    best_t = np.full(len(dirs), np.inf)
    best_i = np.full(len(dirs), -1, dtype=np.int32)
    for i in range(len(LO)):
        t0 = (LO[i] - orig) * inv
        t1 = (HI[i] - orig) * inv
        tn = np.maximum.reduce(np.minimum(t0, t1), axis=1)
        tf = np.minimum.reduce(np.maximum(t0, t1), axis=1)
        t = np.where(tn > EPS, tn, tf)
        ok = (tf > np.maximum(tn, EPS)) & (t > EPS) & (t < tmax) & (t < best_t)
        best_t = np.where(ok, t, best_t)
        best_i = np.where(ok, i, best_i)
    return best_t, best_i


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
    b = np.cross(n, t)
    return t, b


def main(radius, out_path):
    f, r, u = basis()
    tan_half = math.tan(math.radians(FOV) * 0.5)

    xs = np.arange(0, W, STRIDE)
    ys = np.arange(0, H, STRIDE)
    gx, gy = np.meshgrid(xs, ys)
    px = gx.ravel().astype(np.float64)
    py = gy.ravel().astype(np.float64)

    ndc_x = (px + 0.5) / W * 2.0 - 1.0
    ndc_y = 1.0 - (py + 0.5) / H * 2.0
    d = (r * (ndc_x * tan_half)[:, None] + u * (ndc_y * tan_half)[:, None] + f)
    d /= np.linalg.norm(d, axis=1, keepdims=True)

    t, bi = intersect(CAM_POS, d, 1e9)
    hit = bi >= 0
    P = CAM_POS + d * t[:, None]
    N = np.zeros_like(P)
    N[hit] = box_normal(P[hit], bi[hit])

    ao = np.full(len(px), np.nan)
    idx = np.flatnonzero(hit)
    rng = np.random.default_rng(12345)

    CHUNK = 3000
    for s in range(0, len(idx), CHUNK):
        sel = idx[s:s + CHUNK]
        p = P[sel] + N[sel] * EPS
        n = N[sel]
        tg, bt = onb(n)
        m = len(sel)
        # Cosine distributed directions, so the plain mean of occlusion IS the
        # cosine weighted visibility the shader is trying to compute.
        u1 = rng.random((m, SAMPLES))
        u2 = rng.random((m, SAMPLES))
        rr = np.sqrt(u1)
        th = 2.0 * np.pi * u2
        lx, ly, lz = rr * np.cos(th), rr * np.sin(th), np.sqrt(np.maximum(1.0 - u1, 0.0))
        dirs = (tg[:, None, :] * lx[:, :, None] + bt[:, None, :] * ly[:, :, None] + n[:, None, :] * lz[:, :, None])
        origins = np.repeat(p, SAMPLES, axis=0)
        dirs = dirs.reshape(-1, 3)
        rad = radius
        if _os.environ.get("AO_DIST_RADIUS"):
            # world_radius = screen_radius * (2 * tan_half_fov) * view_depth,
            # the same quantity the gather derives when it holds the march to a
            # fixed share of the screen instead of a fixed distance.
            zc = (P[sel] - CAM_POS) @ f
            rad = np.repeat(float(_os.environ["AO_DIST_RADIUS"]) * 2.0 * tan_half * zc, SAMPLES)
        tt, _ = intersect(origins, dirs, rad)
        blocked = np.isfinite(tt).reshape(m, SAMPLES)
        ao[sel] = 1.0 - blocked.mean(axis=1)
        print("  %d/%d" % (min(s + CHUNK, len(idx)), len(idx)), file=sys.stderr, flush=True)

    np.savez_compressed(out_path, ao=ao.reshape(len(ys), len(xs)),
                        hit=hit.reshape(len(ys), len(xs)), stride=STRIDE, w=W, h=H, radius=radius)
    v = ao[hit]
    print("traced %d pixels, radius %.2f, AO mean %.4f min %.4f max %.4f" % (len(v), radius, v.mean(), v.min(), v.max()))


if __name__ == "__main__":
    main(float(sys.argv[1]), sys.argv[2])
