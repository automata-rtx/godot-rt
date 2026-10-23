extends "res://amd_gi.gd"

const GI := "rendering/global_illumination/amd_gi/"


func _card(label: String, z: float, size: Vector2, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	var mesh := QuadMesh.new()
	mesh.size = size
	mesh.material = material
	node.mesh = mesh
	node.position = Vector3(0, 1.5, z)
	node.rotation.y = PI
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "multibounce", false)
	ProjectSettings.set_setting(GI + "screen_feedback", false)
	ProjectSettings.set_setting(GI + "reflections/enabled", false)
	var emitter := StandardMaterial3D.new()
	emitter.albedo_color = Color.BLACK
	emitter.emission_enabled = true
	emitter.emission = Color(1.0, 0.3, 0.1)
	emitter.emission_energy_multiplier = 3.0
	_card("BehindCameraEmitter", 9.0, Vector2(6, 4), emitter)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.BLACK
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	var pane := _card("BehindCameraCoverage", 8.5, Vector2(8, 6), material)
	await _settle(12)
	await _capture("opacity_disabled")
	for variant in ["hidden", "zero", "half", "one", "opaque"]:
		pane.visible = variant != "hidden"
		material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED if variant == "opaque" else BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = 0.0 if variant == "zero" else (0.5 if variant == "half" else 1.0)
		await _settle(4)
		ProjectSettings.set_setting(GI + "enabled", true)
		await _settle(62)
		await _capture("opacity_" + variant)
		ProjectSettings.set_setting(GI + "enabled", false)
		await _settle(12)
	await _capture("opacity_disabled_after")
	print("AMD opacity capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
