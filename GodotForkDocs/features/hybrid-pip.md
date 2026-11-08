# HybridPiP: experimental regional scope rendering

One logical perspective camera renders the background and a separately sized inner region using a shared world GI cache. Projects can composite a native scope rectangle or magnify only the visible glass while the background supplies the housing. Regional rendering is off by default. Performance and ADS transition costs depend on scene content, region sizes and reconstruction.

## Build and feature gate

Use a fork editor and matching export template built with the resident HybridPiP implementation. A game script can configure this renderer at runtime. Adding a sight, changing its dimensions or tuning zoom needs no engine rebuild once the binary contains the feature. Check the **running executable**, including exports, with `RenderingServer.has_method(&"viewport_prepare_resident_hybrid_pip")`. On older binaries keep ordinary FOV-based ADS. The binding alone cannot confirm hardware or scene support.

The magnified DLSS path requires Vulkan Forward+, a single perspective view, ready AMD GI, a GPU supporting the regional GI batch and working Streamline DLSS Super Resolution. The dedicated compositor parent runs at native output size with its own AA/VRS configuration. Hip-fire can use the player's normal DLSS, FSR or other viewport settings. Frame generation is suspended for the resident regional draw and may resume on the normal path.

## Resource lifetime for a scoped weapon

The gate is **per viewport and explicit**. The engine cannot infer what is equipped. Have one local camera controller own the following transitions.

| Event | Controller action | Renderer behavior |
| --- | --- | --- |
| Start with ordinary sights | Leave HybridPiP disabled | No scope parent or regional children are allocated for this viewport. |
| Equip a magnified optic | Set its runtime overrides and layout, then call `viewport_prepare_resident_hybrid_pip` once | Enables the configuration. The dedicated parent is created on its first eligible active draw. Preparation alone does not exercise either DLSS child. |
| Warm under a loading cover | With the actual camera, representative mesh and GI ready, request active, wait across rendered frames for actual `active=true`, then request inactive | Both regional resolves have an opportunity to run before the first visible ADS. Bound the wait and cancel it if the camera, sight or level changes. An equip during open play can still have a cold first activation. |
| ADS on / off with the same optic | Call only `viewport_set_hybrid_pip_active(view, aiming)` on transitions | Hip-fire draws its ordinary camera. The regional buffers stay resident between aims. The inactive view has no second world draw. An enabled temporal scope can still request previous geometry transforms. |
| Unequip, switch to iron sights, or leave the world | Request inactive, then call `viewport_set_hybrid_pip_enabled(view, false)` on the original RID and restore owned runtime overrides | Drops that viewport's reference to the scope parent and its child buffers. Shared renderer facilities and driver caches have separate lifetimes. An immediate drop in total process VRAM is not guaranteed. |

## Configure the tested magnified path

This example uses 360 input pixels per side and 3× lens magnification. It reconstructs to **1080 × 1080** at **33.3%** per axis. At 3440 × 1440 the background renders at **860 × 360** and reconstructs to **1720 × 720**. Lens magnification is additional to any FOV change the game applies to the whole camera.

```gdscript
# On equip/configuration change, after checking for the resident method.
# view is the main viewport RID. rect and opening are normalized as described below.
var input_side := 360
var resolved_side := roundi(input_side * 3.0)
var options := {
    "background_reconstruction": 2, "background_fxaa": false,
    "native_aa": 5, "native_fsr1": false,
    "magnify_aperture": true, "lens_only": true, "preview_resolve": false,
    "native_resolve_scale": float(resolved_side) / input_side,
    "native_scale": float(input_side) / resolved_side,
}
for key in options:
    ProjectSettings.set_setting("rendering/hybrid_pip/" + key, options[key])
RenderingServer.call(&"viewport_set_hybrid_pip_region", view, rect, opening)
RenderingServer.call(&"viewport_set_hybrid_pip_blur_enabled", view, true)
RenderingServer.call(&"viewport_prepare_resident_hybrid_pip", view, Vector2i.ZERO)
```

The overrides above are **process-wide**. Save the previous values once when taking ownership and restore them on final release. Coordinate any other scope controller using the same keys. Leave the player's scaling, AA and frame-generation preferences under the normal graphics settings owner.

Build the square in **final 3D output pixels** using `viewport_get_hybrid_pip_status(view)["viewport_size"]`. Keep its side fixed as it moves. Snap its origin to integer pixels. The sandbox insets the rectangle by 0.125 pixel on each edge before normalization so outward floor/ceil rounding recovers the intended side. Divide positions and extents independently by output width and height. A zero-sized viewport must wait for a valid resize.

Supply 3–16 ordered vertices of the projected, convex glass opening. The compositor uses their mean as its optical axis and their farthest distance as the circle radius, then clips to the polygon with a one-pixel edge. For a round lens use evenly spaced vertices. In lens-only mode the axis must lie inside the input rectangle and the *reconstructed* footprint must cover all visible glass. The lower-resolution region can draw the housing. A sight with a large or off-center lens may need a larger input or a different placement. Leave an actual unobstructed optical bore in the sight art. The compositor samples scene color including visible foreground geometry.

## Runtime contract

Use the main viewport RID and these `RenderingServer` methods:

