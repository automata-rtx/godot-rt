extends Node3D

# Regression captures for the geometry cache shared by future ray-query clients.
# Compare each capture with the SAME capture from a baseline engine. Compressed
# geometry is not expected to be byte-identical to uncompressed geometry.

var _casters: Array[MeshInstance3D] = []
var _arrays: Array


func _ready() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not rd.has_feature(RenderingDevice.SUPPORTS_RAY_QUERY):
		push_error("Geometry validation requires ray queries; shadow-map fallback is not a test.")
		get_tree().quit(1)
		return
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	ground.mesh = plane
	add_child(ground)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.6, 0.6, 0.6)
	material.roughness = 1.0
	ground.material_override = material
	for x in [-1.2, 1.2]:
		var caster := MeshInstance3D.new()
		caster.position = Vector3(x, 0.6, 0)
		caster.material_override = material
		add_child(caster)
		_casters.append(caster)
	var box := BoxMesh.new()
	box.size = Vector3(0.8, 1.2, 0.8)
	_arrays = box.get_mesh_arrays()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 35, 0)
	sun.light_angular_distance = 0.0
	sun.shadow_enabled = true
	sun.shadow_bias = 0.002
	sun.shadow_normal_bias = 0.0
	add_child(sun)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 4.5, 7)
	camera.rotation_degrees = Vector3(-30, 0, 0)
	camera.current = true
	add_child(camera)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.05, 0.07, 0.1)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.2
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)
	_run.call_deferred()


func _set_mesh(mesh: Mesh) -> void:
	for caster in _casters:
		caster.mesh = mesh


func _settle(frames: int) -> void:
	for frame in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _capture(label: String) -> void:
	await _settle(24)
	var output := OS.get_environment("SHADOW_OUT_DIR")
	if output.is_empty():
		output = "res://out"
	var error := get_viewport().get_texture().get_image().save_png(output.path_join(label + ".png"))
	print("saved %s err=%d" % [label, error])
	if error != OK:
		get_tree().quit(1)


func _run() -> void:
	print("=== geometry cache: shared, indexed, compressed, replaced, deformed, evicted ===")
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays)
	_set_mesh(mesh)
	await _capture("geometry_indexed")
	# Updating bytes keeps the source buffer RID. The shared BLAS must still
	# rebuild, rather than retaining the old silhouette until mesh replacement.
	var widened: PackedVector3Array = _arrays[Mesh.ARRAY_VERTEX].duplicate()
	for i in widened.size():
		widened[i].x *= 1.7
	mesh.surface_update_vertex_region(0, 0, widened.to_byte_array())
	await _capture("geometry_inplace_vertices")
	var widened_arrays: Array = _arrays.duplicate(true)
	widened_arrays[Mesh.ARRAY_VERTEX] = widened
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, widened_arrays)
	await _capture("geometry_inplace_rebuilt")
	var index_count: int = _arrays[Mesh.ARRAY_INDEX].size()
	var index_stride := RenderingServer.mesh_surface_get_format_index_stride(mesh.surface_get_format(0), widened.size())
	var empty_indices := PackedByteArray()
	empty_indices.resize(index_count * index_stride)
	empty_indices.fill(0)
	RenderingServer.mesh_surface_update_index_region(mesh.get_rid(), 0, 0, empty_indices)
	await _capture("geometry_inplace_indices")
	var degenerate := PackedInt32Array()
	degenerate.resize(index_count)
	degenerate.fill(0)
	widened_arrays[Mesh.ARRAY_INDEX] = degenerate
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, widened_arrays)
	await _capture("geometry_indices_rebuilt")
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays)
	for caster in _casters:
		caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await _capture("geometry_control_none")
	for caster in _casters:
		caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

	# Expand every attribute with the original index stream, preserving triangles.
	var expanded: Array = _arrays.duplicate(true)
	var indices: PackedInt32Array = _arrays[Mesh.ARRAY_INDEX]
	for channel in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TANGENT]:
		var source = _arrays[channel]
		var stride := 4 if channel == Mesh.ARRAY_TANGENT else 1
		expanded[channel].resize(indices.size() * stride)
		for i in indices.size():
			for component in stride:
				expanded[channel][i * stride + component] = source[indices[i] * stride + component]
	expanded[Mesh.ARRAY_INDEX] = null
	mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, expanded)
	_set_mesh(mesh)
	await _capture("geometry_nonindexed")

	mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays, [], {}, Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
	_set_mesh(mesh)
	await _capture("geometry_compressed")

	# Force the 32-bit index format without adding triangles or changing the view.
	var wide: Array = []
	wide.resize(Mesh.ARRAY_MAX)
	var vertices: PackedVector3Array = _arrays[Mesh.ARRAY_VERTEX].duplicate()
	var normals: PackedVector3Array = _arrays[Mesh.ARRAY_NORMAL].duplicate()
	vertices.resize(65537)
	normals.resize(65537)
	wide[Mesh.ARRAY_VERTEX] = vertices
	wide[Mesh.ARRAY_NORMAL] = normals
	wide[Mesh.ARRAY_INDEX] = indices
	mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wide)
	_set_mesh(mesh)
	await _capture("geometry_index32")

	# Keep the mesh RID; replacing the source buffers must retire the old BLAS.
	var replacement: Array = _arrays.duplicate(true)
	for i in replacement[Mesh.ARRAY_VERTEX].size():
		replacement[Mesh.ARRAY_VERTEX][i].x *= 1.7
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, replacement)
	await _capture("geometry_replaced")

	var delta: Array = []
	delta.resize(Mesh.ARRAY_MAX)
	var positions := PackedVector3Array()
	positions.resize(_arrays[Mesh.ARRAY_VERTEX].size())
	positions.fill(Vector3(0, 0.45, 0))
	var delta_normals := PackedVector3Array()
	delta_normals.resize(positions.size())
	var delta_tangents := PackedFloat32Array()
	delta_tangents.resize(positions.size() * 4)
	delta[Mesh.ARRAY_VERTEX] = positions
	delta[Mesh.ARRAY_NORMAL] = delta_normals
	delta[Mesh.ARRAY_TANGENT] = delta_tangents
	mesh = ArrayMesh.new()
	mesh.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_RELATIVE
	mesh.add_blend_shape("lift")
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays, [delta])
	_set_mesh(mesh)
	await _capture("geometry_rest_pose")
	for caster in _casters:
		caster.set_blend_shape_value(0, 1.0)
	await _capture("geometry_deformed")
	for caster in _casters:
		caster.set_blend_shape_value(0, 0.0)
	await _capture("geometry_restored")

	# Hold the source resource while it leaves the cache for more than 60 updates.
	_set_mesh(null)
	await _settle(72)
	_set_mesh(mesh)
	await _capture("geometry_after_eviction")
	_set_mesh(null)
	mesh = null
	await _capture("geometry_freed")
	get_tree().quit()
