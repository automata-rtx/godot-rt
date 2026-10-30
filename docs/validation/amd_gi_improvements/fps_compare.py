"""Compare matched FPS captures. PNG measurements are display metrics, not ground truth."""

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser()
parser.add_argument("before", type=Path)
parser.add_argument("after", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--before-label", default="Before refinement")
parser.add_argument("--after-label", default="After refinement")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
folders = [args.before, args.after]
reports = [json.loads((folder / "capture.json").read_text()) for folder in folders]
for key in ["size", "fsr2", "taa", "primary_rays_per_pixel", "gi_denoiser", "multibounce", "reflections"]:
    assert reports[0][key] == reports[1][key], f"Different setting: {key}"
assert reports[0]["fsr2"] is False and reports[0]["taa"] is False
assert reports[0]["primary_rays_per_pixel"] == 0.25 and reports[0]["gi_denoiser"] is True
captures = [{record["label"]: record for record in report["captures"]} for report in reports]
common = captures[0].keys() & captures[1].keys()
for name in common:
    assert captures[0][name] == captures[1][name], f"Unmatched scene/timeline at {name}"


def rgb(folder, name):
    return np.asarray(Image.open(folder / f"{name}.png").convert("RGB"), dtype=np.float64) / 255.0


def linear(folder, name):
    value = rgb(folder, name)
    return np.where(value <= 0.04045, value / 12.92, ((value + 0.055) / 1.055) ** 2.4)


def luminance(value):
    return value @ np.array([0.2126, 0.7152, 0.0722])


for name in ["direct_on", "direct_off"]:
    assert np.array_equal(rgb(folders[0], name), rgb(folders[1], name)), f"Different GI-off control: {name}"

height, width = rgb(folders[0], "direct_off").shape[:2]
assert (width, height) == (640, 360), "Review fixed test regions before using another resolution"
regions = {
    "shaded_left": (20, 130, 235, 310),
    "back_wall": (245, 130, 375, 230),
    "partition": (377, 145, 423, 270),
    "weapon": (420, 250, 520, 360),
}
if reports[0]["phase"] == "close":
    regions = {
        "under_bench": (20, 275, 380, 355),
        "back_wall": (180, 60, 440, 210),
        "actor": (445, 170, 580, 300),
        "weapon": (420, 250, 520, 360),
    }
elif reports[0]["phase"] == "cache":
    regions = {
        "shaded_left": (90, 150, 235, 310),
        "back_wall": (340, 130, 418, 220),
        "partition": (270, 120, 315, 280),
        "weapon": (420, 250, 520, 360),
    }
# Interior regions of the receiver's two visible metal faces. The wider
# "weapon" region also contains background and must not alone diagnose specular noise.
regions["weapon_front"] = (470, 320, 510, 345)
regions["weapon_top"] = (450, 280, 475, 300)
masks = {}
for name, (x0, y0, x1, y1) in regions.items():
    mask = np.zeros((height, width), dtype=bool)
    mask[y0:y1, x0:x1] = True
    masks[name] = mask
shade = masks["under_bench" if reports[0]["phase"] == "close" else "shaded_left"].copy()
if reports[0]["phase"] not in ["close", "cache"]:
    shade[145:220, 150:210] = False
masks["diffuse_shade"] = shade


def stack(folder, prefix):
    return np.array([linear(folder, name) for name in sorted(common) if name.startswith(prefix + "_")])


if "torch_steady_00" in common:
    ambient = stack(folders[0], "ambient_steady").mean(axis=0)
    lit = stack(folders[0], "torch_steady").mean(axis=0)
    direct_change = np.abs(luminance(linear(folders[0], "direct_on") - linear(folders[0], "direct_off")))
    # A fixed BEFORE-derived mask: visibly responding pixels outside the direct beam.
    diffuse = np.ones((height, width), dtype=bool)
    # Fixed exclusions for the polished side panel and first-person weapon.
    # Their reflected flashlight is not a diffuse-bounce response measurement.
    if reports[0]["phase"] != "close":
        diffuse[145:220, 150:210] = False
    diffuse[245:360, 395:550] = False
    masks["bounce"] = diffuse & (luminance(lit - ambient) > 0.001) & (direct_change < 0.0005) & (lit.max(axis=2) < 0.9)

measurements: dict[str, object] = {}
responses: dict[str, dict[str, float]] = {}
worst_labels: list[str] = []
for folder in folders:
    result: dict[str, object] = {}
    measurements[str(folder)] = result
    for prefix in ["ambient_steady", "torch_steady", "dark_steady", "corner_steady", "constant"]:
        if prefix + "_00" not in common:
            continue
        samples = luminance(stack(folder, prefix))
        low = np.full((height, width, 3), 255, dtype=np.uint8)
        high = np.zeros_like(low)
        for name in sorted(common):
            if name.startswith(prefix + "_"):
                raw = np.asarray(Image.open(folder / f"{name}.png").convert("RGB"))
                low = np.minimum(low, raw)
                high = np.maximum(high, raw)
        ranges = (high.astype(np.int16) - low.astype(np.int16)).max(axis=2)
        result[prefix] = {
            name: {
                "mean": float(samples[:, mask].mean()),
                "temporal_std": float(samples[:, mask].std(axis=0).mean()),
                "rgb_range_p95_of_255": float(np.percentile(ranges[mask], 95)),
                "rgb_range_max_of_255": int(ranges[mask].max()),
            }
            for name, mask in masks.items()
            if mask.any()
        }
    if all(f"hazard_{index:02d}" in common for index in range(25, 49)):
        # Compare identical phases across three cycles, not adjacent frames:
        # the latter would count the intended light flicker as instability.
        cycles = np.stack([luminance(linear(folder, f"hazard_{index:02d}")) for index in range(25, 49)])
        phase_variation = cycles.reshape(3, 8, height, width).std(axis=0).mean(axis=0)
        result["hazard_same_phase_variation"] = {
            name: float(phase_variation[mask].mean()) for name, mask in masks.items() if mask.any() and name != "bounce"
        }
    if "bounce" in masks and masks["bounce"].any():
        mask = masks["bounce"]
        ambient = stack(folder, "ambient_steady").mean(axis=0)
        lit = stack(folder, "torch_steady").mean(axis=0)
        amplitude = float(luminance(lit - ambient)[mask].mean())
        response = {}
        for name in sorted(common):
            if name.startswith(("torch_on_", "torch_off_")):
                response[name] = float(luminance(linear(folder, name) - ambient)[mask].mean()) / max(amplitude, 1e-9)
        result["bounce_relative_to_own_settled"] = response
        responses[str(folder)] = response
    errors = {}
    convergence_pairs = [
        ("corner_32", "corner_settled"),
        ("actor_32", "actor_settled"),
        ("sweep_32", "sweep_settled"),
    ]
    convergence_pairs += [(name, "corner_settled") for name in sorted(common) if name.startswith("corner_hold_")]
    for first, settled in convergence_pairs:
        if first in common and settled in common:
            difference = np.abs(luminance(linear(folder, first) - linear(folder, settled)))
            errors[first] = {
                name: float(difference[mask].mean()) for name, mask in masks.items() if mask.any() and name != "bounce"
            }
    result["difference_from_own_settled"] = errors
    consecutive = ["corner_32"] + [f"corner_hold_{index:03d}" for index in range(1, 33)]
    if all(name in common for name in consecutive):
        raw_frames = np.stack([
            np.asarray(Image.open(folder / f"{name}.png").convert("RGB"), dtype=np.int16) for name in consecutive
        ])
        steps = np.abs(np.diff(raw_frames, axis=0)).max(axis=3)
        for key, sample_steps in [("stationary_rgb_steps", steps), ("later_rgb_steps", steps[4:])]:
            result[key] = {
                name: {
                    "p99_of_255": float(np.percentile(sample_steps[:, mask], 99)),
                    "max_of_255": int(sample_steps[:, mask].max()),
                    "fraction_over_2": float((sample_steps[:, mask] > 2).mean()),
                    "fraction_over_8": float((sample_steps[:, mask] > 8).mean()),
                }
                for name, mask in masks.items()
                if mask.any() and name != "bounce"
            }
        # Ignore the first four stationary frames for this additional detail-
        # settling illustration; the complete step statistics above retain them.
        scores = (steps[4:, masks["diffuse_shade"]] > 2).mean(axis=1)
        label = consecutive[int(np.argmax(scores)) + 5]
        result["largest_later_diffuse_step"] = label
        worst_labels.append(label)

font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 17)
small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 13)
titles = {
    "ambient_settled": "Steady mixed lighting / shaded recesses",
    "torch_on_016": "16 frames after flashlight ON",
    "torch_on_032": "32 frames after flashlight ON",
    "torch_off_016": "16 frames after flashlight OFF (beam is off)",
    "torch_off_032": "32 frames after flashlight OFF (beam is off)",
    "torch_on_160": "Flashlight settled / noise and detail",
    "sweep_32": "Flashlight moving across surfaces",
    "corner_32": "Camera moving around partition / weapon reflections",
    "corner_hold_001": "Newly exposed surfaces / first stationary frame",
    "corner_hold_008": "Newly exposed surfaces / eight stationary frames",
    "actor_32": "Moving rigid NPC proxy / vacated shadow",
    "muzzle_off_008": "8 frames after three-frame muzzle flash ends",
    "hazard_32": "Rapid alternating emissive hazard",
    "hazard_off_016": "16 frames after emissive hazard OFF",
    "sunset_64": "Moving sun / falling daylight",
    "sun_return_016": "16 frames after daylight returns",
    "turn_16": "Camera turn / polished weapon",
    "turn_hold_096": "Polished weapon / 96 frames after camera stops",
    "weapon_wall_32": "Weapon close to / intersecting partition",
}
for index, label in enumerate(worst_labels):
    if label not in titles:
        titles[label] = f"Largest later diffuse step in {'before' if index == 0 else 'after'} run: {label}"
