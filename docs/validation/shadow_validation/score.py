#!/usr/bin/env python3
"""Score a screen space shadow render against a raytraced render of the same scene.

    python3 score.py out/                     # every hN_tN.png in that directory
    python3 score.py out/ --srgb              # also print the gamma-space numbers
    python3 score.py out/ --bands             # stratify by distance from camera
    python3 score.py out/ --overlay agree.png # draw where the two disagree

THE ONE RULE
------------
A PNG is sRGB encoded. Differencing two of them measures GAMMA SPACE, not light,
and a darkness ratio read off that difference is not the ratio of light the two
shadows remove. Every published screen space number was first taken that way and
had to be re-derived; see the head of the screen space section of FINDINGS.md.
Everything here decodes to linear first, and --srgb exists only so a stale number
can be identified as gamma-space rather than as a regression.

WHY THERE IS NO SEGMENTATION MASK
---------------------------------
The captures differ ONLY in the shadow term -- same geometry, same camera, same
light, same exposure -- so the luminance a capture loses relative to a_off IS the
shadow, everywhere, including on the blades themselves. An earlier rig masked
blade pixels out because it was measuring a shadow's WIDTH on open ground; at
80% coverage that throws away most of the signal, because most shadow then falls
on other blades.

THE THREE NUMBERS, AND WHY IT IS NOT ONE
----------------------------------------
    mass      total light removed, relative to the trace's. Threshold free, no
              selection bias, and the only one of the three that is safe to tune
              `surface_thickness` against.
    area      how many pixels it shadows at all, relative to the trace's.
    darkness  mass / area: "when it does find a shadow, is that shadow as dark as
              the trace's?" This is the number `hardness` moves, and separating it
              from area is the entire reason `hardness` could be tuned at all.

They must be read together. The screen space pass systematically overshoots
darkness while undershooting area -- where the march finds the occluder it
commits fully, and where it does not there is nothing at all -- so a single
figure of merit hides which half is wrong.
"""

import argparse
import math
import os
import re
import sys

import numpy as np
from PIL import Image

# The difference below which a pixel is called unshadowed. Deliberately the same
# NUMBER in both spaces -- 8 of 255 -- and therefore NOT the same amount of light:
# 8/255 of linear range is a far smaller physical difference than 8 sRGB codes are
# down in the dark end. That is fine because the threshold only ever selects which
# pixels to count, and both spaces are scored against a reference selected the
# same way, but it does mean the two spaces count slightly different pixel sets
# and their `area` columns are not directly comparable.
THRESH_SRGB = 8.0
THRESH_LINEAR = 8.0 / 255.0

# field.gd's framing, for --bands. Override with --camera if a rig is changed.
CAM_H, CAM_PITCH, CAM_VFOV = 1.00, 36.0, 55.0


def _rgb(path):
    return np.asarray(Image.open(path).convert("RGB")).astype(np.float32)


def _lum(a, space):
    if space == "srgb":
        return a.mean(axis=2)
    x = a / 255.0
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4).mean(axis=2)


def _deficit(base, img, space):
    """Light removed relative to the unshadowed baseline, clamped at zero.

    Clamping matters: this pass composes with min() and can only ever darken, so
    a negative deficit is noise or a bug, and a run reporting lightened pixels is
    reporting that the composition is wrong. --verbose prints the count.
    """
    return np.clip(_lum(base, space) - _lum(img, space), 0.0, None)


def _variants(out_dir):
    """Every capture that is not the baseline or the reference, sorted."""
    names = []
    for f in sorted(os.listdir(out_dir)):
        if not f.endswith(".png"):
            continue
        stem = f[:-4]
        if stem in ("a_off", "b_rt"):
            continue
        if re.fullmatch(r"h[\d.]+_t[\d.]+", stem) or stem.startswith("x_"):
            names.append(stem)

    # Numeric, not lexical: a sweep sorted as strings puts h0.25 before h0, which
    # reads as noise rather than as the monotonic curve it is.
    def key(stem):
        m = re.fullmatch(r"h([\d.]+)_t([\d.]+)", stem)
        return (0, float(m.group(2)), float(m.group(1))) if m else (1, 0.0, 0.0)

    return sorted(names, key=key)


def score(out_dir, space, verbose=False):
    base = _rgb(os.path.join(out_dir, "a_off.png"))
    ref = _deficit(base, _rgb(os.path.join(out_dir, "b_rt.png")), space)
    th = THRESH_SRGB if space == "srgb" else THRESH_LINEAR
    rsel = ref > th
    r_mass, r_dark, r_area = ref.sum(), ref[rsel].mean(), int(rsel.sum())

    print("%-8s  reference: %d px shadowed, %.4g removed per px" % (space.upper(), r_area, r_dark))
    print("  %-26s %9s %9s %9s" % ("variant", "darkness", "mass", "area"))
    rows = {}
    for name in _variants(out_dir):
        d = _deficit(base, _rgb(os.path.join(out_dir, name + ".png")), space)
        sel = d > th
        mass = d.sum() / r_mass
        area = int(sel.sum()) / r_area
        # Darkness is mass divided by area, deliberately, rather than a mean over
        # the thresholded pixels: it is the definition the published tables use,
        # and the two differ by a few thousandths because a mean discards the
        # sub-threshold deficits that mass still counts.
        row = (mass / max(area, 1e-9), mass, area)
        rows[name] = row
        print("  %-26s %9.3f %9.3f %9.3f" % (name, row[0], row[1], row[2]))
        if verbose:
            lit = int((_lum(base, space) - _lum(_rgb(os.path.join(out_dir, name + ".png")), space) < -th).sum())
            print("      %d px LIGHTENED (must be 0; min() composition can only darken)" % lit)
    return rows


