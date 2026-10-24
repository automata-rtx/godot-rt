extends Node3D

const GI := "rendering/global_illumination/amd_gi/"


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", true)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "reflections/enabled", false)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	add_child(world)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 0, 4)
	add_child(camera)
	camera.make_current()
	for index in 3:
		var node := MeshInstance3D.new()
		node.mesh = BoxMesh.new()
		node.position.x = float(index - 1) * 1.2
		if index == 1:
			var emission := StandardMaterial3D.new()
			emission.emission_enabled = true
			emission.emission = Color(0.1, 0.2, 0.1)
			node.material_override = emission
		if index == 2:
			var shader := Shader.new()
			shader.code = "shader_type spatial; void fragment() { ALBEDO = vec3(abs(dFdx(UV.x))); }"
			var unsupported := ShaderMaterial.new()
			unsupported.shader = shader
			node.material_override = unsupported
		add_child(node)
	var lights: Array[OmniLight3D] = []
	for index in 1025:
		var light := OmniLight3D.new()
		light.position = Vector3(float(index % 3) * 0.1, 2, 2)
		light.light_energy = 0.001
		light.shadow_enabled = false
		light.omni_range = 10.0
		add_child(light)
		lights.append(light)
	print("COLLECTION phase grown")
	for frame in 5:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	for index in range(1, lights.size()):
		lights[index].queue_free()
	print("COLLECTION phase shrunk")
	for frame in 5:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	ProjectSettings.set_setting(GI + "enabled", false)
	for frame in 3:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	print("COLLECTION FINISHED")
	get_tree().quit()
