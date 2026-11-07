extends "res://lifecycle.gd"

# Focused GPU queue/ownership correctness test, never a performance test.
# Launch with --log-file <absolute path> and all three VALIDATE_* variables below.
# It reuses generated fixture geometry, never game assets or project settings.
const GI := "rendering/global_illumination/amd_gi/"
const VALIDATORS := ["GODOT_AMD_GI_VALIDATE_HITS", "GODOT_AMD_GI_VALIDATE_BOUNCES",
    "GODOT_AMD_GI_VALIDATE_RESERVOIRS"]
var _log_file := ""


func _positive_work(label: String, all_hits: bool, bounces: bool) -> Dictionary:
    # stderr flushes the engine log even in builds which buffer normal stdout.
    # This is a stage marker, not an engine error.
    printerr("HYBRID_PIP_QUEUES end " + label)
    var text := FileAccess.get_file_as_string(_log_file)
    var start := text.rfind("HYBRID_PIP_QUEUES begin " + label)
    var end := text.rfind("HYBRID_PIP_QUEUES end " + label)
    if not _expect(start >= 0 and end > start, label + " missing flushed log markers"):
        return {}
    var section := text.substr(start, end - start)
    _expect(not section.contains("ERROR:"), label + " engine/validator error")
    var result := {}
    var patterns := {
        "hits": "AMD GI hit update validation: primary=(\\d+) secondary=(\\d+)",
        "bounces": "AMD GI multibounce validation: primary=(\\d+) secondary_hits=(\\d+)",
        "reservoirs": "AMD GI reservoir validation: valid=(\\d+) reused=(\\d+)"
    }
    for kind in patterns:
        var expression := RegEx.new()
        _expect(expression.compile(patterns[kind]) == OK, "invalid fixture expression")
        var matches := expression.search_all(section)
        var maximum_first := 0
        var maximum_second := 0
        for matched in matches:
            maximum_first = maxi(maximum_first, int(matched.get_string(1)))
            maximum_second = maxi(maximum_second, int(matched.get_string(2)))
        result[kind] = {"validated_frames": matches.size(),
            "maximum_first_count": maximum_first, "maximum_second_count": maximum_second}
        var required: bool = kind == "reservoirs" or (kind == "hits" and all_hits) or (kind == "bounces" and bounces)
        if required:
            _expect(matches.size() > 0 and maximum_first > 0, label + " no positive " + kind + " work")
        if bounces and (kind == "bounces" or (kind == "hits" and all_hits)):
            _expect(maximum_second > 0, label + " no secondary " + kind + " work")
    return result


func _queue_stage(view: SubViewport, label: String, active: bool, all_hits: bool, bounces: bool) -> bool:
    RenderingServer.viewport_set_hybrid_pip_active(view.get_viewport_rid(), active)
    if not await _wait(view, label, true, active):
        return false
    var before := _state(view)
    var gi_before: Dictionary = _gi(view).get("batch", {})
    print("HYBRID_PIP_QUEUES begin " + label)
    await _frames(8)
    var after := _state(view)
    var gi_after: Dictionary = _gi(view).get("batch", {})
    var gi_delta := int(gi_after.get("frame", -1)) - int(gi_before.get("frame", -1))
    var rendered_delta := int(after.get("rendered_frame", -1)) - int(before.get("rendered_frame", -1))
    _expect(after.get("ready", false) and after.get("active", false) == active, label + " lost readiness")
    _expect(gi_after.get("valid", false) and gi_delta > 0 and gi_delta == rendered_delta, label + " incorrect shared GI progression")
    _expect(after.get("region_count", 0) == (2 if active else 1), label + " incorrect active region count")
    _expect(gi_after.get("capacity", 0) == gi_before.get("capacity", -1), label + " capacity changed during stable stage")
    var evidence := _positive_work(label, all_hits, bounces)
    _records.append({"stage": label, "all_hits": all_hits, "multibounce": bounces,
        "status": after, "batch": gi_after, "gpu_validators": evidence})
    return _failures.is_empty()


func _finish() -> void:
    if _finished:
        return
    _finished = true
    var report := FileAccess.open(_output.path_join("queues.json"), FileAccess.WRITE)
    if report:
        report.store_string(JSON.stringify({"failures": _failures, "stages": _records,
            "readiness_waits_not_benchmarks": _waits, "log": _log_file}, "\t"))
    else:
        _expect(false, "report write failed")
    print("HYBRID_PIP_QUEUES complete failures=", _failures.size(), " output=", _output)
    quit(0 if _failures.is_empty() else 1)


func _run() -> void:
    _output = OS.get_environment("HYBRID_PIP_OUT")
    if _output.is_empty():
        _output = ProjectSettings.globalize_path("user://hybrid_pip_queues")
    if not _expect(DirAccess.make_dir_recursive_absolute(_output) == OK, "cannot create output directory"):
        _finish()
        return
    var args := OS.get_cmdline_args()
    _log_file = OS.get_environment("HYBRID_PIP_LOG_FILE")
    var log_arg := args.find("--log-file")
    if log_arg >= 0 and log_arg + 1 < args.size():
        _log_file = args[log_arg + 1]
    _expect(not _log_file.is_empty() and _log_file.is_absolute_path(), "requires --log-file with absolute path")
    for variable in VALIDATORS:
        _expect(not OS.get_environment(variable).is_empty(), "requires " + variable + "=1")
    if not _failures.is_empty():
        _finish()
        return
    ProjectSettings.set_setting(GI + "cache_all_hits", true)
    ProjectSettings.set_setting(GI + "multibounce", false)
    ProjectSettings.set_setting(GI + "light_resampling", true)
    ProjectSettings.set_setting(GI + "continuation_probability", 1.0)
    ProjectSettings.set_setting(GI + "debug/statistics", false)
    _taa = false
    var data := _make_view(Vector2i(640, 360), Color(0.12, 0.7, 0.2))
    _views.append(data)
    var view: SubViewport = data.view
    # Enclose the sides/ceiling so continuation rays exercise actual hit queues.
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.4, 0.45, 0.5)
    for side in [-1.0, 1.0]:
        _box(data.world, Vector3(side * 5.8, 2, -2), Vector3(0.3, 4, 12), material)
    _box(data.world, Vector3(0, 4.1, -2), Vector3(12, 0.3, 12), material)
    data.emitter.emission_enabled = true
    data.pulse.light_energy = 3.0
    _display = TextureRect.new()
    _display.texture = view.get_texture()
    root.add_child(_display)
    _display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _prepare(view)
    for options in [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(0, 0)]:
        var all_hits: bool = options.x != 0
        var bounces: bool = options.y != 0
        ProjectSettings.set_setting(GI + "cache_all_hits", all_hits)
        ProjectSettings.set_setting(GI + "multibounce", bounces)
        var label := "hits%d_bounces%d" % [options.x, options.y]
        for active in [false, true]:
            if not await _queue_stage(view, label + ("_regional" if active else "_uniform"), active, all_hits, bounces):
                _finish()
                return
    _display.texture = null
    view.queue_free()
    _views.clear()
    data.clear()
    await _frames(4)
    _finish()
