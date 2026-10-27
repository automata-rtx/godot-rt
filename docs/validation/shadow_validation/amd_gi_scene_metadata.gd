extends "res://gi.gd"

# Exercise the native metadata cache with GODOT_AMD_GI_VALIDATE_SCENE_CACHE=1.
# Engine oracle failures are errors: the runner must reject any such log entry,
# not only check this script's completion marker/process exit code.
const GI := "rendering/global_illumination/amd_gi/"
const SOURCE := """shader_type spatial;
render_mode cull_disabled, depth_draw_always;
uniform sampler2D source_map : filter_nearest, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0);
global uniform float gi_metadata_global;
instance uniform float gi_metadata_instance = 0.0;
varying vec4 instance_color;
void vertex() { instance_color = COLOR + INSTANCE_CUSTOM * 0.1; }
void fragment() {
    ALBEDO = texture(source_map, UV).rgb * tint.rgb * instance_color.rgb;
    ROUGHNESS = 1.0;
    EMISSION = ALBEDO * (gi_metadata_global + gi_metadata_instance + 0.01 * (sin(TIME) + 1.0));
}
"""


func _settle_metadata(label: String, frames: int = 4) -> void:
	print("SCENE_METADATA stage ", label)
	for frame in frames:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw


func _metadata_mesh(material: Material, triangle_count: int = 1) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	for triangle in triangle_count:
		var offset := Vector3(float(triangle) * 0.04, 0, 0)
		vertices.append_array(PackedVector3Array([
			Vector3(-0.2, 0.0, 0.0) + offset, Vector3(0.2, 0.0, 0.0) + offset, Vector3(0.0, 0.4, 0.0) + offset
		]))
		normals.append_array(PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK]))
		uvs.append_array(PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.UP]))
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
	mesh.surface_set_material(0, material)
	return mesh


