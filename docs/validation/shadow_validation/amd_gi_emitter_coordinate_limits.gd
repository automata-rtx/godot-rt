extends Node3D

func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/reflections/enabled", false)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	add_child(world)
	var cases := {
		"nonlinear": "EMISSION = texture(test_map, UV * UV).rgb;",
		"partial_write": "vec2 mapped = UV; mapped.x *= 0.25; EMISSION = texture(test_map, mapped).rgb;",
		"loop": "vec2 mapped = UV; for (int i=0; i<2; i++) { mapped *= 0.5; } EMISSION = texture(test_map, mapped).rgb;",
		"texture_dependent": "EMISSION = texture(test_map, UV + texture(test_map, UV).xy * 0.1).rgb;",
		"helper": "EMISSION = texture(test_map, remap(UV)).rgb;",
	}
	var i := 0
	for label: String in cases:
		var shader := Shader.new()
		shader.take_over_path("res://coordinate_limit_%s.gdshader" % label)
		shader.code = "shader_type spatial; uniform sampler2D test_map : filter_nearest_mipmap; vec2 remap(vec2 p) { return p * 0.5; } void fragment() { %s }" % cases[label]
		var material := ShaderMaterial.new()
		material.shader = shader
		var mesh := BoxMesh.new()
		mesh.material = material
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		instance.position.x = i * 1.5
		add_child(instance)
		i += 1
	var camera := Camera3D.new()
	camera.position = Vector3(3, 0, 10)
	add_child(camera)
	camera.make_current()
	for frame in 4:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	print("COORDINATE LIMITS FINISHED")
	get_tree().quit()
