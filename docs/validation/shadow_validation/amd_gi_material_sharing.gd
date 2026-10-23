extends "res://amd_gi.gd"

const GI := "rendering/global_illumination/amd_gi/"


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "multibounce", true)
	ProjectSettings.set_setting(GI + "max_distance", 20.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.78, 0.78, 0.78)
	material.roughness = 1.0
	material.metallic_specular = 0.0
	var shared_box := BoxMesh.new()
	shared_box.size = Vector3.ONE
	shared_box.material = material
	var short_box: MeshInstance3D = get_node("ShortBox")
	var tall_box: MeshInstance3D = get_node("TallBox")
	short_box.mesh = shared_box
	short_box.scale = Vector3(1.15, 1.1, 1.15)
	tall_box.mesh = shared_box
	tall_box.scale = Vector3(1.05, 1.9, 1.05)
	var sphere := SphereMesh.new()
	sphere.radial_segments = 32
	sphere.rings = 16
	sphere.material = material
	var triangles: int = sphere.get_mesh_arrays()[Mesh.ARRAY_INDEX].size() / 3
	assert(triangles * 300 > 32768)
	print("Shared material stress: %d repeated sphere triangles" % (triangles * 300))
	# Geometry is in the GI volume but behind the room's opaque side wall.
	# Repetition must not consume independent copies of the material atlas.
	for i in 300:
		var instance := MeshInstance3D.new()
		instance.mesh = sphere
		instance.position = Vector3(5.0 + (i % 8) * 0.5, 1.0, -2.0 + (i / 8) * 0.1)
		add_child(instance)
	await _settle(12)
	await _capture("sharing_disabled")
	ProjectSettings.set_setting(GI + "enabled", true)
	await _settle(64)
	await _capture("sharing_shared")
	print("stage sharing: transform only")
	var original := short_box.transform
	for frame in 12:
		short_box.rotation.y += 0.02
		await _settle(1)
	short_box.transform = original
	await _settle(64)
	await _capture("sharing_restored")
	print("stage sharing: native world capture")
	# Same material values, but an explicit model input forces the existing
	# per-instance native capture. This independently checks rotated/nonuniform
	# normal transforms and protects custom world-dependent material semantics.
	var shader := Shader.new()
	shader.code = "shader_type spatial; uniform vec4 tint : source_color; void fragment() { ALBEDO = tint.rgb + MODEL_MATRIX[3].xyz * 0.0; ROUGHNESS = 1.0; SPECULAR = 0.0; }"
	var dependent := ShaderMaterial.new()
	dependent.shader = shader
	dependent.set_shader_parameter("tint", material.albedo_color)
	short_box.material_override = dependent
	tall_box.material_override = dependent
	await _settle(64)
	await _capture("sharing_world_capture")
	ProjectSettings.set_setting(GI + "enabled", false)
	short_box.material_override = null
	tall_box.material_override = null
	await _settle(12)
	await _capture("sharing_disabled_after")
	print("AMD material sharing capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
