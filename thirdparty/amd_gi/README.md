# AMD GI blue-noise lookup

Source: [AMD Capsaicin](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin),
commit `914b91596cd119eda85fbc1d3c7ee6ac391b1452`.

`blue_noise.h` contains the first two dimensions of
`samplerBlueNoiseErrorDistribution_128x128_OptimizedFor_2d2d2d2d_1spp`,
evaluated at sample index zero using the upstream Sobol, ranking, and scrambling
tables. This is the spatial portion of Capsaicin's `BlueNoiseSampler.rand2()`.
The shader applies the same frame-dependent golden-ratio rotation. The two
dimensions are used only for screen-probe interpolation jitter.

The underlying sampler is from *A Low-Discrepancy Sampler that Distributes
Monte Carlo Errors as a Blue Noise in Screen Space*, Heitz et al.

Regenerate with `python3 thirdparty/amd_gi/generate_blue_noise.py /path/to/Capsaicin`.
The compact precomputed table replaces the three larger runtime tables and uses
32 KiB of GPU storage. It is allocated only when AMD GI is active.

The upstream MIT license is preserved in `LICENSE.txt`.
