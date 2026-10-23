extends "res://amd_gi.gd"


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 20.0)
	get_node("Ceiling").queue_free()
	var environment: Environment
	for child in get_children():
		if child is WorldEnvironment:
			environment = child.environment
	var shader := Shader.new()
	shader.code = "shader_type sky; uniform vec3 tint = vec3(0.15); void sky() { COLOR = tint * (1.0 + 0.05 * sin(TIME + EYEDIR.x)); }"
	var material := ShaderMaterial.new()
	material.shader = shader
	var sky := Sky.new()
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.sky_material = material
	environment.sky = sky
	environment.background_mode = Environment.BG_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 1.0
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.light_energy = 0.3
	sun.light_angular_distance = 0.0
	sun.shadow_enabled = true
	add_child(sun)
	await _settle(12)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _settle(32)
	await _capture("dynamic_start")
	print("stage dynamic: gradual")
	for frame in 96:
		var fraction := float(frame + 1) / 96.0
		sun.rotation_degrees.y = 30.0 + fraction * 10.0
		sun.light_energy = 0.3 + 0.05 * fraction
		_light.position.x = -0.2 + 0.5 * fraction
		_light.light_energy = 1.8 + 0.2 * fraction
		environment.sky_rotation.y = fraction * 0.15
		await _settle(1)
	await _capture("dynamic_moving_lights")
	print("stage dynamic: cut")
	_light.light_energy = 0.0
	sun.light_energy = 0.0
	material.set_shader_parameter("tint", Vector3.ZERO)
	await _settle(64)
	await _capture("dynamic_black")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(12)
	print("AMD dynamic lighting capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
