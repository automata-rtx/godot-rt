# Fork documentation audit — 2026-11-06

Source reviewed: `b3c0262131` plus the working tree, including asynchronous GI
preparation/cache reuse, emitter-history retention, conservative temporal RT
shadows, and the General / Advanced Fork Options split. These changes are not all
represented by HEAD alone. This was a documentation/source audit, with no engine
launch, new benchmark, or new rendering acceptance result.

## Authority and scope

The portable `GodotForkDocs/` pack owns project-facing behavior. Engine
`docs/internals/` owns technical rebuild contracts; `PORTING.md` owns integration
order. `STATUS.md` owns evidence limits. Dated reports under `docs/validation/`
and archived snapshots retain their original measurements and configurations;
they do not establish current defaults. They were screened for conflicting
current guidance, not rerun or rewritten as new results. Upstream Godot and
third-party documentation/license text is not a fork behavior specification.

The audit covered the root routing instructions, portable pack, active engine
guides, redirects, feature implementation notes, candidate/decision records,
validation routes and historical index. Source checks targeted registrations,
runtime consumers and changed contracts, not a fresh proof of every renderer
algorithm. No claim of exhaustive hardware or API compatibility is made.

| Area | Source anchors checked / retained contracts |
| --- | --- |
| Settings | `core/config/project_settings.cpp`, `rendering_server.cpp`, `editor/settings/fork_project_settings.cpp`: 98 fork controls; 20 General, 78 Advanced; unchanged canonical keys |
| RT shadows | `rt_scene.*`, `rt_shadows.*`, temporal/spatial GLSL: startup master, sole conservative temporal path, contact protection, five-frame default and eight-frame ceiling; shared geometry and opaque-query limitations retained |
| AMD GI | `amd_gi.*`, native material/scene adapter, clustered renderer: capabilities, options/history, staged materials, complete-set publication, bounded retry, source identity and cache persistence |
| AO/contact shadows | GTAO and screen-space effects plus forward composition: independent screen-space visibility, selected directional shadow minimum, separate GI radiance composite; no VBAO/GI darker-wins feature |
| Streamline | Vulkan integration and viewport APIs: Windows/Vulkan startup, requested/effective upscaler distinction, device-owned shutdown; runtime binaries remain external |
| Project integration | `fps-proto/project.godot`, rendering design/preparation controller and existing AI routing: project overrides are not engine defaults; preparation covers loaded material sets, not all assets/raster variants |

## Corrections

- Replaced stale October source headers without relabeling dated test evidence.
- Reduced the portable entry guide and moved the settings inventory into
  `GodotForkDocs/SETTINGS.md`. Feature guides remain independently readable.
- Fixed portable links that escaped into the engine's `docs/` directory. Optional
  engine evidence is now an explicit repository path, not a broken project link.
- Corrected the debug settings location and distinguished the current 38 modes
  from the older fixture's 32-mode coverage.
- Documented retired RT temporal controls, current conservative filtering,
  default-on emitter-history retention and the unimplemented flashlight priority
  proposal. Responsive history is not presented as an accepted flashlight fix.
- Corrected stale “no runtime evidence” and “latest binary” wording. CPU follow-up
  benchmarks exist; exhaustive new automated regression coverage remains pending.
- Added loading/cache troubleshooting and clarified that VBAO is not blended
  against GI with a darkest-value operation.
- Corrected stale class-reference descriptions of rough-reflection fallback rays,
  screen feedback, reflection-filter independence and RT-shadow filtering. XML
  prose was maintained manually and parsed; no API signatures changed and no
  doctool regeneration was performed.

## Distribution and executable identity

The portable pack is maintained in the engine checkout. Synchronize the complete
folder to projects, preserving any separately authored project-specific notes.
The local project inventory found fork settings in `fps-proto` and `rt-shadows`;
both receive the same pack. Other projects were not assumed to use this fork.
`fps-proto` already routes agents through `CLAUDE.md` and `docs/README.md` to the
pack. The small RT-shadow project receives a root pointer. No game source,
assets or settings are changed by this audit.

Actual file hashes read during this audit:

| Executable | SHA-256 | Meaning |
| --- | --- | --- |
| Engine `bin/godot.windows.editor.x86_64.exe` | `F752866DA77677EE337F4449503B425AEF85F00DAEF5AA2D7815C47146485E56` | Settings UI build; prior blank-editor validation recorded separately |
| Desktop `GodotRT` and `GodotRTGI` editors | `63161B3F2FA7DC27021228C88766B1C7302AC8642A5C31362F95229EA041F030` | Prior loading-preparation build; lacks the settings UI split |

These are observations on this date, not permanent deployment promises. No binary
was replaced. Project reflection cutoff `0.45` and full-resolution reflections
are overrides; registered engine defaults remain `0.2` and half resolution.

Static checks cover active Markdown destinations/anchors, portable-pack isolation,
documented setting defaults against registrations, settings classification counts,
copy equality and whitespace. Local detailed output is under
`.artifacts/docs-audit-20261106/`; no runtime checks were needed for prose changes.

Results: 38 active Markdown documents, 187 links, 73 portable-table defaults and
all 98 fork class-reference entries checked. Both project copies match the 13-file
portable pack byte for byte. The main entry guide is 422 words; detailed settings,
features, implementation contracts and historical evidence stay on separate routes.

## Follow-up: porting boundaries and source contracts

The same-day follow-up checked shared ownership and update order against
`rt_geometry.{h,cpp}`, `rt_scene.{h,cpp}`, `rt_gi_scene.{h,cpp}` and
`RendererSceneRenderRD::update_raytracing_scene`; checked buffer-read group
validation in RenderingDevice; and compared current shadow/GI ABI assertions,
source-material entry points, GI prepass plane packing, emitter capacity offsets,
response metadata and asynchronous material-build methods with the notes.
These are source checks, not new execution tests or a proof of every shader.

The technical pack now has a required [shared RT foundation](internals/shared-raytracing.md),
separate shadow and GI consumers, and a separate required
[GI preparation component](internals/amd-gi-preparation.md). The porting map assigns
one owner to shared files and requires combined-consumer acceptance after GI is
integrated. Existing section anchors remain as redirects so older links work.
The stale `prepare_material_pipelines` source-map name was replaced by the actual
`prepare_scene_material_pipelines` and `update_material_pipelines` entry points.
Follow-up link checks passed for 40 active documents and 210 links.

No unresolved contradiction was found in those checked contracts. This does not
certify every sentence forever: a later port must pin the full source snapshot
(including these uncommitted changes), recheck the target engine's interfaces,
and run the specified independent and combined-feature acceptance cases.
