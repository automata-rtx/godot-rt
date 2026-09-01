"""A faithful CPU model of the GTAO gather, run against the same depth buffer
the screen space reference marches. Same camera, same projection terms, same
sample pattern, same bitmask. If this and the shader disagree, the shader has a
plumbing bug; if they agree and both miss the reference, the estimator is wrong.
Iterating here costs seconds instead of a rebuild and a software render."""

import math

import numpy as np
from scenes import active

BOXES, LO, HI, CAM_POS, CAM_TARGET, W, H = active()

FOV, STRIDE, EPS = 75.0, 4, 1e-3

SECTORS = 32
PI = math.pi
HALF_PI = PI / 2
STEP_ANG = PI / SECTORS
ROT_C, ROT_S = math.cos(2 * STEP_ANG), math.sin(2 * STEP_ANG)


def basis():
    f = CAM_TARGET - CAM_POS
    f /= np.linalg.norm(f)
    r = np.cross(f, np.array([0.0, 1.0, 0.0]))
    r /= np.linalg.norm(r)
    return f, r, np.cross(r, f)


F, R, U = basis()
TAN = math.tan(math.radians(FOV) * 0.5)
TAN_X = TAN * (W / H)
MUL = np.array([TAN_X * 2.0, TAN * -2.0])
ADD = np.array([-TAN_X, TAN])


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


def gbuffer():
    """Linear view depth and view space normals, exactly as the engine's would be."""
    gx, gy = np.meshgrid(np.arange(W), np.arange(H))
    ndc_x = (gx.ravel() + 0.5) / W * 2 - 1
    ndc_y = 1 - (gy.ravel() + 0.5) / H * 2
    d = R * (ndc_x * TAN_X)[:, None] + U * (ndc_y * TAN)[:, None] + F
    d /= np.linalg.norm(d, axis=1, keepdims=True)
    t, bi = intersect(CAM_POS, d, 1e9)
    P = CAM_POS + d * t[:, None]
    z = np.where(bi >= 0, (P - CAM_POS) @ F, 1e6)
    nw = np.zeros_like(P)
    hit = bi >= 0
    nw[hit] = box_normal(P[hit], bi[hit])
    nv = np.stack([nw @ R, nw @ U, nw @ F], axis=1)
    return z.reshape(H, W), nv.reshape(H, W, 3), hit.reshape(H, W)


def build_mips(z, radius, levels=5):
    """Farthest biased, the same weighting the prefilter pass uses."""
    mips = [z]
    fmul, fadd = -1.0 / max(radius, 1e-4), 1.0
    cur = z
    for _ in range(levels - 1):
        h, w = cur.shape[0] // 2 * 2, cur.shape[1] // 2 * 2
        q = np.stack([cur[0:h:2, 0:w:2], cur[0:h:2, 1:w:2], cur[1:h:2, 0:w:2], cur[1:h:2, 1:w:2]])
        far = q.max(axis=0)
        wgt = np.clip((far - q) * fmul + fadd, 0.0, 1.0)
        tot = wgt.sum(axis=0)
        cur = np.where(tot > 1e-4, (wgt * q).sum(axis=0) / np.maximum(tot, 1e-9), far)
        mips.append(cur)
    return mips


def sample_depth(mips, uv, level, snap):
    """textureLod on the NEAREST sampler the effect actually binds. Returns the
    depth and, when asked, the UV of the texel center it came from -- which is
    where that depth describes a surface, and not in general the UV asked for."""
    out = np.empty(len(uv))
    ruv = uv.copy()
    for lv in np.unique(level.astype(np.int32)):
        m = level.astype(np.int32) == lv
        img = mips[lv]
        hh, ww = img.shape
        ix = np.clip((uv[m, 0] * ww).astype(np.int32), 0, ww - 1)
        iy = np.clip((uv[m, 1] * hh).astype(np.int32), 0, hh - 1)
        out[m] = img[iy, ix]
        if snap:
            ruv[m, 0] = (ix + 0.5) / ww
            ruv[m, 1] = (iy + 0.5) / hh
    return out, ruv


