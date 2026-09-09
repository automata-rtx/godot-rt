#!/usr/bin/env python3
"""Is DirectionalLight3D.shadow_opacity linear on a RAYTRACED sun?

    python3 score_opacity.py out/opacity

shadow_opacity is a linear fade of the shadow toward fully lit, so the light a
shadowed pixel loses at 0.5 must be exactly half what it loses at 1.0. If the
fade is applied k times it goes as opacity^k, so fitting the exponent counts the
applications directly -- which is how a double-apply in the raytraced directional
path was found and fixed.

The shadow MAP captures are the CONTROL and the whole reason this is trustworthy.
That path applies the fade exactly once, in code this fork does not touch, so it
MUST read 0.500. The first version of this measurement had it reading 0.336, and
that is what revealed the fault was in the measurement rather than in the engine:
the captures were being differenced in sRGB. Everything here decodes to linear
first. If the control ever moves off 0.500 again, fix the measurement before
believing anything else it says.
"""

import os
import sys

import numpy as np
from PIL import Image

CAPTURES = (("rt_100", 1.00), ("rt_075", 0.75), ("rt_050", 0.50), ("rt_025", 0.25))
THRESH = 0.02  # of full-scale linear


def load(out_dir, name):
    a = np.asarray(Image.open(os.path.join(out_dir, name + ".png")).convert("RGB")).astype(np.float32) / 255.0
    return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4).mean(axis=2)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "out/opacity"
    none = load(out_dir, "a_none")
    lost_full = np.clip(none - load(out_dir, "rt_100"), 0.0, None)
    sel = lost_full > THRESH
    base = lost_full[sel].mean()
    print("%s\n%d px shadowed, %.4f of the light removed at opacity 1.0\n" % (out_dir, int(sel.sum()), base))
    print("  %-8s %8s %8s %10s" % ("capture", "opacity", "ratio", "exponent"))
    worst = 0.0
    for name, o in CAPTURES:
        lost = np.clip(none - load(out_dir, name), 0.0, None)[sel].mean()
        r = lost / base
        if o < 1.0:
            k = np.log(max(r, 1e-9)) / np.log(o)
            worst = max(worst, abs(k - 1.0))
            print("  %-8s %8.2f %8.3f %10.2f" % (name, o, r, k))
        else:
            print("  %-8s %8.2f %8.3f %10s" % (name, o, r, "-"))

    mfull = np.clip(none - load(out_dir, "map_100"), 0.0, None)
    msel = mfull > THRESH
    mhalf = np.clip(none - load(out_dir, "map_050"), 0.0, None)
    rm = mhalf[msel].mean() / mfull[msel].mean()
    km = np.log(max(rm, 1e-9)) / np.log(0.5)
    print("\n  CONTROL, shadow map: ratio %.3f, exponent %.2f -- %s"
          % (rm, km, "sound" if abs(km - 1.0) < 0.08 else "MEASUREMENT AT FAULT, fix it before reading the above"))
    print("  raytraced path: %s (exponent 1 = applied once, 2 = applied twice)"
          % ("LINEAR" if worst < 0.08 else "NOT LINEAR, worst exponent off by %.2f" % worst))


if __name__ == "__main__":
    main()
