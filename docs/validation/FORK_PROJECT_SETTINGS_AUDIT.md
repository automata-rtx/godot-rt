# Fork project settings audit, 2026-11-05

Compared literal project-setting registrations and the class reference with the
fork's Godot base, `b56a91878e7c94977e4af978968e41d0670c0a8b`. The 100 fork
additions present before the shadow replacement included two retired here.
All 98 remaining keys have runtime consumers. Six reflection-radius keys are
selected by constructing the setting name for the active resolution. This was
a source audit of project settings, excluding stock keys, per-node properties
and editor preferences.

Existing projects may remove saved `denoiser/adaptive_temporal` and
`denoiser/lag_response` entries under RT shadows. The renderer ignores both.
`denoiser/temporal_frames = 1` still selects spatial-only filtering.

| Remaining fork controls | Count | Finding |
| --- | ---: | --- |
| AMD GI, including tuning and diagnostics | 54 | Four material capture controls belong to the reference renderer. The actual GI debug views, sampling choices and denoisers serve distinct purposes. |
| Reference RT GI | 4 | Enables and configures the uncached comparison renderer. Keep available for engine validation. |
| RT shadows | 16 | Removing the temporal mode selector and its legacy lag control left five denoiser settings, including raw output and a spatial-only configuration. |
| Screen-space shadows | 8 | Edge handling, caster selection, quality and debug views affect different parts of the pass. |
| Ground Truth AO / VBAO | 9 | Includes the AO method selector. Some settings apply only to the chosen algorithm or resolution. |
| Streamline and DLSS preset | 7 | Startup paths, diagnostics, quality selection, frame generation and reactive-mask submission each have consumers. |

**Historical recommendation (superseded by the 2026-11-06 split below).** Group `material_atlas_mb`, `material_tile_size`,
`material_adaptive_resolution` and `material_preparation_budget` under reference
validation in the project UI. Preserve old saved values and runtime script access
if their keys move. With AMD GI enabled, the scene adapter evaluates source
materials directly. The atlas allocation, resolution reduction and page budget
are used by the other branch. Both the four material settings and the four
existing validator settings already use the Advanced view.
[Scene material paths](../../servers/rendering/renderer_rd/environment/rt_gi_scene.cpp)
and [reference renderer](../../servers/rendering/renderer_rd/environment/rtgi_validation.cpp).

**Keep the conditional controls.** For example, the two split-filter radius
settings both default to 11, but each can be tuned for its own reflection
resolution. Firefly marking radii influence brightness ranking only with
non-default rank thresholds. Debug atlas page selects a page of the cache
visualization, independently of the old material-capture atlas. Keep these
available for overlays and specialized projects.
[GI settings and dispatch](../../servers/rendering/renderer_rd/environment/amd_gi.cpp),
[firefly marking](../../servers/rendering/renderer_rd/shaders/effects/amd_gi_reflections_inc.glsl)
and [debug visualizations](../../servers/rendering/renderer_rd/shaders/effects/amd_gi_debug_inc.glsl).

One reason to present these controls conditionally is visible in the code today.
With A-Trous reflections active, editing the split-filter radius for the active
resolution still changes the packed radii compared by `AMDGI::render` and resets
GI history. The split filter itself only consumes that radius in split mode.
A follow-up can restrict the reset to changes that affect the active passes.

## Implemented presentation split, 2026-11-06

Rechecked current registrations against the fork base: 98 added project keys,
all retained. General exposes 20 normal setup/quality controls, including with
its Advanced Settings switch off. Advanced Fork Options is a separate tab for
the other 78. Search and the stock Advanced Settings switch in General cannot
reintroduce those specialized controls. The [portable map](../../GodotForkDocs/FORK_GUIDE.md#finding-fork-settings)
lists the main controls; the feature guides retain detailed advanced descriptions.

| Area | General | Advanced | Reason for advanced placement |
| --- | ---: | ---: | --- |
| AMD GI | 6 | 48 | Algorithm/sampler comparisons, cache sizing, histories, raw output, alternate denoisers, diagnostic instrumentation; four material-capture keys only affect the reference path |
| Reference RT GI | 0 | 4 | Validation renderer rather than a normal game quality setting |
| RT shadows | 6 | 10 | Denoiser internals, traversal distance/precision, directional coverage and fallback-map tuning |
| Screen-space shadows | 4 | 4 | Depth-edge thresholds/rejection and visualizer |
| VBAO / SSAO method | 2 | 7 | Estimator, sampling, footprint and calibration internals; authors retain Environment radius/intensity |
| Streamline / DLSS preset | 2 | 5 | Installation paths, application identity, logging, model override, experimental reactive mask |

No setting keys, values, enum meanings, rendering defaults, or renderer consumers
were changed by this split. The two already-retired RT-shadow entries remain
retired; all live controls remain script-accessible. No new compound quality
preset silently overwrites several values. The player flashlight proposal is
unrelated and remains deferred.

Implementation: `editor/settings/fork_project_settings.cpp` explicitly lists
advanced keys; unknown/custom keys stay in General. Dot-suffixed feature overrides
follow their base key. Both SectionedInspector instances edit ProjectSettings
through the existing proxy, with filtering applied to both the category tree
and property list. Canonical names retain hints, documentation, revert and
serialization. Shared add/delete/feature-override tools follow the selected tab;
restart notices follow the active settings tab so startup requirements stay visible.

Per-node review retained `Environment.ssao_method` and
`Light3D.shadow_map_enabled`: both are real authoring/compatibility choices.
Light size/angular distance and material controls also stay in the Inspector.
Debugging environment variables and RenderingServer diagnostic/preparation APIs
are not project-setting clutter and were retained. Stock settings, including
viewport scaling, were not moved.

Validation: MSVC Windows release-style editor built successfully, source base
`b3c0262131` plus the existing working changes and this UI change. Executable
SHA-256: `f752866da77677ee337f4449503b425aef85f00daef5aa2d7815c47146485e56`. An isolated blank project used the Compatibility/OpenGL
editor on the RTX 5090 (driver 621.01); GI and RT were disabled and no game ran.
The final editor pass exited 0 with 26 checks passing, covering normal/advanced
visibility and search, real property edits, canonical revert values, undo/redo
including switching tabs, restart notices, feature-override creation using the
existing Add controls, override classification, custom settings, and saved paths.
Screenshot review verified both tabs and the restart notice at 1200x700.
An initially oversized hidden-tab description was corrected before acceptance.

Static checks verified the exact 20/78 partition, basic visibility for all 20
General controls, and unchanged registration values/hints/types/restart flags
relative to the pre-task working tree. XML parsing, local guide links, formatting,
and `git diff --check` passed. No rendering acceptance or performance claim is
made: this is a presentation change. Local evidence (not portable to other clones)
is `.artifacts/fork-settings-ui-20261106/`: `inventory.json`, `build-final.log`,
`editor-final.log`, the temporary editor plugin, and three screenshots.
Desktop editors and fps-proto were not modified.
