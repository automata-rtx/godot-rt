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
- The former Game Director chat is retired. Omit it from all benchmark coordination
  and release messages. Check for competing workloads locally before timing.
- For this owner's GI/reflection tests, turn grass off and prefer a bounded
  windowed resolution such as 1280x720. Preserve original saves/preferences.
- The desktop target is an RTX 5090. The laptop target is a Ryzen 7 7840HS with
  Radeon 780M graphics. Do not extrapolate a desktop test into a laptop guarantee.
- Existing game AA policy prefers temporal upscaling or SMAA, with MSAA off. That
  is an authored project choice, not a statement that the engine lacks other AA.

Machine paths, executable checksums, per-run settings and publication history
belong with the relevant evidence. Re-read the real project configuration before
testing; archived screenshots and handoffs may describe older game content.

## Local build delivery

Owner instruction, 2026-11-06: after every successful local Windows editor build,
the standard desktop shortcut must represent the newest built editor, including
builds with uncommitted changes. Do not wait for a separate replacement request.
Retain run-permission requirements: updating a shortcut does not authorize launch.

Current shortcut: `Desktop/godot.windows.editor.x86_64.exe - Shortcut.lnk`.
Normal target: `Documents/GodotRT-AMDGI/bin/godot.windows.editor.x86_64.exe`, with
that `bin` directory as its working directory. If an alternate compiler/output
path produces the newer editor, update the target accordingly. After a successful
build, save/read back the shortcut, verify the target exists and record its hash.
Keep any intended launch arguments and required runtime DLL configuration valid.
Failed builds must not be published as successful editor updates; export templates
do not replace the editor shortcut.

`Desktop/GodotRTGI` is reserved for the latest downloaded GitHub Actions version.
Do not copy local editors into that folder. This policy does not automatically
download CI artifacts or certify the folder's current contents. At policy adoption,
it still contains the previously installed local loading-preparation build; replace
that only with an Actions artifact when CI delivery is requested or performed.
The desktop shortcut is the local-build entry point; the Actions folder is separate.
