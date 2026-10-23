extends "res://amd_gi.gd"


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 20.0)
	_light.light_energy = 0.0
	get_node("Ceiling").queue_free()
	var environment: Environment
	for child in get_children():
		if child is WorldEnvironment:
			environment = child.environment
	var shader := Shader.new()
	shader.code = "shader_type sky; uniform vec3 tint = vec3(0.3); uniform float directional = 0.0; void sky() { COLOR = tint * mix(1.0, max(EYEDIR.x, 0.0), directional); }"
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
	await _settle(12)
	await _capture("sky_disabled")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _settle(64)
	await _capture("sky_uniform")
	material.set_shader_parameter("tint", Vector3(0.0, 0.0, 0.0))
	await _settle(64)
	await _capture("sky_black")
	material.set_shader_parameter("tint", Vector3(0.05, 0.4, 0.05))
	await _settle(64)
	await _capture("sky_green")
	material.set_shader_parameter("tint", Vector3(0.6, 0.6, 0.6))
	material.set_shader_parameter("directional", 1.0)
	await _settle(64)
	await _capture("sky_directional")
	environment.sky_rotation = Vector3(0, PI, 0)
	await _settle(64)
	await _capture("sky_rotated")
	environment.sky_rotation = Vector3.ZERO
	material.set_shader_parameter("directional", 0.0)
	material.set_shader_parameter("tint", Vector3(0.3, 0.3, 0.3))
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(12)
	await _capture("sky_disabled_after")
	print("AMD sky capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
