extends "res://amd_gi.gd"


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 20.0)
	var material: StandardMaterial3D = _green_wall.mesh.material
	material.albedo_color = Color.WHITE
	var pixels := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	pixels.fill(Color(0.12, 0.7, 0.16))
	var texture := ImageTexture.create_from_image(pixels)
	material.albedo_texture = texture
	await _settle(12)
	await _capture("dirty_disabled")
	print("stage dirty: green")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _settle(64)
	await _capture("dirty_green")
	print("stage dirty: blue")
	pixels.fill(Color(0.12, 0.16, 0.7))
	texture.update(pixels)
	await _settle(64)
	await _capture("dirty_blue")
	print("stage dirty: emission")
	material.emission_enabled = true
	material.emission = Color(0.0, 0.6, 0.0)
	await _settle(64)
	await _capture("dirty_emission")
	print("stage dirty: time")
	var shader := Shader.new()
	shader.code = "shader_type spatial; void fragment() { ALBEDO = vec3(0.12, 0.7, 0.16); ROUGHNESS = 1.0; SPECULAR = 0.0; EMISSION = vec3(0.0, 0.05 * (sin(TIME) + 1.0), 0.0); }"
	var animated := ShaderMaterial.new()
	animated.shader = shader
	_green_wall.mesh.material = animated
	await _settle(24)
	await _capture("dirty_time")
	print("stage dirty: global")
	RenderingServer.global_shader_parameter_add("gi_validation_tint", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0.12, 0.7, 0.16, 1.0))
	shader.code = "shader_type spatial; global uniform vec4 gi_validation_tint; void fragment() { ALBEDO = gi_validation_tint.rgb; ROUGHNESS = 1.0; SPECULAR = 0.0; }"
	await _settle(64)
	await _capture("dirty_global_green")
	RenderingServer.global_shader_parameter_set("gi_validation_tint", Vector4(0.12, 0.16, 0.7, 1.0))
	await _settle(64)
	await _capture("dirty_global_blue")
	print("stage dirty: restored")
	_green_wall.mesh.material = material
	material.emission_enabled = false
	pixels.fill(Color(0.12, 0.7, 0.16))
	texture.update(pixels)
	await _settle(64)
	await _capture("dirty_restored")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(12)
	await _capture("dirty_disabled_after")
	RenderingServer.global_shader_parameter_remove("gi_validation_tint")
	print("AMD dirty material capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
