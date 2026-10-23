# AMD GI blue-noise lookup

Source: [AMD Capsaicin](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin),
commit `914b91596cd119eda85fbc1d3c7ee6ac391b1452`.

`blue_noise.h` contains the first four dimensions of
`samplerBlueNoiseErrorDistribution_128x128_OptimizedFor_2d2d2d2d_1spp`,
evaluated at sample index zero using the upstream Sobol, ranking, and scrambling
tables. This is the spatial portion of Capsaicin's `BlueNoiseSampler.rand2()`.
The shader applies the same frame-dependent golden-ratio rotation. Interpolation uses dimensions 1/2, glossy rays use 2/3, and reflection
filtering uses 0/1, matching the reference call sites.

The underlying sampler is from *A Low-Discrepancy Sampler that Distributes
Monte Carlo Errors as a Blue Noise in Screen Space*, Heitz et al.

Regenerate with `python3 thirdparty/amd_gi/generate_blue_noise.py /path/to/Capsaicin`.
The compact precomputed table replaces the three larger runtime tables and uses
64 KiB of GPU storage. It is allocated only when AMD GI is active.

The upstream MIT license is preserved in `LICENSE.txt`.

The renderer appends Capsaicin's deterministic `RandomNumberGenerator` seed data
to the same storage buffer: MT19937 seed 5489, at least 1920×1080 uints, enlarged
for larger render dimensions. This does not modify the generated blue-noise table.
The runtime PCG emits the old state before advancing, as in the reference.
