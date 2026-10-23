extends "res://amd_gi.gd"

const GI := "rendering/global_illumination/amd_gi/"


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "multibounce", true)
	var boxes: Array[MeshInstance3D] = [get_node("ShortBox"), get_node("TallBox")]
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = [Color(0.65, 0.15, 0.08), Color(0.12, 0.28, 0.65)]
	var custom: Array[Color] = [Color(0.1, 0.3, 0.2, 0), Color(0.3, 0.1, 0.2, 0)]
	for i in 2:
		var mesh: BoxMesh = boxes[i].mesh
		var model := boxes[i].transform
		model.basis = model.basis.scaled_local(mesh.size)
		transforms.append(model)
		var shader := Shader.new()
		shader.code = "shader_type spatial; uniform vec4 tint; uniform vec4 custom; uniform float element; void fragment() { ALBEDO=tint.rgb; EMISSION=custom.rgb*(0.1+element*0.1); ROUGHNESS=1.0; SPECULAR=0.0; }"
		var material := ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter("tint", Vector4(colors[i].r, colors[i].g, colors[i].b, colors[i].a))
		material.set_shader_parameter("custom", Vector4(custom[i].r, custom[i].g, custom[i].b, custom[i].a))
		material.set_shader_parameter("element", float(i))
		boxes[i].material_override = material
	await _settle(12)
	await _capture("multimesh_reference_off")
	ProjectSettings.set_setting(GI + "enabled", true)
	await _settle(64)
	await _capture("multimesh_reference_on")
	ProjectSettings.set_setting(GI + "enabled", false)
	for box in boxes:
		box.queue_free()
	var shader := Shader.new()
	shader.code = "shader_type spatial; varying flat float element; varying vec4 custom; void vertex() { element=float(INSTANCE_ID); custom=INSTANCE_CUSTOM; } void fragment() { ALBEDO=COLOR.rgb; EMISSION=custom.rgb*(0.1+element*0.1); ROUGHNESS=1.0; SPECULAR=0.0; }"
	var material := ShaderMaterial.new()
	material.shader = shader
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	mesh.material = material
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.use_custom_data = true
	multi.instance_count = 2
	multi.mesh = mesh
	for i in 2:
		multi.set_instance_transform(i, transforms[i])
		multi.set_instance_color(i, colors[i])
		multi.set_instance_custom_data(i, custom[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = multi
	add_child(node)
	await _settle(12)
	await _capture("multimesh_off")
	ProjectSettings.set_setting(GI + "enabled", true)
	await _settle(64)
	await _capture("multimesh_on")
	print("stage multimesh: move")
	var moved := transforms[0]
	for frame in 12:
		moved.origin.x += 0.02
		multi.set_instance_transform(0, moved)
		await _settle(1)
	multi.set_instance_transform(0, transforms[0])
	await _settle(64)
	await _capture("multimesh_restored")
	print("stage multimesh: color/custom update")
	multi.set_instance_color(0, Color(0.1, 0.65, 0.1))
	multi.set_instance_custom_data(1, Color(0.1, 2.0, 0.1, 0))
	await _settle(64)
	await _capture("multimesh_updated")
	for i in 2:
		multi.set_instance_color(i, colors[i])
		multi.set_instance_custom_data(i, custom[i])
	ProjectSettings.set_setting(GI + "enabled", false)
	await _settle(12)
	await _capture("multimesh_disabled_after")
	get_tree().quit(1 if _failures else 0)
