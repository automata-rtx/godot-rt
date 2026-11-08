extends SceneTree

# Correctness/lifetime fixture only. Readbacks and compilation waits make every
# stage unsuitable for performance comparison. No external project content.
const CAPACITY := Vector2i(320, 320)
const TIMEOUT_MS := 120000
const SOURCE := """shader_type spatial;
uniform vec4 tint : source_color = vec4(0.15, 0.7, 0.25, 1.0);
void fragment() {
    ALBEDO = tint.rgb;
    METALLIC = 0.25;
    ROUGHNESS = 0.35;
}
"""
const HELPER := """vec3 coordinate_helper(vec2 screen_position, vec4 fragment_position, vec2 viewport_extent) {
    return vec3(screen_position, fragment_position.x / max(viewport_extent.x, 1.0));
}
void fragment() {"""

class NoOpEffect extends CompositorEffect:
    func _init() -> void:
        effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE

    func _render_callback(_callback_type: int, _render_data: RenderData) -> void:
        pass

var _failures: Array[String] = []
var _records: Array[Dictionary] = []
var _waits: Array[Dictionary] = []
var _views: Array[Dictionary] = []
var _display: TextureRect
var _output := ""
var _taa := false
var _finished := false


func _initialize() -> void:
    call_deferred("_run")


func _expect(condition: bool, message: String) -> bool:
    if not condition:
        _failures.append(message)
        push_error("HYBRID_PIP_FIXTURE " + message)
    return condition


func _frames(count: int) -> void:
    for _frame in count:
        await process_frame
        await RenderingServer.frame_post_draw


func _box(parent: Node, at: Vector3, size: Vector3, material: Material) -> MeshInstance3D:
    var mesh := BoxMesh.new()
    mesh.size = size
    mesh.material = material
    var node := MeshInstance3D.new()
    node.mesh = mesh
    node.position = at
    parent.add_child(node)
    return node


func _make_view(size: Vector2i, tint: Color) -> Dictionary:
    var view := SubViewport.new()
    view.size = size
    view.own_world_3d = true
    view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    view.msaa_3d = Viewport.MSAA_DISABLED
    view.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
    view.use_taa = _taa
    view.scaling_3d_scale = 1.0
    root.add_child(view)
    var world := Node3D.new()
    view.add_child(world)
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.035, 0.05, 0.08)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.3, 0.3, 0.3)
    environment.ambient_light_energy = 0.3
    var world_environment := WorldEnvironment.new()
    world_environment.environment = environment
    world.add_child(world_environment)
    var floor_material := StandardMaterial3D.new()
    floor_material.albedo_color = Color(0.45, 0.45, 0.45)
    _box(world, Vector3(0, -0.15, -2), Vector3(12, 0.3, 12), floor_material)
    _box(world, Vector3(0, 2, -5), Vector3(12, 4, 0.3), floor_material)
    var shader := Shader.new()
    shader.code = SOURCE
    var material := ShaderMaterial.new()
    material.shader = shader
    material.set_shader_parameter("tint", tint)
    _box(world, Vector3(0, 0.85, 0), Vector3(1.5, 1.7, 0.8), material)
    var emitter := StandardMaterial3D.new()
    emitter.albedo_color = Color(0.7, 0.12, 0.03)
    emitter.emission = Color(1.0, 0.12, 0.02)
    emitter.emission_energy_multiplier = 6.0
    _box(world, Vector3(-1.6, 0.65, -0.5), Vector3(0.4, 1.3, 0.4), emitter)
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-55, -25, 0)
    sun.light_energy = 1.5
    sun.shadow_enabled = true
    sun.light_angular_distance = 1.0
    world.add_child(sun)
    var pulse := OmniLight3D.new()
    pulse.position = Vector3(-1.4, 1.5, 0.6)
    pulse.light_color = Color(1, 0.35, 0.1)
    pulse.light_energy = 0
    pulse.omni_range = 5
    pulse.shadow_enabled = true
    world.add_child(pulse)
    var camera := Camera3D.new()
    camera.position = Vector3(0, 1.6, 4.5)
    camera.fov = 75
    world.add_child(camera)
    camera.look_at(Vector3(0, 0.9, -0.2))
    camera.current = true
    return {"view": view, "camera": camera, "world": world,
        "shader": shader, "material": material, "emitter": emitter, "pulse": pulse}


