extends "res://amd_gi.gd"

const GI := "rendering/global_illumination/amd_gi/"


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "multibounce", true)
	await _settle(12)
	await _capture("overlay_off")
	ProjectSettings.set_setting(GI + "enabled", true)
	await _settle(64)
	await _capture("overlay_on")
	print("stage overlay: decorative passes")
	var source: MeshInstance3D = get_node("ShortBox")
	var decoration: Array[MeshInstance3D] = []
	for variant in 4:
		var shader := Shader.new()
		shader.code = (
			"shader_type spatial; render_mode unshaded, depth_draw_never, depth_test_disabled; void fragment() { ALPHA=0.0; }"
			if variant == 1 else
			"shader_type spatial; render_mode unshaded, depth_draw_never, cull_front; void vertex() { VERTEX+=NORMAL*0.025; } void fragment() { ALBEDO=vec3(1.0); ALPHA=1.0; }"
		)
		var shader_material := ShaderMaterial.new()
		shader_material.shader = shader
		var material: Material = shader_material
		if variant >= 2:
			var transparent := StandardMaterial3D.new()
			transparent.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			transparent.albedo_color = Color(0.2, 0.5, 0.8, 0.2)
			if variant == 3:
				transparent.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				transparent.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			material = transparent
		var overlay := MeshInstance3D.new()
		overlay.mesh = source.mesh
		overlay.material_override = material
		overlay.transform = source.transform
		if variant >= 2:
			overlay.scale *= 1.05 + float(variant) * 0.01
		overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		overlay.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(overlay)
		decoration.append(overlay)
	await _settle(64)
	await _capture("overlay_decorated_on")
	ProjectSettings.set_setting(GI + "enabled", false)
	await _settle(12)
	await _capture("overlay_decorated_off")
	for overlay in decoration:
		overlay.queue_free()
	await _settle(12)
	await _capture("overlay_disabled_after")
	print("AMD decorative overlay capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