def bands(out_dir, cam_h, pitch, vfov, blade_depth=0.010):
    """Stratify mass by distance from the camera.

    A global average over a frame is the number that made `surface_thickness`
    look like it wanted retuning when it did not: near the camera every variant
    undershoots, because a tall blade close up throws a shadow longer than the
    quality tier's march in PIXELS and the tail is never reached, and far away
    every variant overshoots, because the fixed one pixel of rasterization
    overshoot is proportionally huge on a blade under two pixels deep. Thickness
    trades one error against the other, and a frame whose near bands carry most
    of the mass averages them into an apparent match.
    """
    base = _rgb(os.path.join(out_dir, "a_off.png"))
    ref = _deficit(base, _rgb(os.path.join(out_dir, "b_rt.png")), "linear")
    h, _w = ref.shape
    v = (np.arange(h) + 0.5) / h
    ang = math.radians(pitch) - np.arctan((1.0 - 2.0 * v) * math.tan(math.radians(vfov) / 2.0))
    dist = cam_h / np.tan(np.maximum(ang, 1e-4))
    px_per_m = h / (2.0 * math.tan(math.radians(vfov) / 2.0))

    names = _variants(out_dir)
    defs = {n: _deficit(base, _rgb(os.path.join(out_dir, n + ".png")), "linear") for n in names}
    print("\nper distance band, LINEAR, mass vs trace")
    print("%13s %7s " % ("band (m)", "bl px") + " ".join("%9s" % n for n in names))
    edges = [0.5, 0.9, 1.3, 1.9, 2.7, 3.8, 5.2, 6.7]
    errs = {n: [] for n in names}
    for lo, hi in zip(edges, edges[1:]):
        sel = (dist >= lo) & (dist < hi)
        r = ref[sel].sum()
        if r < 1e-6:
            continue
        mid = 0.5 * (lo + hi)
        row = "%5.1f-%-7.1f %7.1f " % (lo, hi, blade_depth * px_per_m / mid)
        for n in names:
            m = defs[n][sel].sum() / r
            errs[n].append(abs(m - 1.0))
            row += "%9.3f" % m
        print(row)
    print("mean |error| per band: " + "   ".join("%s=%.2f" % (n, np.mean(errs[n])) for n in names))


def overlay(out_dir, variant, path):
    """Draw WHERE the two disagree, which a table cannot show.

    blue  = shadow only the trace found -- an occluder off screen, or further
            along the ray than the march reaches. Not tunable.
    orange= shadow only the march found.
    white = both agree.
    """
    base = _rgb(os.path.join(out_dir, "a_off.png"))
    ref = _deficit(base, _rgb(os.path.join(out_dir, "b_rt.png")), "linear") > (10.0 / 255.0)
    sh = _deficit(base, _rgb(os.path.join(out_dir, variant + ".png")), "linear") > (10.0 / 255.0)
    h, w = ref.shape
    vis = np.full((h, w, 3), 26, dtype=np.uint8)
    vis[ref & ~sh] = [70, 130, 255]
    vis[sh & ~ref] = [255, 150, 40]
    vis[ref & sh] = [242, 242, 242]
    Image.fromarray(vis).save(path)
    a, o_rt, o_ss = int((ref & sh).sum()), int((ref & ~sh).sum()), int((sh & ~ref).sum())
    t = max(a + o_rt + o_ss, 1)
    print(
        "\n%s: agree %.1f%%   trace only %.1f%%   march only %.1f%%  -> %s"
        % (variant, 100.0 * a / t, 100.0 * o_rt / t, 100.0 * o_ss / t, path)
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out_dir", help="directory holding a_off.png, b_rt.png and the variants")
    ap.add_argument("--srgb", action="store_true", help="also print gamma-space numbers, to identify a stale figure")
    ap.add_argument("--bands", action="store_true", help="stratify mass by distance from the camera")
    ap.add_argument("--overlay", metavar="PNG", help="draw the disagreement map for the first variant")
    ap.add_argument("--verbose", action="store_true", help="also count lightened pixels, which must be zero")
    ap.add_argument(
        "--camera",
        nargs=3,
        type=float,
        metavar=("HEIGHT", "PITCH", "VFOV"),
        default=[CAM_H, CAM_PITCH, CAM_VFOV],
        help="framing for --bands (default: field.gd's)",
    )
    a = ap.parse_args()

    for need in ("a_off.png", "b_rt.png"):
        if not os.path.exists(os.path.join(a.out_dir, need)):
            sys.exit("missing %s in %s -- the run did not finish" % (need, a.out_dir))

    if a.srgb:
        score(a.out_dir, "srgb", a.verbose)
        print()
    score(a.out_dir, "linear", a.verbose)
    if a.bands:
        bands(a.out_dir, *a.camera)
    if a.overlay:
        v = _variants(a.out_dir)
        if v:
            overlay(a.out_dir, v[0], a.overlay)


if __name__ == "__main__":
    main()
