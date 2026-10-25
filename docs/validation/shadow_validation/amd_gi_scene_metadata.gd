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


func _metadata_mesh(material: Material) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.2, 0.0, 0.0), Vector3(0.2, 0.0, 0.0), Vector3(0.0, 0.4, 0.0)
	])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.UP])
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
	RenderingServer.global_shader_parameter_add("gi_metadata_global", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.1)
	var shader := Shader.new()
	shader.code = SOURCE
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
	await _settle_metadata("initial shared static mesh", 8)
	await _settle_metadata("unchanged metadata with TIME advancing", 8)
	material.set_shader_parameter("tint", Color(0.8, 0.2, 0.1))
	await _settle_metadata("shared local uniform only")
	RenderingServer.global_shader_parameter_set("gi_metadata_global", 0.7)
	instances[1].set_instance_shader_parameter("gi_metadata_instance", 0.4)
	await _settle_metadata("global and instance values only")
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
	shader.code = SOURCE.replace("uniform vec4 tint", "uniform vec4 extra;\nuniform vec4 tint").replace("ALBEDO = texture", "ALBEDO = extra.rgb + texture")
	material.set_shader_parameter("extra", Vector4(0.1, 0.0, 0.0, 0.0))
	await _settle_metadata("uniform buffer layout grows")
	shader.code = SOURCE.replace("ROUGHNESS = 1.0;", "ROUGHNESS = 1.0; ALPHA = 0.6;")
	await _settle_metadata("shader alpha changes TLAS flags")
	shader.code = SOURCE
	await _settle_metadata("original shader layout restored")
	shader.code = SOURCE.replace("cull_disabled", "cull_front").replace("EMISSION = ALBEDO", "ALBEDO = ALBEDO")
	await _settle_metadata("cull changes and emission membership removed")
	shader.code = SOURCE
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
	await _settle_metadata("MultiMesh added")
	multimesh.set_instance_color(1, Color(0.2, 0.8, 0.1))
	multimesh.set_instance_custom_data(2, Color(0.7, 0.1, 0.2))
	await _settle_metadata("MultiMesh color and custom data only")
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
