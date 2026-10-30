"""Label native captures and measure displayed response; not radiometric truth."""

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser()
parser.add_argument("capture_root", type=Path)
args = parser.parse_args()
root = args.capture_root
variants = ["final-baseline", "final-combined"]
records = [json.loads((root / variant / "capture.json").read_text()) for variant in variants]
for key in [
    "size",
    "fsr2",
    "taa",
    "gi_denoiser",
    "primary_rays_per_pixel",
    "multibounce",
    "reflections",
    "on_settle_frames",
    "captures",
]:
    assert records[0][key] == records[1][key], f"Unmatched {key}"
assert records[0]["fsr2"] is False and records[0]["taa"] is False
assert records[0]["primary_rays_per_pixel"] == 0.25 and records[0]["gi_denoiser"] is True
assert (root / variants[0] / "executable.sha256").read_text().split()[0] == (
    root / variants[1] / "executable.sha256"
).read_text().split()[0]


def image(variant, name):
    return Image.open(root / variant / (name + ".png")).convert("RGB")


def linear(variant, name):
    value = np.asarray(image(variant, name), dtype=np.float64) / 255.0
    return np.where(value <= 0.04045, value / 12.92, ((value + 0.055) / 1.055) ** 2.4)


assert np.array_equal(np.asarray(image(variants[0], "direct_only")), np.asarray(image(variants[1], "direct_only"))), (
    "Direct-only controls differ"
)
font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
font = ImageFont.truetype(font_path, 17)
small = ImageFont.truetype(font_path, 13)


def paired(name, title, note):
    captures = [image(variant, name) for variant in variants]
    width, height = captures[0].size
    assert all(capture.size == (width, height) for capture in captures)
    result = Image.new("RGB", (width, 2 * (height + 35) + 48), (23, 26, 30))
    draw = ImageDraw.Draw(result)
    for index, (capture, label) in enumerate(zip(captures, ["Original AMD path", "All three upgrades"])):
        y = index * (height + 35)
        draw.text((12, y + 8), f"{label}: {title}", font=font, fill="white")
        result.paste(capture, (0, y + 35))
    y = 2 * (height + 35)
    draw.text((12, y + 5), note, font=small, fill=(220, 220, 220))
    draw.text(
        (12, y + 26),
        f"Native {width}x{height} | 1/4 primary ray/pixel | GI denoiser ON | FSR2/TAA OFF",
        font=small,
        fill=(220, 220, 220),
    )
    result.save(root / ("comparison-" + name + ".png"))


paired("on_16", "16 frames after bounce ON", "Same camera, exposure and direct light; only the GI response differs.")
paired("off_32", "32 frames after bounce OFF", "The remaining light is stale bounce. Neither result is instantaneous.")
paired(
    "on_256",
    "settled, 256 frames after bounce ON",
    "Normal quarter sampling throughout; no higher-ray reference rendering.",
)
paired(
    "return_01",
    "first frame after camera returns",
    "Disocclusion stress: compare newly exposed surfaces and lingering patches.",
)
paired(
    "flash_08", "rapid four-frame light pulses", "Stress test, not a claim that flicker or noise has been eliminated."
)

off = linear(variants[0], "off_settled")
settled = linear(variants[0], "on_256")
mask = ((settled - off).mean(axis=2) > 0.002) & (settled.max(axis=2) < 0.9)
measurements: dict[str, object] = {}
metrics = {
    "method": "sRGB PNG converted to display-linear RGB; fixed baseline-derived mask. Mean RGB excess over off image, normalized to each run's on_256. Tonemapped display metric, not radiometric truth or GPU time.",
    "mask_pixels": int(mask.sum()),
    "variants": measurements,
}
for variant in variants:
    names = ["on_04", "on_08", "on_16", "on_32", "on_64", "on_128", "on_256", "off_04", "off_08", "off_16", "off_32"]
    values = {name: float((linear(variant, name) - off)[mask].mean()) for name in names}
    samples = np.array([linear(variant, f"steady_{frame:02d}") for frame in range(16)])
    luminance = samples @ np.array([0.2126, 0.7152, 0.0722])
    measurements[variant] = {
        "raw_response": values,
        "relative_to_own_on256": {name: value / values["on_256"] for name, value in values.items()},
        "mean_luminance": float(luminance.mean(axis=0)[mask].mean()),
        "mean_temporal_std": float(luminance.std(axis=0)[mask].mean()),
    }
(root / "final-metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
print(json.dumps(metrics, indent=2))