func _run() -> void:
	if OS.get_environment("GODOT_AMD_GI_VALIDATE_SCENE_CACHE").is_empty():
		push_error("SCENE_METADATA requires GODOT_AMD_GI_VALIDATE_SCENE_CACHE=1")
		get_tree().quit(1)
		return
	ProjectSettings.set_setting(GI + "enabled", true)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "emissive_sampling", true)
	# Exercise both ordinary and emission-writing retained scene groups.
	var retained_subjects := OS.get_environment("GODOT_AMD_GI_TEST_NONEMISSIVE_METADATA") == "1"
	var source := SOURCE
	if retained_subjects:
		source = source.replace("EMISSION = ALBEDO *", "ALBEDO *= 0.5 +")
	print("RETAINED_METADATA mode ", "nonemissive" if retained_subjects else "emissive")
	RenderingServer.global_shader_parameter_add("gi_metadata_global", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.1)
	var shader := Shader.new()
	shader.code = source
	var material := ShaderMaterial.new()
	material.shader = shader
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.3, 0.5, 0.7))
	var texture := ImageTexture.create_from_image(image)
	material.set_shader_parameter("source_map", texture)
	var mesh := _metadata_mesh(material)
	var instances: Array[MeshInstance3D] = []
	for i in 24:
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.position = Vector3(float(i % 8) * 0.5 - 1.75, 0.5 + float(i / 8) * 0.5, -1.5)
		add_child(node)
		instances.append(node)
	print("RETAINED_METADATA subject mesh ", instances[1].get_instance())
	await _settle_metadata("initial shared static mesh", 8)
	await _settle_metadata("unchanged metadata with TIME advancing", 8)
	material.set_shader_parameter("tint", Color(0.8, 0.2, 0.1))
	await _settle_metadata("shared local uniform only")
	RenderingServer.global_shader_parameter_set("gi_metadata_global", 0.7)
	instances[1].set_instance_shader_parameter("gi_metadata_instance", 0.4)
	await _settle_metadata("global and instance values only")
	# A late non-triangle surface stops preparation after earlier record writes.
	# Restoring the early input before retry catches stale partial publication.
	var original_transform := instances[1].transform
	instances[1].position.x += 0.2
	var line_arrays := []
	line_arrays.resize(Mesh.ARRAY_MAX)
	line_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.UP])
	var line_mesh := ArrayMesh.new()
	line_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, line_arrays)
	line_mesh.surface_set_material(0, material)
	var late_failure := MeshInstance3D.new()
	late_failure.mesh = line_mesh
	late_failure.position = Vector3(0, 1, -1)
	add_child(late_failure)
	print("RETAINED_METADATA subject deferred ", late_failure.get_instance())
	await _settle_metadata("late geometry failure after earlier record writes", 6)
	instances[1].transform = original_transform
	late_failure.queue_free()
	await _settle_metadata("recovery after discarded partial preparation", 8)
	image.fill(Color(0.1, 0.8, 0.2))
	texture.update(image)
	await _settle_metadata("same texture resource pixels")
	var replacement := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	replacement.fill(Color(0.8, 0.1, 0.4))
	texture.set_image(replacement)
	await _settle_metadata("same Texture2D resource replaced RD image")
	material.set_shader_parameter("source_map", ImageTexture.create_from_image(image))
	await _settle_metadata("different texture binding")
	material.set_shader_parameter("source_map", null)
	shader.set_default_texture_parameter("source_map", texture)
	await _settle_metadata("shader default texture")
	material.shader = null
	await _settle_metadata("null shader without mesh mutation")
	material.shader = shader
	await _settle_metadata("shader restored")
	material.next_pass = StandardMaterial3D.new()
	await _settle_metadata("next pass removes unsupported surfaces")
	material.next_pass = null
	await _settle_metadata("next pass removed restores dense IDs")
	shader.code = source.replace("uniform vec4 tint", "uniform vec4 extra;\nuniform vec4 tint").replace("ALBEDO = texture", "ALBEDO = extra.rgb + texture")
	material.set_shader_parameter("extra", Vector4(0.1, 0.0, 0.0, 0.0))
	await _settle_metadata("uniform buffer layout grows")
	shader.code = source.replace("ROUGHNESS = 1.0;", "ROUGHNESS = 1.0; ALPHA = 0.6;")
	await _settle_metadata("shader alpha changes TLAS flags")
	shader.code = source
	await _settle_metadata("original shader layout restored")
	shader.code = source.replace("cull_disabled", "cull_front").replace("EMISSION = ALBEDO", "ALBEDO = ALBEDO")
	await _settle_metadata("cull changes and emission membership removed")
	shader.code = SOURCE
	await _settle_metadata("retained subjects write emission", 8)
	ProjectSettings.set_setting(GI + "emissive_sampling", false)
	await _settle_metadata("emissive sampling disabled", 8)
	ProjectSettings.set_setting(GI + "emissive_sampling", true)
	await _settle_metadata("emissive sampling restored", 8)
	shader.code = SOURCE.replace("EMISSION = ALBEDO *", "ALBEDO *= 0.5 +")
	await _settle_metadata("emission removed restores retained subjects", 8)
	shader.code = SOURCE
	await _settle_metadata("emission restored rebuilds retained emitter ranges", 8)
	shader.code = source
	await _settle_metadata("configured emission mode restored", 8)
	instances[4].transform = Transform3D(Basis.from_scale(Vector3(-1.2, 0.8, 1.0)), Vector3(-0.5, 1.7, -1.4))
	instances[5].layers = 2
	await _settle_metadata("mirrored nonuniform transform and layers")
	var primitive := BoxMesh.new()
	primitive.material = material
	instances[6].mesh = primitive
	await _settle_metadata("primitive source geometry")
	primitive.size = Vector3(0.3, 0.5, 0.2)
	await _settle_metadata("same PrimitiveMesh RID replaces surface buffers")
	instances[6].mesh = mesh
	mesh.surface_update_attribute_region(0, 0, PackedFloat32Array([0.75, 0.25]).to_byte_array())
	await _settle_metadata("UV attribute region without dependency notification")
	mesh.surface_update_vertex_region(0, 0, PackedFloat32Array([-0.3, 0.05, 0.0]).to_byte_array())
	await _settle_metadata("vertex region without dependency notification")
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	multimesh.instance_count = 4
	for i in 4:
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(float(i) * 0.5 - 0.75, 2.1, -1.0)))
		multimesh.set_instance_color(i, Color.WHITE)
	var multi_node := MultiMeshInstance3D.new()
	multi_node.multimesh = multimesh
	add_child(multi_node)
	print("RETAINED_METADATA subject multimesh ", multi_node.get_instance())
	await _settle_metadata("MultiMesh added")
	# Earlier emitter topology changes later prefixes without changing later
	# subjects' own materials, transforms or dense surface IDs.
	var prefix_shader := Shader.new()
	prefix_shader.code = SOURCE
	var prefix_material := ShaderMaterial.new()
	prefix_material.shader = prefix_shader
	prefix_material.set_shader_parameter("source_map", texture)
	instances[0].material_override = prefix_material
	await _settle_metadata("earlier emitter prefix established")
	instances[0].mesh = _metadata_mesh(material, 2)
	await _settle_metadata("earlier emitter triangle count changes downstream prefixes", 8)
	instances[0].material_override = StandardMaterial3D.new()
	await _settle_metadata("earlier emitter membership removed", 8)
	instances[0].material_override = prefix_material
	await _settle_metadata("earlier emitter membership restored", 8)
	instances[0].mesh = mesh
	instances[0].material_override = null
	await _settle_metadata("earlier emitter source restored", 8)
	multi_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await _settle_metadata("MultiMesh shadow mask disabled")
	multi_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	multi_node.material_override = StandardMaterial3D.new()
	await _settle_metadata("MultiMesh material override")
	multi_node.material_override = null
	await _settle_metadata("MultiMesh material and shadow mask restored")
	multimesh.set_instance_color(1, Color(0.2, 0.8, 0.1))
	multimesh.set_instance_custom_data(2, Color(0.7, 0.1, 0.2))
	await _settle_metadata("MultiMesh color and custom data only")
	multimesh.set_instance_transform(2, Transform3D(Basis.IDENTITY, Vector3(0.3, 2.4, -0.9)))
	await _settle_metadata("visible nonfirst MultiMesh element moves with count unchanged")
	multimesh.set_instance_transform(3, Transform3D(Basis.IDENTITY, Vector3(0.5, 2.3, -0.8)))
	multimesh.visible_instance_count = 2
	await _settle_metadata("MultiMesh transform and visible count")
	multimesh.visible_instance_count = -1
	# DressingBatch uses complete CPU buffer uploads, unlike the individual
	# setters above. Exercise that path while preserving color/custom layout.
	var bulk := multimesh.buffer
	for i in 4:
		var offset := i * 20 # 12 transform floats, then RGBA color and custom.
		bulk[offset + 3] += 0.15
		bulk[offset + 7] += 0.05 * float(i)
		bulk[offset + 12] = 0.15 + 0.2 * float(i)
		bulk[offset + 16] = 0.8 - 0.15 * float(i)
	multimesh.buffer = bulk
	await _settle_metadata("MultiMesh bulk transforms colors and custom data")
	multi_node.transform = Transform3D(Basis.from_scale(Vector3(-1.0, 0.75, 1.25)), Vector3(0.2, 0.1, 0.0))
	multimesh.visible_instance_count = 0
	await _settle_metadata("MultiMesh transformed parent and zero visible prefix")
	multimesh.visible_instance_count = 3
	await _settle_metadata("MultiMesh transformed parent and restored visible prefix")
	# Fresh allocation plus a bulk upload has no preexisting element cache,
	# matching authored dressing loaded from PackedFloat32Array transforms.
	var dressing := MultiMesh.new()
	dressing.transform_format = MultiMesh.TRANSFORM_3D
	dressing.mesh = mesh
	dressing.instance_count = 2
	var dressing_buffer := PackedFloat32Array([
		1, 0, 0, -0.4, 0, 1, 0, 1.2, 0, 0, 1, -1.2,
		-1, 0, 0, 0.4, 0, 0.8, 0, 1.3, 0, 0, 1.2, -1.2
	])
	dressing.buffer = dressing_buffer
	multi_node.multimesh = dressing
	await _settle_metadata("fresh transform-only MultiMesh bulk buffer")
	dressing_buffer[3] += 0.3
	dressing_buffer[19] += 0.1
	dressing.buffer = dressing_buffer
	await _settle_metadata("retained MultiMesh bulk replacement")
	multi_node.multimesh = multimesh
	multimesh.visible_instance_count = -1
	await _settle_metadata("MultiMesh resource identity restored")
	# These paths must invalidate value reuse even when ordinary dependency
	# notifications are absent, or another parent shares the same source.
	var shared_multi_node := MultiMeshInstance3D.new()
	shared_multi_node.multimesh = multimesh
	shared_multi_node.position = Vector3(0.3, -0.2, -0.1)
	add_child(shared_multi_node)
	await _settle_metadata("MultiMesh shared by differently transformed parents")
	shared_multi_node.position.x += 0.2
	await _settle_metadata("one shared MultiMesh parent moves")
	mesh.custom_aabb = AABB(Vector3(-0.5, -0.1, -0.1), Vector3(1.0, 0.8, 0.2))
	await _settle_metadata("mesh bounds change without MultiMesh data change")
	mesh.custom_aabb = AABB()
	shared_multi_node.queue_free()
	var fixed_bounds := MultiMesh.new()
	fixed_bounds.transform_format = MultiMesh.TRANSFORM_3D
	fixed_bounds.mesh = mesh
	fixed_bounds.instance_count = 2
	fixed_bounds.custom_aabb = AABB(Vector3(-2, -2, -3), Vector3(4, 5, 6))
	fixed_bounds.buffer = dressing_buffer
	multi_node.multimesh = fixed_bounds
	await _settle_metadata("fresh bulk MultiMesh with custom AABB")
	dressing_buffer[3] += 0.25
	fixed_bounds.buffer = dressing_buffer
	await _settle_metadata("custom AABB bulk write after cached expansion")
	fixed_bounds.instance_count = 0
	fixed_bounds.use_colors = true
	fixed_bounds.instance_count = 2
	for i in 2:
		fixed_bounds.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(-0.3 + i * 0.6, 1.8, -1.2)))
		fixed_bounds.set_instance_color(i, Color.WHITE)
	await _settle_metadata("same MultiMesh identity reallocates data layout")
	# Interpolation uploads rendered elements through the backend bulk path.
	# Advancing input once per physics tick must not leave a cached render pose.
	get_tree().physics_interpolation = true
	multi_node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	await _settle_metadata("MultiMesh physics interpolation enabled")
	for step in 4:
		await get_tree().physics_frame
		fixed_bounds.set_instance_transform(0, Transform3D(Basis.IDENTITY, Vector3(-0.3 + step * 0.08, 1.8, -1.2)))
		await _settle_metadata("interpolated MultiMesh pose %d" % step, 2)
	multi_node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	get_tree().physics_interpolation = false
	multi_node.multimesh = multimesh
	# Direct server callers can replace the base type on an existing instance.
	# Its previous MultiMesh expansion must die with the old base-data owner.
	RenderingServer.instance_set_base(multi_node.get_instance(), mesh.get_rid())
	await _settle_metadata("same rendering instance changes from MultiMesh to mesh")
	RenderingServer.instance_set_base(multi_node.get_instance(), multimesh.get_rid())
	await _settle_metadata("same rendering instance restores MultiMesh base type")
	# A second viewport updates a different scene between main-scene updates.
	# A global render-frame stamp is not a valid preparation-cache epoch.
	var second_view := SubViewport.new()
	second_view.size = Vector2i(96, 64)
	second_view.own_world_3d = true
	second_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(second_view)
	var second_environment := WorldEnvironment.new()
	second_environment.environment = Environment.new()
	second_view.add_child(second_environment)
	var second_mesh := MeshInstance3D.new()
	second_mesh.mesh = mesh
	second_view.add_child(second_mesh)
	var second_camera := Camera3D.new()
	second_camera.position = Vector3(0, 0.2, 2)
	second_view.add_child(second_camera)
	second_camera.current = true
	await _settle_metadata("separate viewport and scene in the same engine frame", 8)
	second_mesh.position.x += 0.1
	await _settle_metadata("second scene moves while main scene remains unchanged")
	second_view.queue_free()
	await _settle_metadata("second viewport resources released")
	instances[0].visible = false
	instances[2].gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	instances[3].material_override = StandardMaterial3D.new()
	await _settle_metadata("visibility GI mode and override")
	instances[0].visible = true
	instances[2].gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	instances[3].material_override = null
	for i in 80:
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.position = Vector3(float(i % 10) * 0.12 - 0.6, 0.3 + float(i / 10) * 0.1, -2.0)
		add_child(node)
		instances.append(node)
	await _settle_metadata("context buffer growth")
	for i in range(8, instances.size()):
		instances[i].queue_free()
	instances.resize(8)
	await _settle_metadata("membership shrink and resource expiry")
	for node in instances:
		node.mesh = _metadata_mesh(material)
	await _settle_metadata("mesh identity replacement")
	ProjectSettings.set_setting(GI + "enabled", false)
	await _settle_metadata("GI disabled")
	ProjectSettings.set_setting(GI + "enabled", true)
	await _settle_metadata("GI re-enabled", 8)
	print("SCENE_METADATA complete; runner must also reject engine oracle errors")
	get_tree().quit()
