extends SceneTree
## Renderer contract: hold, hidden-material preparation, publication, mutation,
## supersession, and same-source reuse with reversed discovery order.

var world: Node3D
var materials: Array[Material] = []
var last_draw := 0
var max_draw_gap_ms := 0.0
var draws := 0


func _initialize() -> void:
	RenderingServer.frame_post_draw.connect(_drawn)
	_run.call_deferred()


func _drawn() -> void:
	var now := Time.get_ticks_usec()
	if last_draw:
		max_draw_gap_ms = maxf(max_draw_gap_ms, (now - last_draw) / 1000.0)
	last_draw = now
	draws += 1


func _material(code: String) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = code
	return material


func _stage(hold: bool, reverse: bool = false) -> void:
	var ids: Array[RID] = []
	for material in materials:
		ids.append(material.get_rid())
	if reverse:
		ids.reverse()
	RenderingServer.scenario_set_amd_gi_preparation(world.get_world_3d().scenario, ids, hold)


func _scene() -> void:
	world = Node3D.new()
	root.add_child(world)
	_stage(true)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.12, 0.15, 0.2)
	world.add_child(env)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 0, 4)
	world.add_child(camera)
	camera.make_current()
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, -25, 0)
	world.add_child(light)
	_add_mesh(materials[0], Vector3.ZERO)


func _add_mesh(material: Material, pos: Vector3) -> void:
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.material_override = material
	mesh.position = pos
	world.add_child(mesh)


func _status() -> Dictionary:
	return RenderingServer.viewport_get_amd_gi_preparation_status(root.get_viewport_rid())


func _wait_ready(label: String) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 120000:
		await process_frame
		await RenderingServer.frame_post_draw
		var status := _status()
		if status.get("ready", false):
			print("PREPARATION ", label, " ms=", Time.get_ticks_msec() - started, " ", status)
			return true
	push_error("PREPARATION timed out: " + label + " " + str(_status()))
	quit(1)
	return false


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	materials.append(_material("shader_type spatial; uniform vec3 tint=vec3(0.4,0.2,0.1); void fragment(){ ALBEDO=tint; ROUGHNESS=0.7; }"))
	materials.append(_material("shader_type spatial; void fragment(){ ALBEDO=vec3(0.1,0.4,0.2); EMISSION=vec3(0.012); }"))
	_scene()
	for frame in 12:
		await process_frame
	assert(_status().get("state") == "gathering", str(_status()))
	assert(not _status().get("ready", true))
	_stage(false, "--reverse" in OS.get_cmdline_user_args())
	if "--quit-pending" in OS.get_cmdline_user_args():
		var pending_material := _material("shader_type spatial; void fragment(){ ALBEDO=vec3(0.3721,0.163,0.611); }")
		_add_mesh(pending_material, Vector3(-1.3, 0, 0))
		var deadline := Time.get_ticks_msec() + 120000
		while Time.get_ticks_msec() < deadline:
			await process_frame
			var status := _status()
			if status.get("state") == "compiling" and int(status.get("completed_passes", 0)) > 0:
				print("PREPARATION quit while workers active: ", status)
				quit()
				return
		push_error("Pending-worker shutdown test missed compilation")
		quit(1)
		return
	if not await _wait_ready("initial"):
		return
	var revision: int = _status().revision
	_add_mesh(materials[1], Vector3(1.3, 0, 0))
	materials[0].set_shader_parameter("tint", Vector3(0.7, 0.1, 0.2))
	for frame in 8:
		await process_frame
		assert(_status().get("ready", false), str(_status()))
		assert(_status().revision == revision, "A prepared material triggered a new shader set")
	print("PREPARATION hidden material spawn and uniform update: PASS")
	# Start a truly new shader set, then retire its scene before publication.
	var late := _material("shader_type spatial; void fragment(){ ALBEDO=vec3(0.37); ROUGHNESS=0.63; }")
	_add_mesh(late, Vector3(-1.3, 0, 0))
	for frame in 5:
		await process_frame
	world.queue_free()
	for frame in 3:
		await process_frame
	_scene()
	for frame in 3:
		await process_frame
	_stage(false, true)
	if not await _wait_ready("scene-return"):
		return
	print("PREPARATION PASS draws=", draws, " max_draw_gap_ms=", max_draw_gap_ms)
	world.queue_free()
	for frame in 3:
		await process_frame
	quit()