for name, title in titles.items():
    if name not in common:
        continue
    header = 48
    footer = 2 * (height + header)
    canvas = Image.new("RGB", (width, footer + 52), (23, 26, 30))
    draw = ImageDraw.Draw(canvas)
    for index, (folder, label) in enumerate(zip(folders, [args.before_label, args.after_label])):
        y = index * (height + header)
        draw.text((10, y + 5), label, fill="white", font=font)
        draw.text((10, y + 28), title, fill="white", font=small)
        canvas.paste(Image.open(folder / f"{name}.png"), (0, y + header))
    draw.text(
        (10, footer + 8),
        "Native 640x360 | 1/4 primary ray/pixel | GI denoiser ON | FSR2/TAA OFF",
        fill="white",
        font=small,
    )
    draw.text(
        (10, footer + 29),
        "Same simulation frame and scene. Software Vulkan; no GPU timing claim.",
        fill="white",
        font=small,
    )
    canvas.save(args.output / f"comparison-{name}.png")

report = {
    "method": "Display-linear luminance from tonemapped sRGB PNGs; not radiometric ground truth. Fixed before-derived bounce mask excludes direct beam. Steady noise is per-pixel standard deviation over all shared captures in that steady group (12 frames in main suite; 64 in stability sequence); own-settled comparisons are convergence diagnostics, not correctness proofs.",
    "regions": regions,
    "mask_pixels": {name: int(mask.sum()) for name, mask in masks.items()},
    "variants": measurements,
}
(args.output / "metrics.json").write_text(json.dumps(report, indent=2) + "\n")
if "bounce" in masks and masks["bounce"].any():
    import matplotlib.pyplot as plt

    figure, axes = plt.subplots(2, 1, figsize=(8, 7), constrained_layout=True)
    for folder, label in zip(folders, [args.before_label, args.after_label]):
        values = responses[str(folder)]
        for axis, prefix in zip(axes, ["torch_on_", "torch_off_"]):
            points = sorted(
                (int(name.removeprefix(prefix)), value * 100)
                for name, value in values.items()
                if name.startswith(prefix)
            )
            axis.plot([point[0] for point in points], [point[1] for point in points], marker="o", label=label)
    for axis, title in zip(
        axes, ["Flashlight ON: higher = faster recovery", "Flashlight OFF: lower = less lingering bounce"]
    ):
        axis.set(title=title, xlabel="Frames since switch", ylabel="% of own settled bounce", ylim=(-5, 110))
        axis.grid(alpha=0.25)
        axis.legend()
    figure.suptitle(
        "Diffuse bounce response — fixed non-metallic, indirectly lit pixels\nQuarter sampling; denoiser on; no FSR2/TAA. Display metric, not ground truth.",
        fontsize=11,
    )
    figure.savefig(args.output / "response-curves.png", dpi=120)
    plt.close(figure)
print(json.dumps(report, indent=2))
