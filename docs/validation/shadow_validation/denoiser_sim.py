#!/usr/bin/env python3
"""Simulate the raytraced shadow denoiser's temporal pass and score it.

    python3 denoiser_sim.py              # the 3x3 against 5x5 table FINDINGS.md quotes
    python3 denoiser_sim.py --kernels    # weighted 5x5 gathers against the box
    python3 denoiser_sim.py --radius     # the clamp window each estimator asks for
    python3 denoiser_sim.py --window     # what a tight clamp does to a penumbra
    python3 denoiser_sim.py --quick      # any of the above with fewer frames

WHY THIS EXISTS AND WHY IT IS NOT A RENDER
------------------------------------------
Everything else in this directory captures Godot under Xvfb and scores PNGs.
None of it can say anything about the denoiser: `run.sh` renders with the
denoiser OFF, on settled still frames, deliberately, so that a measurement of
the trace is not a measurement of a filter. That leaves the temporal pass with
no rig at all -- and the temporal pass is where ghosting, steady state noise and
every history clamp question live.

So this reimplements `rt_shadow_temporal.glsl` in numpy and drives it with
synthetic visibility whose true value is known exactly, which a render never
gives you. It is a MODEL, not a measurement: a number from here is worth what
the model's fidelity is worth, and the model is stated below so a reader can
judge it. Label anything published from here as simulated. It is not
interchangeable with a harness number.

WHAT IS MODELED, FAITHFULLY
---------------------------
    - one ray per sample per light, so a tap is Binomial(sample_count, p) /
      sample_count -- the binary taps that the whole clamp argument turns on
    - 8-bit storage of the SQUARE ROOT of visibility, both for the trace's
      output and for the accumulator's own re-read
    - the dithered store: `dither_offset()`'s interleaved gradient hash advanced
      by the conjugate of the golden ratio, subtracted by half a step before
      rounding. Without it the accumulator ratchets darker and a bias
      measurement reads the ratchet instead of the filter
    - the variance decomposition, the clamp, `lag_response`, and the exponential
      window with its R8_UNORM history length

WHAT IS NOT
-----------
    - reprojection. The camera is static, which is deliberately the WORST case
      for ghosting: a static receiver reprojects exactly, so nothing rejects a
      stale tap. It is also the only case where "the true answer" is a fixed
      number a bias can be measured against
    - the a-trous pass. Contact shadows early out of it entirely (see the guard
      comment in `rt_shadow_atrous.glsl`), so for a narrow penumbra the temporal
      pass IS the output. For a wide one, treat the noise here as an upper bound
    - the surface and light-set rejection tests, which never fire on one flat
      receiver lit by one light

THE TWO NUMBERS
---------------
    noise   standard deviation over TIME at a pixel, averaged over the frame.
            This is what reads as a shimmer at rest.
    bias    the largest error in the time-averaged value anywhere across the
            profile. On a penumbra it lands at the SHOULDER, where the gather
            straddles the step into the flat region, and not in the interior.

The RATIO between two configurations is the robust output. The absolute noise
figure depends on the scene, so quote it with the scene attached.
"""

import argparse

import numpy as np

# The shipped defaults, from core/config/project_settings.cpp.
SAMPLES_PER_LIGHT = 1
TEMPORAL_FRAMES = 32.0
LAG_RESPONSE = 1.0
CLAMP_SIGMA = 2.0

SIZE = 48


def dither_offset(height, width, frame):
    """`dither_offset()` from rt_shadow_temporal.glsl, evaluated over a grid."""
    y, x = np.mgrid[0:height, 0:width].astype(np.float64)
    spatial = np.mod(52.9829189 * np.mod(x * 0.06711056 + y * 0.00583715, 1.0), 1.0)
    return np.mod(spatial + frame * 0.61803399, 1.0)


def store(visibility, dither):
    """VIS_ENCODE, dither by half a step, round to 8 bits, VIS_DECODE."""
    encoded = np.sqrt(np.clip(visibility, 0.0, 1.0)) + (dither - 0.5) / 255.0
    return (np.clip(np.rint(encoded * 255.0), 0.0, 255.0) / 255.0) ** 2


def gather(source, kernel):
    """Weighted first and second moments, edge clamped, plus effective tap count.

    The effective count is (sum w)^2 / sum w^2, which is what the variance terms
    want: for the box the shader ships it is exactly the tap count.
    """
    radius = (kernel.shape[0] - 1) // 2
    padded = np.pad(source, radius, mode="edge")
    squared = padded * padded
    height, width = source.shape
    moment1 = np.zeros_like(source)
    moment2 = np.zeros_like(source)
    for dy in range(kernel.shape[0]):
        for dx in range(kernel.shape[1]):
            moment1 += kernel[dy, dx] * padded[dy : dy + height, dx : dx + width]
            moment2 += kernel[dy, dx] * squared[dy : dy + height, dx : dx + width]
    total = kernel.sum()
    return moment1 / total, moment2 / total, (total * total) / (kernel * kernel).sum()