| Method | Purpose |
| --- | --- |
| `viewport_set_hybrid_pip_region(viewport, rectangle, aperture)` | Supply a normalized source rectangle plus 3–16 ordered output-space vertices around the clear lens opening |
| `viewport_prepare_hybrid_pip(viewport, capacity)` | Enable and prepare a fixed native crop allocation, in output pixels; call behind a loading cover |
| `viewport_prepare_resident_hybrid_pip(viewport, capacity)` | Keep a separate native compositor parent so hip-fire can use full-view DLSS and its own AA. Activate once behind the loading screen to warm both regional upscalers. Ordinary ADS toggles retain both sets of buffers and draw only the selected path. |
| `viewport_get_hybrid_pip_status(viewport)` | Check `ready`, actual `active`, and fallback `reason`; also reports dimensions and frame counters |
| `viewport_set_hybrid_pip_active(viewport, active)` | Enter/leave ADS while retaining resources; before readiness, uniform rendering continues |
| `viewport_set_hybrid_pip_blur_enabled(viewport, enabled)` | Toggle peripheral blur; defaults on |
| `viewport_set_hybrid_pip_enabled(viewport, enabled)` | Disable/re-enable the feature; disabling releases regional state during rendering |

Pass `Vector2i.ZERO` for an exact fit computed by the renderer against its actual 3D output. A window texture can include additional UI stretch. For a fixed allocation, prepare once for the protected rectangle's outward-rounded pixel extent.
Matching its dimensions gives an unpadded native crop. A larger requested
capacity renders extra native pixels. `native_rect` reports the active crop's
position and size in output pixels.
The renderer reports uniform fallback if capacity cannot cover the request.
Move the rectangle/aperture with scope sway; retain capacity until a genuine
resolution or scope-size change. Reprepare such changes behind a loading cover.

`ready` means the supported preparation path has finished; it is not a universal
zero-hitch guarantee. Use `active` to confirm the requested path is actually
rendering. Do not parse diagnostic reason strings as a stable API.

The unmagnified rectangular mode protects the chosen scope rectangle. Its capacity can cover the entire housing. For lens-only magnification use the aperture and reconstruction rules above.

- `native_aa` selects off, FXAA, SMAA, TAA, FSR2 or DLSS (0 through 5). `native_scale` is input pixels divided by reconstruction pixels per axis. At 100%, DLSS uses DLAA. Spatial FSR1 can be enabled separately via `native_fsr1`.
- For an adjustable DLSS optic, set `native_aa=5`, `magnify_aperture=true` and `lens_only=true`. Center the square source rectangle on the optical axis. With an input side of *S* pixels and desired zoom *Z* (1–4), use reconstructed side *T* = round(*S* × *Z*), `native_resolve_scale=T/S` and `native_scale=S/T`. The scale percentage is 100 × *S* / *T*. Streamline receives the actual dimensions together with an SDK quality mode. The shader copies reconstructed texels one-to-one inside the lens. The reconstructed footprint must cover every visible aperture vertex.
- `background_reconstruction=2` enables outer DLSS Performance, rendering at one quarter of the display width and height and reconstructing to half of each. The default background mode can use `background_fxaa`.
- During ADS, check `active`, `native_input_size`, `native_target_size`, `native_rect`, `lens_only` and `background_reconstruction` in the viewport status. Input and target are child texture dimensions; the source rectangle describes the sampled area in parent output coordinates.

Blur uses current depth outside the aperture: a radius of 2 to 10.72 output
pixels at 720p, smoothly increasing between 0.12 and 25 meters of axial camera
depth. Radius scales with output height. The aperture stays clear; scope surfaces
outside it receive the same depth-based treatment. Canvas UI remains at output
resolution; signs and other UI drawn as 3D geometry follow their region's resolution.

## Compatibility and limits

Resident requests report `resident_state` as `idle`, `warming`, `active` or `fallback`. A known incompatibility, failed regional DLSS submission or five seconds of unconfirmed warm-up latches fallback. The next eligible camera draw uses the ordinary viewport and player upscaler. The detecting frame can already be recorded. The game owns weapon visibility and ordinary FOV ADS. Stop a loading warm-up on either active or fallback. Each requested DLSS region must successfully submit before the attempt reports active. This is a driver submission result, not a GPU completion fence.

Release and re-aim, prepare a changed profile, or change the camera/scenario or viewport configuration to retry. Moving the aperture or resending the same active request keeps the existing decision. Legacy preparation still uses the uniform parent on decline. Older resident builds without `resident_state` need a game-side bounded wait and explicit deactivation. Current fallbacks include custom
compositor callbacks, materials sampling screen/depth/normal textures, custom
clip-space/projection writes, point-size shaders, camera DoF, auto-exposure,
custom sky FOV, volumetric fog, SDFGI/VoxelGI/SSIL, SSR when not replaced by GI
reflections, external depth, debug rendering, orthographic/multiview cameras,
reflection probes and partial render regions. KEEP/CANVAS/CAMERA_FEED environment
backgrounds also use uniform rendering. Ordinary fog, sky, fixed exposure,
VBAO/contact shadows and the fork's RT shadows have regional adapters.

The filter border is finite; movement and lighting boundaries still require
scene-specific visual review. Prepared native, background and uniform histories
use additional GPU memory. Histories reset when a mode resumes after inactivity
or its prepared buffers change; crop motion uses the previous crop mapping.
Inactive modes are not continuously rendered. New materials can still need
pipeline compilation under the existing loading preparation policy.

This API supplies rendering only. The game must supply scope bounds, lens shape,
ADS state and loading-cover integration. Do not copy the validation scene's
camera, scope size, or pixel capacity blindly into another project.
