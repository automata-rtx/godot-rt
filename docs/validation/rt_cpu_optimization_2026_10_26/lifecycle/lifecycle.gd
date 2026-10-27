extends SceneTree

# Hard-shadow pixel comparisons, not timing measurements. Each capture must
# match its counterpart from the preserved baseline executable on the same GPU.
const RT := "rendering/lights_and_shadows/raytraced_shadows/"
var _output := ""
var _failures := 0
var _records: Array[Dictionary] = []
var _views: Array[SubViewport] = []
var _worlds: Array[Node3D] = []
var _casters: Array[MeshInstance3D] = []
var _parents: Array[MultiMeshInstance3D] = []
var _cameras: Array[Camera3D] = []
var _suns: Array[DirectionalLight3D] = []
var _locals: Array[OmniLight3D] = []
var _source: ArrayMesh
var _arrays: Array
var _material: StandardMaterial3D
var _multi: MultiMesh


func _initialize() -> void:
	_run.call_deferred()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error("RT_CPU_FIXTURE " + message)
		_failures += 1


func _add_view(size: Vector2i) -> void:
	var view := SubViewport.new()
	view.size = size
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	_views.append(view)
	var world := Node3D.new()
	view.add_child(world)
	_worlds.append(world)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(18, 18)
	ground.mesh = plane
	ground.material_override = _material
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(ground)
	var caster := MeshInstance3D.new()
	caster.mesh = _source
	caster.position = Vector3(-2.3, 0.75, 0)
	world.add_child(caster)
	_casters.append(caster)
	for offset in [Vector3.ZERO, Vector3(0, 0, -2.7)]:
		var parent := MultiMeshInstance3D.new()
		parent.multimesh = _multi
		parent.position = offset
		world.add_child(parent)
		_parents.append(parent)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 30, 0)
	sun.light_angular_distance = 0
	sun.shadow_enabled = true
	sun.shadow_bias = 0.002
	sun.shadow_normal_bias = 0
	world.add_child(sun)
	_suns.append(sun)
	var local := OmniLight3D.new()
	local.position = Vector3(0, 4, 1)
	local.omni_range = 9
	local.light_size = 0
	local.light_energy = 3
	local.shadow_enabled = true
	local.shadow_bias = 0.002
	local.shadow_normal_bias = 0
	local.visible = false
	world.add_child(local)
	_locals.append(local)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 7, 10)
	world.add_child(camera)
	camera.look_at(Vector3(0, 0, -1))
	camera.current = true
	_cameras.append(camera)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.08, 0.1, 0.14)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.15
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world.add_child(world_environment)


func _stage(label: String, frames: int = 8) -> void:
	print("RT_CPU_FIXTURE stage ", label)
	for frame in frames:
		await process_frame
		await RenderingServer.frame_post_draw
	var record := {"stage": label, "views": []}
	for index in _views.size():
		var image := _views[index].get_texture().get_image()
		_expect(not image.is_empty(), label + " empty image")
		_expect(image.save_png(_output.path_join(label + "_" + str(index) + ".png")) == OK, label + " save failed")
		record.views.append({"width": image.get_width(), "height": image.get_height()})
	_records.append(record)