def box(radius):
    return np.ones((2 * radius + 1, 2 * radius + 1))


def separable(row):
    return np.outer(row, row).astype(float)


def run(
    truth,
    kernel,
    samples=SAMPLES_PER_LIGHT,
    clamp_sigma=CLAMP_SIGMA,
    max_history=TEMPORAL_FRAMES,
    lag_response=LAG_RESPONSE,
    frames=700,
    warmup=450,
    seed=20260913,
    old_estimator=False,
    want_radius=False,
):
    """Drive the temporal pass over a static scene. Returns the settled frames.

    With `want_radius`, returns the per-frame clamp sigma instead, so the window
    the estimator asks for can be scored on its own.
    """
    rng = np.random.default_rng(seed)
    height, width = truth.shape
    history = np.zeros_like(truth)
    history_length = np.zeros_like(truth)
    settled = []
    radii = []

    for frame in range(frames):
        # The trace's own store is dithered too, on its own frame counter.
        current = store(
            rng.binomial(samples, truth) / samples,
            dither_offset(height, width, frame + 1000),
        )

        moment1, moment2, taps = gather(current, kernel)
        trials = max(taps * samples, 1.0)
        corrected = (moment1 * trials + 2.0) / (trials + 4.0)
        var_mean = corrected * (1.0 - corrected) / (trials + 4.0)
        var_sampling = corrected * (1.0 - corrected) / max(samples, 1)
        var_measured = np.maximum(moment2 - moment1 * moment1, 0.0)
        if old_estimator:
            # What shipped before the decomposition: the raw spread of the taps,
            # floored by the uncertainty in their mean. Kept so the two can be
            # scored against each other rather than compared from memory.
            sigma = np.maximum(np.sqrt(var_measured), np.sqrt(var_mean))
        else:
            sigma = np.sqrt(np.maximum(var_measured - var_sampling, 0.0) + var_mean)
        radii.append(sigma)

        clamped = np.clip(history, moment1 - sigma * clamp_sigma, moment1 + sigma * clamp_sigma)
        fired = history_length > 0.0
        lag = np.where(fired, np.clip(np.abs(clamped - history), 0.0, 1.0), 0.0)
        history_length = np.where(fired, history_length * (1.0 - lag), history_length)
        history = np.where(fired, clamped, history)

        history_length = np.where(history_length > 0.0, np.minimum(history_length + 1.0, max_history), 1.0)
        # The history length lives in an R8_UNORM normalized by max_history.
        history_length = np.rint(history_length / max_history * 255.0) / 255.0 * max_history

        alpha = np.maximum(1.0 / np.maximum(history_length, 1e-6), lag * lag_response)
        history = store(history + (current - history) * alpha, dither_offset(height, width, frame))
        if frame >= warmup:
            settled.append(history)

    return np.array(radii[warmup:]) if want_radius else np.array(settled)


def noise(settled):
    return float(settled.std(axis=0).mean())


def bias(settled, truth):
    return float(np.abs(settled.mean(axis=0)[0] - truth[0]).max())


def flat(value=0.5):
    return np.full((SIZE, SIZE), value)