func _region(view: SubViewport, offset_pixels := Vector2.ZERO) -> void:
    var extent := Vector2(view.size)
    var center := extent * 0.5 + offset_pixels
    var protected := Rect2(center - Vector2(64, 64), Vector2(128, 128))
    var aperture := PackedVector2Array()
    for vertex in 8:
        var angle := TAU * float(vertex) / 8.0
        aperture.append((center + Vector2(cos(angle), sin(angle)) * 44.0) / extent)
    RenderingServer.viewport_set_hybrid_pip_region(view.get_viewport_rid(),
        Rect2(protected.position / extent, protected.size / extent), aperture)


func _prepare(view: SubViewport) -> void:
    _region(view)
    var rid := view.get_viewport_rid()
    RenderingServer.viewport_set_hybrid_pip_active(rid, false)
    RenderingServer.viewport_set_hybrid_pip_blur_enabled(rid, false)
    RenderingServer.viewport_prepare_hybrid_pip(rid, CAPACITY)


func _state(view: SubViewport) -> Dictionary:
    return RenderingServer.viewport_get_hybrid_pip_status(view.get_viewport_rid())


func _gi(view: SubViewport) -> Dictionary:
    return RenderingServer.viewport_get_amd_gi_diagnostics(view.get_viewport_rid())


func _wait(view: SubViewport, label: String, ready: bool, active: bool, reason := "") -> bool:
    print("HYBRID_PIP_FIXTURE wait ", label)
    var start := Time.get_ticks_msec()
    await _frames(2)
    var status := _state(view)
    while Time.get_ticks_msec() - start < TIMEOUT_MS:
        status = _state(view)
        if not status.is_empty() and status.get("ready", false) == ready and status.get("active", false) == active and (reason.is_empty() or status.get("reason", "") == reason):
            _waits.append({"stage": label, "wait_ms": Time.get_ticks_msec() - start, "status": status})
            return true
        await _frames(1)
    _expect(false, label + " timed out; status=" + str(status))
    _finish()
    return false


func _capture(view: SubViewport, label: String) -> Dictionary:
    var image := view.get_texture().get_image()
    if not _expect(image != null and not image.is_empty(), label + " missing image"):
        return {}
    _expect(image.get_size() == view.size, label + " stale presentation extent")
    # Presentation-level finite/visibility checks. These do not prove that every
    # intermediate HDR attachment is finite before display conversion.
    var minimum := INF
    var maximum := -INF
    var sum := 0.0
    var samples := 0
    var center := Vector3.ZERO
    for y in range(0, image.get_height(), 13):
        for x in range(0, image.get_width(), 13):
            var color := image.get_pixel(x, y)
            if not _expect(is_finite(color.r) and is_finite(color.g) and is_finite(color.b), label + " nonfinite presentation pixel"):
                return {}
            var value := (color.r + color.g + color.b) / 3.0
            minimum = minf(minimum, value)
            maximum = maxf(maximum, value)
            sum += value
            samples += 1
    var midpoint := image.get_size() / 2
    for y in range(midpoint.y - 4, midpoint.y + 4):
        for x in range(midpoint.x - 4, midpoint.x + 4):
            var color := image.get_pixel(x, y)
            center += Vector3(color.r, color.g, color.b)
    center /= 64.0
    _expect(sum / maxf(samples, 1) > 0.005 and maximum - minimum > 0.03, label + " black/flat output")
    _expect(image.save_png(_output.path_join(label + ".png")) == OK, label + " capture write failed")
    return {"center_rgb": center, "mean": sum / maxf(samples, 1), "range": maximum - minimum}