func _run() -> void:
	_output = OS.get_environment("RT_CPU_OUT")
	if _output.is_empty():
		push_error("RT_CPU_FIXTURE requires RT_CPU_OUT")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_output)
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not rd.has_feature(RenderingDevice.SUPPORTS_RAY_QUERY):
		push_error("RT_CPU_FIXTURE requires hardware ray queries")
		quit(1)
		return
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.6, 0.6, 0.6)
	_material.roughness = 1
	var box := BoxMesh.new()
	box.size = Vector3(0.8, 1.5, 0.8)
	_arrays = box.get_mesh_arrays()
	_source = ArrayMesh.new()
	_source.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays)
	_source.surface_set_material(0, _material)
	_multi = MultiMesh.new()
	_multi.transform_format = MultiMesh.TRANSFORM_3D
	_multi.mesh = _source
	_multi.instance_count = 3
	for index in 3:
		_multi.set_instance_transform(index, Transform3D(Basis(), Vector3(-0.5 + index * 1.5, 0.75, 0)))
	_add_view(Vector2i(641, 359))
	await _stage("initial", 32)
	await _stage("unchanged")
	_casters[0].position.x += 0.8
	await _stage("instance_moved")
	_casters[0].position.x -= 0.8
	await _stage("instance_restored")
	var initial_transform := _multi.get_instance_transform(0)
	var moved := initial_transform
	moved.origin.x += 0.8
	_multi.set_instance_transform(0, moved)
	await _stage("element_moved")
	_multi.set_instance_transform(0, initial_transform)
	await _stage("element_restored")
	var original_buffer := _multi.buffer
	var bulk := original_buffer.duplicate()
	# The native MultiMesh buffer is three row-major vec4 transform rows.
	bulk[3] += 1.1
	_multi.buffer = bulk
	await _stage("bulk_moved")
	_multi.buffer = original_buffer
	_parents[1].position.x += 1.2
	await _stage("shared_parent_moved")
	_parents[1].position.x -= 1.2
	_multi.visible_instance_count = 1
	await _stage("visible_count_reduced")
	_multi.visible_instance_count = -1
	await _stage("visible_count_restored")
	# Reallocate the same MultiMesh RID with a different element layout.
	_multi.instance_count = 0
	_multi.use_colors = true
	_multi.instance_count = 3
	for index in 3:
		_multi.set_instance_transform(index, Transform3D(Basis(), Vector3(-0.5 + index * 1.5, 0.75, 0)))
		_multi.set_instance_color(index, Color.WHITE)
	await _stage("layout_reallocated")
	for parent in _parents:
		parent.layers = 2
	_suns[0].shadow_caster_mask = 1
	await _stage("shadow_mask_excluded")
	_suns[0].shadow_caster_mask = 3
	await _stage("shadow_mask_restored")
	ProjectSettings.set_setting(RT + "directional/scatter_casters", 0)
	await _stage("scatter_disabled")
	ProjectSettings.set_setting(RT + "directional/scatter_casters", 2)
	await _stage("scatter_restored")
	_suns[0].rotation_degrees.y += 35
	await _stage("light_rotated")
	_suns[0].rotation_degrees.y -= 35
	_cameras[0].position.x += 3
	_cameras[0].look_at(Vector3(0, 0, -1))
	await _stage("camera_moved")
	_cameras[0].position.x -= 3
	_cameras[0].look_at(Vector3(0, 0, -1))
	_suns[0].visible = false
	_locals[0].visible = true
	await _stage("local_only")
	_locals[0].position.x += 2.2
	await _stage("local_moved")
	_locals[0].visible = false
	_suns[0].visible = true
	var widened: PackedVector3Array = _arrays[Mesh.ARRAY_VERTEX].duplicate()
	for index in widened.size():
		widened[index].x *= 1.6
	_source.surface_update_vertex_region(0, 0, widened.to_byte_array())
	await _stage("same_buffer_geometry_changed")
	_source.clear_surfaces()
	_source.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays)
	_source.surface_set_material(0, _material)
	await _stage("source_buffers_replaced")
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.albedo_color = Color(0.6, 0.6, 0.6, 0.25)
	_source.surface_set_material(0, glass)
	await _stage("surface_noncasting_material")
	_source.surface_set_material(0, _material)
	await _stage("surface_material_restored")
	# Test a nonempty renderer scene with an empty shadow TLAS, then repopulate it.
	for parent in _parents:
		parent.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_casters[0].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await _stage("all_shadow_casters_disabled")
	for parent in _parents:
		parent.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_casters[0].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	await _stage("shadow_casters_restored")
	_add_view(Vector2i(319, 181))
	_casters[1].position.x += 1.0
	_parents[3].position.x -= 1.0
	await _stage("two_independent_views")
	_casters[0].position.z += 0.6
	_casters[1].position.z -= 0.9
	_views[1].size = Vector2i(353, 199)
	await _stage("both_views_changed")
	# Drop all owners of the old source, freeing its BLAS and reverse TLAS links.
	for caster in _casters:
		caster.mesh = null
	for parent in _parents:
		parent.multimesh = null
	_multi = null
	_source = null
	await _stage("source_freed")
	_source = ArrayMesh.new()
	_source.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays)
	_source.surface_set_material(0, _material)
	_multi = MultiMesh.new()
	_multi.transform_format = MultiMesh.TRANSFORM_3D
	_multi.use_colors = true
	_multi.mesh = _source
	_multi.instance_count = 3
	for index in 3:
		_multi.set_instance_transform(index, Transform3D(Basis(), Vector3(-0.5 + index * 1.5, 0.75, 0)))
		_multi.set_instance_color(index, Color.WHITE)
	for parent in _parents:
		parent.multimesh = _multi
	for caster in _casters:
		caster.mesh = _source
	await _stage("source_recreated")
	var file := FileAccess.open(_output.path_join("lifecycle.json"), FileAccess.WRITE)
	_expect(file != null, "manifest open failed")
	if file:
		file.store_string(JSON.stringify({"failures": _failures, "stages": _records}, "\t"))
	print("RT_CPU_FIXTURE complete failures=%d" % _failures)
	quit(1 if _failures else 0)
