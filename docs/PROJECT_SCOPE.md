# Personal-fork scope and local testing preferences

These are owner/project constraints, not engine-wide capabilities. Do not copy
them into unrelated projects as Godot requirements. Source audit: 2026-10-26.

- This fork serves a single-player 3D game; general upstream completeness is not
  the objective. Support decisions still need to be visible in feature guides.
- Follow AMD GI 1.2's pinned implementation as closely as practical. Necessary
  Godot adapters are distinct from changing AMD's algorithms. New algorithmic
  deviations need strong evidence and explicit owner approval; see
  [adapter decisions](AMD_GI_ADAPTER_DECISIONS.md).
- Negative/subtractive GI lights and orthographic GI are intentionally unsupported
  in the present scope. Ordinary CPU-managed MultiMesh support is required.
  General shader-driven grass geometry tracing is deferred pending its cost.
- Existing game source/assets are outside engine-task edit permission. Rendering
  settings may be used for authorized diagnosis; do not silently persist tests.
- Check the current conversation before running Godot or a game. An old successful
  run, this document, or an archived authorization does not grant new permission.
- For this owner's GI/reflection tests, turn grass off and prefer a bounded
  windowed resolution such as 1280x720. Preserve original saves/preferences.
- The desktop target is an RTX 5090. The laptop target is a Ryzen 7 7840HS with
  Radeon 780M graphics. Do not extrapolate a desktop test into a laptop guarantee.
- Existing game AA policy prefers temporal upscaling or SMAA, with MSAA off. That
  is an authored project choice, not a statement that the engine lacks other AA.

Machine paths, executable checksums, per-run settings and publication history
belong with the relevant evidence. Re-read the real project configuration before
testing; archived screenshots and handoffs may describe older game content.
