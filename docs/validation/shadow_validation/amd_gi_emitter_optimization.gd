extends "res://gi.gd"

func settle(count: int = 3) -> void:
	for frame in count:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw

func make_emitter(triangles: int, material: Material) -> MeshInstance3D:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	for i in triangles:
		var x := float(i % 100) * 0.015 - 0.75
		var y := float(i / 100) * 0.002 + 0.3
		for corner in [Vector3(x, y, -1), Vector3(x + 0.01, y, -1), Vector3(x, y + 0.001, -1)]:
			vertices.append(corner)
			normals.append(Vector3(0, 0, 1))
			uvs.append(Vector2(0.75 if i % 37 == 0 else 0.25, 0.5))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	add_child(node)
	return node

func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	var shader := Shader.new()
	shader.code = "shader_type spatial; uniform sampler2D emission_map: filter_nearest, repeat_disable; uniform float energy=1.0; void fragment(){ ALBEDO=vec3(0.5); EMISSION=texture(emission_map,UV).rgb*energy; }"
	var image := Image.create(2, 1, false, Image.FORMAT_RGBAF)
	image.set_pixel(0, 0, Color(0, 0, 0, 1))
	image.set_pixel(1, 0, Color(4, 2, 1, 1))
	var texture := ImageTexture.create_from_image(image)
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("emission_map", texture)
	var moving := make_emitter(65, material)
	var stable := make_emitter(4097, material)
	await settle(5)
	print("EMITTER_OPT stage transforms")
	moving.position.x += 0.3
	await settle()
	print("EMITTER_OPT stage black emission then recovery")
	material.set_shader_parameter("energy", 0.0)
	await settle()
	material.set_shader_parameter("energy", 2.0)
	await settle()
	print("EMITTER_OPT stage texture update")
	image.set_pixel(0, 0, Color(1, 3, 2, 1))
	image.set_pixel(1, 0, Color(0, 0, 0, 1))
	texture.update(image)
	await settle()
	print("EMITTER_OPT stage light membership")
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(0, 1, 0)
	add_child(lamp)
	await settle()
	lamp.queue_free()
	await settle()
	print("EMITTER_OPT stage environment membership and resampling")
	var world: WorldEnvironment
	for child in get_children():
		if child is WorldEnvironment:
			world = child
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	world.environment.sky = sky
	world.environment.background_mode = Environment.BG_SKY
	world.environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/light_resampling", true)
	await settle()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/light_resampling", false)
	await settle()
	print("EMITTER_OPT stage signed HDR and dim emission")
	image.set_pixel(0, 0, Color(-2, 10, -1, 1))
	image.set_pixel(1, 0, Color(0.000001, 0.000001, 0.000001, 1))
	texture.update(image)
	await settle()
	print("EMITTER_OPT stage tiny and distant geometry")
	moving.scale = Vector3.ONE * 0.000001
	material.set_shader_parameter("energy", 0.0)
	await settle()
	moving.position = Vector3(2000000, 0, 0)
	moving.scale = Vector3.ONE * 10000
	await settle()
	moving.position = Vector3.ZERO
	moving.scale = Vector3.ONE
	material.set_shader_parameter("energy", 1.0)
	image.set_pixel(0, 0, Color(1, 3, 2, 1))
	image.set_pixel(1, 0, Color(0, 0, 0, 1))
	texture.update(image)
	await settle()
	print("EMITTER_OPT stage emitter layout and shrink")
	moving.queue_free()
	await settle()
	moving = make_emitter(63, material)
	await settle()
	stable.queue_free()
	await settle()
	moving.queue_free()
	await settle()
	print("EMITTER_OPT stage upper mask boundary")
	var many := make_emitter(262145, material)
	material.set_shader_parameter("energy", 0.0)
	await settle()
	material.set_shader_parameter("energy", 1.0)
	await settle()
	many.queue_free()
	await settle()
	print("EMITTER_OPT stage disable/re-enable")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await settle()
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await settle()
	print("EMITTER_OPT complete")
	get_tree().quit()
