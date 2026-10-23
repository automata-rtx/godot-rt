extends "res://amd_gi.gd"

const GI := "rendering/global_illumination/amd_gi/"


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "multibounce", true)
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = "shader_type spatial; void fragment() { ALBEDO=COLOR.rgb; ROUGHNESS=1.0; SPECULAR=0.0; }"
	material.shader = shader
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.2, 0.2, 0.2)
	mesh.material = material
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.instance_count = 200
	multi.mesh = mesh
	for i in multi.instance_count:
		multi.set_instance_transform(i, Transform3D(Basis(), Vector3(float(i % 20) * 0.25 - 2.5, 0.0, 10.0 + float(i / 20) * 0.25)))
		multi.set_instance_color(i, Color(0.4, 0.1, 0.1) if i % 2 else Color(0.1, 0.4, 0.1))
	var node := MultiMeshInstance3D.new()
	node.multimesh = multi
	add_child(node)
	var sphere := SphereMesh.new()
	sphere.radial_segments = 128
	sphere.rings = 128
	var padding := MeshInstance3D.new()
	padding.mesh = sphere
	padding.position = Vector3(0, 0, 15)
	padding.material_override = StandardMaterial3D.new()
	padding.material_override.albedo_color = Color.BLACK
	add_child(padding)
	await _settle(12)
	await _capture("density_disabled")
	for variant in ["eight", "four", "restored"]:
		ProjectSettings.set_setting(GI + "material_tile_size", 4 if variant == "four" else 8)
		ProjectSettings.set_setting(GI + "enabled", true)
		print("stage density: ", variant)
		await _settle(62)
		await _capture("density_" + variant)
	# Change size live, with GI resources still active throughout all three stages.
	ProjectSettings.set_setting(GI + "enabled", false)
	await _settle(12)
	await _capture("density_disabled_after")
	print("AMD material density capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
