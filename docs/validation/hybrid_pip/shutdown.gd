extends "res://lifecycle.gd"

# Exercise normal SceneTree teardown while regional owners are still live.
# Do not detach textures, disable the feature, or queue_free the viewport first.
const INVALID_SOURCE := """shader_type spatial;
void fragment() {
    ALBEDO = vec3(HYBRID_PIP_EXPECTED_INVALID_IDENTIFIER);
}
"""


func _run() -> void:
    _output = OS.get_environment("HYBRID_PIP_OUT")
    if _output.is_empty():
        _output = ProjectSettings.globalize_path("user://hybrid_pip_shutdown")
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
    var invalid_shader := OS.get_environment("HYBRID_PIP_INVALID_SHADER") == "1"
    if invalid_shader:
        print("HYBRID_PIP_SHUTDOWN injecting expected invalid shader")
        main.shader.code = INVALID_SOURCE
        await _frames(30)
        var status := _state(view)
        _expect(not status.get("ready", true) and not status.get("active", true),
            "invalid material did not leave regional rendering safely")
        _expect(status.get("reason", "") == "amd_gi_preparing_or_unsupported",
            "unexpected invalid-material fallback reason: " + str(status))
        _records.append({"stage": "03_expected_invalid_shader_fallback", "status": status,
            "image": _capture(view, "03_expected_invalid_shader_fallback")})
    print("HYBRID_PIP_SHUTDOWN live-owner exit invalid_shader=", invalid_shader)
    # Report/exit status covers script assertions only. The caller must inspect
    # engine.log after process exit: shutdown errors occur after this returns.
    _finish()