def sector_weights(n_angle, open_mask):
    """The shader's closed form, vectorized over pixels. Returns (open, total)."""
    sin_n, cos_n = np.sin(n_angle), np.cos(n_angle)
    bound = n_angle - HALF_PI
    c, s = -cos_n.copy(), -sin_n.copy()
    a_zero = -cos_n * 0.25
    a_low = -c * 0.25 + bound * sin_n * 0.5
    prev = np.zeros_like(n_angle)
    opened = np.zeros_like(n_angle)
    for i in range(SECTORS):
        c, s = c * ROT_C - s * ROT_S, s * ROT_C + c * ROT_S
        bound = bound + STEP_ANG
        a = -c * 0.25 + bound * sin_n * 0.5
        w = np.where(bound <= 0.0, a_low - a, a - 2 * a_zero + a_low)
        opened += np.where((open_mask >> np.uint32(i)) & np.uint32(1) != 0, w - prev, 0.0)
        prev = w
    return opened, prev


def spatial_noise(px, py):
    a = np.modf(52.9829189 * np.modf(px * 0.06711056 + py * 0.00583715)[0])[0]
    b = np.modf(((px.astype(np.int64) ^ py.astype(np.int64)) * 1103515245 % 1024) * (1.0 / 1024.0))[0]
    return a, b


