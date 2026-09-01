"""Recover the AO term from a render pair and score it against the traced
reference. The ratio of an ambient-only render to the same render with
occlusion disabled IS the occlusion term, so this compares like with like."""

import sys

import numpy as np
from PIL import Image


def to_linear(a):
    a = a / 255.0
    return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)


ref = np.load(sys.argv[1])
truth, hit, stride = ref["ao"], ref["hit"], int(ref["stride"])
noao = to_linear(np.asarray(Image.open(sys.argv[2]).convert("L"), dtype=np.float64))

print("%-26s %7s %7s %7s %7s  %s" % ("variant", "MAE", "RMSE", "bias", "maxerr", "corr"))
print("-" * 74)
for label, path in [a.split("=", 1) for a in sys.argv[3:]]:
    img = to_linear(np.asarray(Image.open(path).convert("L"), dtype=np.float64))
    ao = np.divide(img, noao, out=np.full_like(img, np.nan), where=noao > 1e-4)
    ao = np.clip(ao[::stride, ::stride], 0.0, 1.0)
    m = hit & np.isfinite(ao) & np.isfinite(truth)
    e = ao[m] - truth[m]
    corr = np.corrcoef(ao[m], truth[m])[0, 1]
    print(
        "%-26s %7.4f %7.4f %+7.4f %7.4f  %.4f"
        % (label, np.abs(e).mean(), np.sqrt((e**2).mean()), e.mean(), np.abs(e).max(), corr)
    )

# Where the error lives: bucket by how occluded the reference says the pixel is.
print()
print("error by reference occlusion depth (first variant):")
label, path = sys.argv[3].split("=", 1)
img = to_linear(np.asarray(Image.open(path).convert("L"), dtype=np.float64))
ao = np.clip(np.divide(img, noao, out=np.full_like(img, np.nan), where=noao > 1e-4)[::stride, ::stride], 0, 1)
m = hit & np.isfinite(ao) & np.isfinite(truth)
for lo, hi in [(0.0, 0.4), (0.4, 0.6), (0.6, 0.8), (0.8, 0.95), (0.95, 1.001)]:
    b = m & (truth >= lo) & (truth < hi)
    if b.sum() < 20:
        continue
    e = ao[b] - truth[b]
    print(
        "  truth %.2f-%.2f  n=%6d  mean measured %.3f vs %.3f   bias %+.4f"
        % (lo, hi, b.sum(), ao[b].mean(), truth[b].mean(), e.mean())
    )