func _stage(view: SubViewport, label: String, active: bool, ready := true, reason := "", batch := true) -> bool:
    if not await _wait(view, label, ready, active, reason):
        return false
    var before := _gi(view)
    var status_before := _state(view)
    await _frames(6)
    var after := _gi(view)
    var status_after := _state(view)
    _expect(status_after.get("ready", false) == ready and status_after.get("active", false) == active, label + " state changed unexpectedly")
    if ready:
        _expect(int(status_after.get("rendered_frame", -1)) > int(status_before.get("rendered_frame", -1)), label + " stale renderer status")
        _expect(status_after.get("output_size", Vector2i.ZERO) == view.size, label + " stale logical output extent")
        var expected_background := Vector2i((view.size.x + 1) / 2, (view.size.y + 1) / 2) if active else view.size
        _expect(status_after.get("background_size", Vector2i.ZERO) == expected_background, label + " wrong background render extent")
        _expect(status_after.get("native_size", Vector2i.ZERO) == (CAPACITY if active else Vector2i.ZERO), label + " wrong native crop extent")
        _expect(int(status_after.get("region_count", 0)) == (2 if active else 1), label + " wrong active region count")
    if batch:
        var before_batch: Dictionary = before.get("batch", {})
        var after_batch: Dictionary = after.get("batch", {})
        _expect(before_batch.has("frame") and after_batch.has("frame"), label + " missing actual batch GI frame diagnostics")
        _expect(after_batch.get("valid", false), label + " batch GI frame invalid")
        var gi_delta := int(after_batch.get("frame", -1)) - int(before_batch.get("frame", -1))
        var rendered_delta := int(status_after.get("rendered_frame", -1)) - int(status_before.get("rendered_frame", -1))
        _expect(gi_delta > 0, label + " shared GI did not advance")
        _expect(gi_delta == rendered_delta, label + " logical GI advanced " + str(gi_delta) + " times over " + str(rendered_delta) + " rendered frames")
    else:
        _expect(int(after.get("frame", -1)) > int(before.get("frame", -1)), label + " uniform GI did not advance")
    var image := _capture(view, label)
    _records.append({"stage": label, "status": status_after, "gi": after, "image": image})
    if not _failures.is_empty():
        _finish()
        return false
    return true


func _add_moving_geometry(data: Dictionary) -> void:
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.15, 0.3, 0.8)
    var mesh := BoxMesh.new()
    mesh.size = Vector3(0.3, 0.65, 0.3)
    mesh.material = material
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.mesh = mesh
    multi.instance_count = 6
    for instance in 6:
        multi.set_instance_transform(instance, Transform3D(Basis.IDENTITY, Vector3(-2.2 + instance * 0.85, 0.33, -2)))
    var node := MultiMeshInstance3D.new()
    node.multimesh = multi
    data.world.add_child(node)
    data["multi"] = multi
    var source := BoxMesh.new()
    source.size = Vector3(0.65, 1.2, 0.65)
    var arrays := source.get_mesh_arrays()
    var delta := []
    delta.resize(Mesh.ARRAY_MAX)
    var positions := PackedVector3Array()
    var normals := PackedVector3Array()
    var tangents := PackedFloat32Array()
    positions.resize(arrays[Mesh.ARRAY_VERTEX].size())
    normals.resize(positions.size())
    tangents.resize(positions.size() * 4)
    for vertex in positions.size():
        positions[vertex] = Vector3(0.35, 0.1, 0) if arrays[Mesh.ARRAY_VERTEX][vertex].y > 0 else Vector3.ZERO
    delta[Mesh.ARRAY_VERTEX] = positions
    delta[Mesh.ARRAY_NORMAL] = normals
    delta[Mesh.ARRAY_TANGENT] = tangents
    var deforming := ArrayMesh.new()
    deforming.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_RELATIVE
    deforming.add_blend_shape("bend")
    deforming.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [delta])
    deforming.surface_set_material(0, material)
    var actor := MeshInstance3D.new()
    actor.mesh = deforming
    actor.position = Vector3(1.7, 0.6, -0.8)
    data.world.add_child(actor)
    data["actor"] = actor