def gather(
    z,
    nv,
    radius=1.0,
    thickness=0.3,
    slices=4,
    steps=8,
    bitmask=True,
    angle_bias=0.03,
    first_step_px=1.0,
    mips=None,
    stride=STRIDE,
    snap=True,
    spacing=1.0,
    thick_mode="const",
    join_tol=None,
    scale_radius_with_distance=True,
    screen_radius=0.05,
):
    if mips is None:
        mips = build_mips(z, radius)
    xs = np.arange(0, W, stride)
    ys = np.arange(0, H, stride)
    sx, sy = np.meshgrid(xs, ys)
    px = sx.ravel().astype(np.float64)
    py = sy.ravel().astype(np.float64)
    ix = sx.ravel()
    iy = sy.ravel()
    cz = z[iy, ix]
    uv = np.stack([(px + 0.5) / W, (py + 0.5) / H], axis=1)
    cpos = np.concatenate([(uv * MUL + ADD) * cz[:, None], cz[:, None]], axis=1)
    vdir = -cpos / np.linalg.norm(cpos, axis=1, keepdims=True)
    nrm = nv[iy, ix]

    if scale_radius_with_distance:
        # The shipped default, and for a long time the branch this model did not
        # have. Anchored to the vertical axis, as the gather is: screen_radius is
        # a fraction of screen HEIGHT, because a camera holds its vertical field
        # of view fixed and a fraction of WIDTH would grow with the aspect ratio.
        srad = np.full(len(px), screen_radius * H)
        world_radius = radius * screen_radius * abs(MUL[1]) * cz
    else:
        world_radius = np.full(len(px), float(radius))
        view_extent = np.maximum(cz, 1e-4)
        srad = (world_radius / np.maximum(abs(MUL[0]) * view_extent, 1e-4)) * W
    srad = np.clip(srad, 2.0, float(W))
    thick = thickness * world_radius

    nz_a, nz_b = spatial_noise(px, py)
    open_sum = np.zeros(len(px))
    total_sum = np.zeros(len(px))

    for sl in range(slices):
        phi = (sl + nz_a) * PI / slices
        sdir = np.stack([np.cos(phi), np.sin(phi)], axis=1)
        ip_uv = uv + sdir * 0.01
        in_plane = np.concatenate([(ip_uv * MUL + ADD) * cz[:, None], cz[:, None]], axis=1) - cpos
        bt = np.cross(in_plane, vdir)
        bt /= np.maximum(np.linalg.norm(bt, axis=1, keepdims=True), 1e-12)
        tg = np.cross(vdir, bt)
        pn = nrm - bt * np.sum(nrm * bt, axis=1, keepdims=True)
        plen = np.linalg.norm(pn, axis=1)
        good = plen > 1e-4
        n_ang = np.arctan2(np.sum(pn * tg, axis=1), np.sum(pn * vdir, axis=1))

        occ = np.zeros(len(px), dtype=np.uint32)
        for side_sign in (1.0, -1.0):
            prev_h = np.zeros(len(px))
            prev_z = np.zeros(len(px))
            prev_ok = np.zeros(len(px), bool)
            for st in range(steps):
                t = (st + nz_b) / steps
                off = np.maximum(np.power(t, spacing) * srad, first_step_px)
                spx = px + sdir[:, 0] * off * side_sign
                spy = py + sdir[:, 1] * off * side_sign
                inside = (spx >= 0) & (spx < W) & (spy >= 0) & (spy < H)
                suv = np.stack([(np.clip(spx, 0, W - 1) + 0.5) / W, (np.clip(spy, 0, H - 1) + 0.5) / H], axis=1)
                mip = np.clip(np.floor(np.log2(np.maximum(off, 1.0))) - 3.0, 0, len(mips) - 1)
                sz, suv = sample_depth(mips, suv, mip, snap)
                spos = np.concatenate([(suv * MUL + ADD) * sz[:, None], sz[:, None]], axis=1)
                delta = spos - cpos
                dist = np.linalg.norm(delta, axis=1)
                ok = inside & (dist > 1e-4) & (dist <= world_radius) & good
                ok &= np.sum(delta * nrm, axis=1) >= dist * angle_bias
                if thick_mode == "const":
                    tk = np.full(len(dist), thick)
                elif thick_mode == "prop":
                    tk = thickness * dist
                else:
                    tk = np.maximum(thickness * dist, thick * 0.25)
                back = delta - vdir * tk[:, None]
                fa = np.arctan2(np.sum(delta * tg, axis=1), np.sum(delta * vdir, axis=1))
                ba = np.arctan2(np.sum(back * tg, axis=1), np.sum(back * vdir, axis=1))
                h1 = np.clip((fa - n_ang + HALF_PI) / PI, 0, 1)
                h2 = np.clip((ba - n_ang + HALF_PI) / PI, 0, 1)
                lo = np.minimum(h1, h2)
                hi = np.maximum(h1, h2)
                if join_tol is not None:
                    # Two steps that landed on the same surface describe one
                    # occluder, not two: close the arc between them.
                    same = prev_ok & ok & (np.abs(sz - prev_z) < join_tol * world_radius)
                    lo = np.where(same, np.minimum(lo, prev_h), lo)
                    hi = np.where(same, np.maximum(hi, prev_h), hi)
                    prev_h = np.where(ok, np.minimum(h1, h2), prev_h)
                    prev_z = np.where(ok, sz, prev_z)
                    prev_ok = prev_ok | ok
                first = np.clip(np.floor(lo * SECTORS).astype(np.int64), 0, SECTORS - 1)
                cnt = np.ceil((hi - lo) * SECTORS).astype(np.int64)
                cnt = np.minimum(cnt, SECTORS - first)
                ok &= cnt > 0
                m = np.where(
                    ok,
                    ((np.uint64(1) << cnt.astype(np.uint64)) - np.uint64(1)) << first.astype(np.uint64),
                    np.uint64(0),
                )
                occ |= m.astype(np.uint32)

        if bitmask:
            om = (~occ).astype(np.uint32)
        else:
            om = np.zeros_like(occ)
            live = np.ones(len(occ), bool)
            for i in range(SECTORS // 2 - 1, -1, -1):
                live &= ((occ >> np.uint32(i)) & np.uint32(1)) == 0
                om |= np.where(live, np.uint32(1) << np.uint32(i), np.uint32(0))
            live = np.ones(len(occ), bool)
            for i in range(SECTORS // 2, SECTORS):
                live &= ((occ >> np.uint32(i)) & np.uint32(1)) == 0
                om |= np.where(live, np.uint32(1) << np.uint32(i), np.uint32(0))
        o, tt = sector_weights(n_ang, om)
        open_sum += np.where(good, plen * o, 0.0)
        total_sum += np.where(good, plen * tt, 0.0)

    vis = np.where(total_sum > 1e-6, open_sum / np.maximum(total_sum, 1e-9), 1.0)
    return np.clip(vis, 0, 1).reshape(len(ys), len(xs))


def apply_transfer(visibility, power=1.0, intensity=1.0):
    """The gather's output transfer, so the model can score what SHIPS and not
    only the raw estimator.

    The harness has always measured at power 1 and intensity 1, where this is the
    identity - which is exactly how a transfer that clipped a third of the tonal
    range to black passed validation twice. Score both.
    """
    open_ = np.power(np.clip(visibility, 0.0, 1.0), power)
    return open_ / np.maximum(open_ + (1.0 - open_) * intensity, 1e-4)


def legacy_transfer(visibility, power=1.0, intensity=1.0, shadow_clamp=0.98):
    """What the shader did before, kept so the regression is measurable."""
    v = np.power(np.clip(visibility, 0.0, 1.0), power)
    return np.clip(1.0 - (1.0 - v) * intensity, 0.0, 1.0)