def penumbra(pixels):
    """A ramp `pixels` wide, centered, flat 0 and 1 on either side."""
    x = np.arange(SIZE)
    start = (SIZE - pixels) // 2
    return np.tile(np.clip((x - start) / pixels, 0.0, 1.0), (SIZE, 1))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--quick", action="store_true", help="fewer frames")
    parser.add_argument("--kernels", action="store_true", help="weighted 5x5 gathers against the box")
    parser.add_argument(
        "--radius", action="store_true", help="the clamp window this estimator asks for, against the old one"
    )
    parser.add_argument("--window", action="store_true", help="what a tight clamp does to a penumbra, by window length")
    args = parser.parse_args()
    span = dict(frames=300, warmup=180) if args.quick else {}

    if args.radius:
        print(
            "Mean clamp window half-width, two sigma, at the middle of a flat penumbra\n"
            "(p = 0.5), 3x3 gather. This is the quantity that decides whether the clamp\n"
            "can fire at all: two sigma wider than the valid range and nothing is ever\n"
            "outside it.\n"
        )
        print(f"{'samples_per_light':>17s} {'raw spread (old)':>17s} {'decomposed':>11s}")
        for samples in (1, 2, 4, 8):
            row = []
            for old_est in (True, False):
                sig = run(
                    flat(),
                    box(1),
                    samples=samples,
                    old_estimator=old_est,
                    want_radius=True,
                    **span,
                )
                row.append(2.0 * float(sig.mean()))
            print(f"{samples:17d} {row[0]:17.2f} {row[1]:11.2f}")
        print(
            "\nThe old estimator charged the whole per-tap binomial scatter to the signal,\n"
            "and that scatter does not shrink with tap count -- so raising the sample\n"
            "count was the only thing that moved it. The decomposed one is tighter at ONE\n"
            "sample than the old one was at eight."
        )
        return

    if args.window:
        print(
            "Converged value at three points of a penumbra, 3x3 gather, samples 1. A\n"
            "tight window pins the value to the neighborhood mean; the question is whether\n"
            "that expands contrast and eats the penumbra's soft tails.\n"
            "\n"
            "It used to. Before the variance decomposition the window collapsed to its\n"
            "floor wherever the taps happened to agree, and a correct history was yanked\n"
            "to a binary answer -- a true 0.25/0.50/0.75 read 0.15/0.49/0.85 at\n"
            "clamp_sigma 1.0 over 32 frames, which is why the guide used to say the two\n"
            "settings had to move together. They no longer do.\n"
        )
        for width in (8, 16, 32):
            truth = penumbra(width)
            column = truth[0]
            probes = [int(np.argmin(np.abs(column - t))) for t in (0.25, 0.50, 0.75)]
            print(f"  penumbra {width}px" + " " * 14 + "true 0.25  true 0.50  true 0.75")
            for clamp_sigma in (2.0, 1.0, 0.3):
                for frames_ in (32.0, 12.0):
                    mean = run(truth, box(1), clamp_sigma=clamp_sigma, max_history=frames_, **span).mean(axis=0)[0]
                    cells = "  ".join(f"{mean[i]:9.2f}" for i in probes)
                    print(f"    sigma {clamp_sigma:4.1f}  frames {frames_:3.0f}   {cells}")
            print()
        return

    if args.kernels:
        kernels = {
            "3x3 box": separable([1, 1, 1]),
            "5x5 box": separable([1, 1, 1, 1, 1]),
            "5x5 tent (1,2,3,2,1)": separable([1, 2, 3, 2, 1]),
            "5x5 binomial (1,4,6,4,1)": separable([1, 4, 6, 4, 1]),
        }
        print("clamp_sigma 0.3, samples 1, temporal 32 -- the tightest shipped window\n")
        print(f"{'kernel':26s} {'eff taps':>8s} {'flat noise':>11s} {'2px bias':>9s}")
        base = None
        for name, kernel in kernels.items():
            eff = (kernel.sum() ** 2) / (kernel * kernel).sum()
            n = noise(run(flat(), kernel, clamp_sigma=0.3, **span))
            b = bias(run(penumbra(2), kernel, clamp_sigma=0.3, **span), penumbra(2))
            if base is None:
                base = (n, b)
                rel = ""
            else:
                rel = f"   {n / base[0]:.2f}x noise for {b / base[1]:.2f}x bias"
            print(f"{name:26s} {eff:8.1f} {n:11.4f} {b:9.4f}{rel}")
        print(
            "\nWeighted kernels sit ON this line rather than beating it: less noise\n"
            "reduction bought with proportionally less shoulder bias. The box is the\n"
            "far end of a tradeoff curve, not a bad point on it."
        )
        return

    print(
        "samples_per_light 1, temporal_frames 32, lag_response 1.0, static camera.\n"
        "The gather the shader picks is 5x5 when samples < 4 AND clamp_sigma <= 1.0.\n"
    )
    print(f"{'scene':16s} {'sigma':>5s} {'metric':>6s} {'3x3':>8s} {'5x5':>8s} {'ratio':>7s}")
    cases = [
        ("flat p=0.5", flat(), "noise"),
        ("penumbra 32px", penumbra(32), "noise"),
        ("penumbra 2px", penumbra(2), "bias"),
        ("penumbra 4px", penumbra(4), "bias"),
        ("penumbra 8px", penumbra(8), "bias"),
        ("penumbra 16px", penumbra(16), "bias"),
        ("penumbra 32px", penumbra(32), "bias"),
    ]
    for name, truth, metric in cases:
        for clamp_sigma in (2.0, 0.3):
            scores = []
            for radius in (1, 2):
                settled = run(truth, box(radius), clamp_sigma=clamp_sigma, **span)
                scores.append(noise(settled) if metric == "noise" else bias(settled, truth))
            print(
                f"{name:16s} {clamp_sigma:5.1f} {metric:>6s} "
                f"{scores[0]:8.4f} {scores[1]:8.4f} {scores[1] / scores[0]:7.2f}"
            )

    print(
        "\nThe wide gather cuts noise to about 0.62x at every window width, and costs\n"
        "bias only at a penumbra narrower than about sixteen pixels -- where it lands\n"
        "on the shoulder, which is the contact hardening the rest of the denoiser is\n"
        "built to protect. On a wide penumbra it is simply better. Hence the gate."
    )


if __name__ == "__main__":
    main()