func _finish() -> void:
    if _finished:
        return
    _finished = true
    var report := FileAccess.open(_output.path_join("lifecycle.json"), FileAccess.WRITE)
    if report:
        report.store_string(JSON.stringify({"failures": _failures, "taa": _taa,
            "stages": _records, "readiness_waits_not_benchmarks": _waits}, "\t"))
    else:
        _expect(false, "report write failed")
    print("HYBRID_PIP_FIXTURE complete failures=", _failures.size(), " output=", _output)
    quit(0 if _failures.is_empty() else 1)


func _run() -> void:
    _output = OS.get_environment("HYBRID_PIP_OUT")
    if _output.is_empty():
        _output = ProjectSettings.globalize_path("user://hybrid_pip_lifecycle")
    if not _expect(DirAccess.make_dir_recursive_absolute(_output) == OK, "cannot create output directory"):
        _finish()
        return
    _taa = OS.get_environment("HYBRID_PIP_TAA") == "1"
    if not _expect(RenderingServer.has_method("viewport_prepare_hybrid_pip"), "build has no HybridPiP API"):
        _finish()
        return
    var main := _make_view(Vector2i(640, 360), Color(0.12, 0.7, 0.2))
    _views.append(main)
    var view: SubViewport = main.view
    _display = TextureRect.new()
    _display.texture = view.get_texture()
    root.add_child(_display)
    _display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _prepare(view)
    if not await _stage(view, "01_ready_uniform", false): return
    RenderingServer.viewport_set_hybrid_pip_active(view.get_viewport_rid(), true)
    if not await _stage(view, "02_regional", true): return
    # Alternate frame parities and inactivity intervals; no preparation calls.
    for toggle in 3:
        RenderingServer.viewport_set_hybrid_pip_active(view.get_viewport_rid(), false)
        if not await _wait(view, "toggle_uniform_" + str(toggle), true, false): return
        await _frames(toggle + 1)
        RenderingServer.viewport_set_hybrid_pip_active(view.get_viewport_rid(), true)
        if not await _wait(view, "toggle_regional_" + str(toggle), true, true): return
    if not await _stage(view, "03_toggles", true): return
    for frame in 18:
        _region(view, Vector2(-40 + frame * 4, 8 * sin(frame * 0.3)))
        main.camera.position.x = 0.3 * sin(frame * 0.2)
        main.camera.look_at(Vector3(0, 0.9, -0.2))
        await _frames(1)
    if not await _stage(view, "04_moving_camera_crop", true): return
    RenderingServer.viewport_set_hybrid_pip_blur_enabled(view.get_viewport_rid(), true)
    if not await _stage(view, "05_depth_blur", true): return
    RenderingServer.viewport_set_hybrid_pip_blur_enabled(view.get_viewport_rid(), false)
    # Stage-specific builtins must be read in fragment(), then passed into a
    # user helper. They are not in scope inside an arbitrary helper definition.
    main.shader.code = SOURCE.replace("void fragment() {", HELPER).replace("ALBEDO = tint.rgb;", "ALBEDO = tint.rgb + coordinate_helper(SCREEN_UV, FRAGCOORD, VIEWPORT_SIZE) * 0.03;")
    main.material.set_shader_parameter("tint", Color(0.75, 0.1, 0.04))
    if not await _stage(view, "06_material_replacement_coordinates", true): return
    var material_image: Dictionary = _records.back().image
    var center: Vector3 = material_image.get("center_rgb", Vector3.ZERO)
    _expect(center.x > center.y + 0.03, "replacement red material did not reach the central visible object")
    for enabled in [true, false, true, false]:
        main.emitter.emission_enabled = enabled
        main.pulse.light_energy = 5.0 if enabled else 0.0
        if not await _wait(view, "emitter_light_crossing_" + str(enabled), true, true): return
        await _frames(3)
    if not await _stage(view, "07_emitter_light_crossings", true): return
    _add_moving_geometry(main)
    for frame in 16:
        main.multi.set_instance_transform(2, Transform3D(Basis(Vector3.UP, frame * 0.08), Vector3(-0.5, 0.33 + frame * 0.015, -2)))
        main.actor.set_blend_shape_value(0, float(frame % 8) / 7.0)
        await _frames(1)
    if not await _stage(view, "08_multimesh_deformation", true): return
    view.size = Vector2i(641, 361)
    _prepare(view)
    if not await _stage(view, "09_odd_resize_reprepared", false): return
    RenderingServer.viewport_set_hybrid_pip_active(view.get_viewport_rid(), true)
    if not await _stage(view, "10_odd_resize_regional", true): return
    var compositor := Compositor.new()
    compositor.compositor_effects = [NoOpEffect.new()]
    main.camera.compositor = compositor
    if not await _stage(view, "11_callback_uniform_fallback", false, false, "compositor_callback_requires_uniform_rendering", false): return
    main.camera.compositor = null
    compositor = null
    if not await _stage(view, "12_callback_removed_recovery", true): return
    var second := _make_view(Vector2i(640, 360), Color(0.06, 0.18, 0.8))
    _views.append(second)
    _prepare(second.view)
    if not await _stage(second.view, "13_second_ready_uniform", false): return
    RenderingServer.viewport_set_hybrid_pip_active(second.view.get_viewport_rid(), true)
    if not await _stage(second.view, "14_second_regional", true): return
    if not await _stage(view, "15_first_still_regional", true): return
    var second_center: Vector3 = _records[_records.size() - 2].image.get("center_rgb", Vector3.ZERO)
    _expect(second_center.z > second_center.x + 0.03, "second viewport inherited first viewport color")
    # Drop a different live regional owner while the first continues rendering.
    second.view.queue_free()
    _views.remove_at(1)
    second.clear()
    await _frames(3)
    if not await _stage(view, "16_second_destroyed", true): return
    RenderingServer.viewport_set_hybrid_pip_enabled(view.get_viewport_rid(), false)
    if not await _stage(view, "17_feature_disabled", false, false, "", false): return
    _prepare(view)
    if not await _stage(view, "18_feature_reprepared", false): return
    RenderingServer.viewport_set_hybrid_pip_active(view.get_viewport_rid(), true)
    if not await _stage(view, "19_final_regional", true): return

    # A resident decline must draw the ordinary scaled camera while the caller
    # is still holding ADS. Repeated requests must not retry on every frame.
    var rid := view.get_viewport_rid()
    RenderingServer.viewport_set_hybrid_pip_active(rid, false)
    RenderingServer.viewport_set_hybrid_pip_enabled(rid, false)
    view.scaling_3d_scale = 0.5
    compositor = Compositor.new()
    compositor.compositor_effects = [NoOpEffect.new()]
    main.camera.compositor = compositor
    RenderingServer.viewport_prepare_resident_hybrid_pip(rid, CAPACITY)
    RenderingServer.viewport_set_hybrid_pip_active(rid, true)
    if not await _wait(view, "20_resident_declined", false, false, "compositor_callback_requires_uniform_rendering"): return
    var rejected := _state(view)
    main.camera.compositor = null
    RenderingServer.viewport_set_hybrid_pip_active(rid, true)
    await _frames(4)
    var held := _state(view)
    _expect(held.get("resident_state") == "fallback" and held.get("requested_active"), "held ADS lost the fallback latch")
    _expect(held.get("rendered_frame") == rejected.get("rendered_frame"), "declined scope was rendered again")
    var normal_size := RenderingServer.viewport_get_internal_size(rid)
    _expect(normal_size.x < view.size.x and _gi(view).get("size") == normal_size, "fallback did not draw ordinary scaled buffers")
    RenderingServer.viewport_set_hybrid_pip_active(rid, false)
    RenderingServer.viewport_set_hybrid_pip_active(rid, true)
    if not await _wait(view, "21_resident_rearmed", true, true): return
    _expect(_state(view).get("resident_state") == "active", "fresh ADS did not recover")
    _display.texture = null
    view.queue_free()
    _views.clear()
    main.clear()
    await _frames(4)
    _finish()
