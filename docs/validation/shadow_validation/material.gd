extends Node3D

# Native-material capture checks against analytically known shader outputs.
# This validates an explicit capture operation, not a GI lighting algorithm.
var _failures := 0


func _ready() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error(message)


func _near(actual: float, expected: float, label: String, tolerance := 0.006) -> void:
	_check(absf(actual - expected) <= tolerance, "%s: got %f, expected %f" % [label, actual, expected])


func _mesh(indexed := true, compressed := false) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
		Vector3(2, 0, 0), Vector3(3, 0, 0), Vector3(2, 1, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_TANGENT] = PackedFloat32Array([1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2(0.8, 0), Vector2(0, 0.8), Vector2.ZERO, Vector2(0.8, 0), Vector2(0, 0.8)])
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(0.2, 0.6), Vector2(0.2, 0.6), Vector2(0.2, 0.6), Vector2(0.8, 0.3), Vector2(0.8, 0.3), Vector2(0.8, 0.3)])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color(0.4, 0, 0), Color(0.4, 0, 0), Color(0.4, 0, 0), Color(0.4, 0, 0), Color(0.4, 0, 0), Color(0.4, 0, 0)])
	var custom := PackedFloat32Array()
	for vertex in 6:
		custom.append_array(PackedFloat32Array([0.125, 0.25, 0.5, 1]))
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	if indexed:
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([3, 4, 5, 0, 1, 2])
	var flags := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	if compressed:
		flags |= Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	return mesh


func _material(code: String) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


func _capture(mesh: ArrayMesh, material: Material, first := 0, transform := Transform3D.IDENTITY) -> Array[Image]:
	var images := RenderingServer.bake_render_triangle_material(mesh.get_rid(), 0, first, 1, 16, transform, material.get_rid())
	_check(images.size() == 4, "capture must return four material channels")
	if images.size() == 4:
		_check(images[0].get_size() == Vector2i(16, 16), "one triangle must occupy one tile")
	return images


func _run() -> void:
	print("=== triangle material capture: native shader attribute and update checks ===")
	var material := _material("""
shader_type spatial;
uniform float tint = 0.5;
varying float source_vertex_id;
varying vec4 custom_data;
void vertex() { source_vertex_id = float(VERTEX_ID); custom_data = CUSTOM0; }
void fragment() {
    ALBEDO = vec3(UV2, COLOR.r);
    ROUGHNESS = UV.x;
    METALLIC = UV.y;
    EMISSION = vec3(source_vertex_id, custom_data.x, tint);
}
""")
	for compressed in [false, true]:
		var mesh := _mesh(true, compressed)
		var original_uv2: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
		var images := _capture(mesh, material)
		if images.size() != 4:
			continue
		var albedo := images[0].get_pixel(4, 4)
		var orm := images[2].get_pixel(4, 4)
		var emission := images[3].get_pixel(4, 4)
		_near(albedo.r, 0.8, "original UV2.x")
		_near(albedo.g, 0.3, "original UV2.y")
		_near(albedo.b, 0.4, "original COLOR.r")
		_near(orm.g, 0.2, "interpolated UV.x")
		_near(orm.b, 0.2, "interpolated UV.y")
		_near(emission.r, 3.75, "original indexed VERTEX_ID", 0.01)
		_near(emission.g, 0.125, "original CUSTOM0.x")
		_near(emission.b, 0.5, "initial material uniform")
		_near(images[1].get_pixel(4, 4).b, 1, "source normal")
		_check(mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2] == original_uv2, "capture modified the source UV2 array")
		images = _capture(mesh, material, 1)
		if images.size() == 4:
			_near(images[3].get_pixel(4, 4).r, 0.75, "triangle range/source ID mapping", 0.01)
			_near(images[0].get_pixel(4, 4).r, 0.2, "triangle range/original UV2")
		var normal_material := _material("""
shader_type spatial;
void fragment() { NORMAL_MAP = vec3(0.8, 0.5, 0.9); }
""")
		images = _capture(mesh, normal_material)
		if images.size() == 4:
			var encoded := images[1].get_pixel(4, 4)
			# The native bake pass uses best-fit encoding, just like the prepass.
			var normal := (Vector3(encoded.r, encoded.g, encoded.b) * 2 - Vector3.ONE).normalized()
			_near(normal.x, 0.6, "tangent-space normal X", 0.01)
			_near(normal.y, 0, "tangent-space normal Y", 0.01)
			_near(normal.z, 0.8, "tangent-space normal Z", 0.01)
	var mesh := _mesh(false)
	var images := _capture(mesh, material)
	if images.size() == 4:
		_near(images[3].get_pixel(4, 4).r, 0.75, "non-indexed VERTEX_ID", 0.01)
	material.set_shader_parameter("tint", 2.0)
	images = _capture(mesh, material)
	if images.size() == 4:
		_near(images[3].get_pixel(4, 4).b, 2.0, "immediate material update/HDR emission")

	var world_material := _material("""
shader_type spatial;
varying vec3 world_position;
void vertex() { world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() { EMISSION = world_position; }
""")
	images = _capture(mesh, world_material, 0, Transform3D(Basis.IDENTITY, Vector3(2, 3, 4)))
	if images.size() == 4:
		var world := images[3].get_pixel(4, 4)
		_near(world.r, 2.25, "world transform X", 0.01)
		_near(world.g, 3.25, "world transform Y", 0.01)
		_near(world.b, 4, "world transform Z", 0.01)
	var cutout := _material("""
shader_type spatial;
uniform float opacity = 0.25;
void fragment() { ALBEDO = vec3(0.2); ALPHA = opacity; ALPHA_SCISSOR_THRESHOLD = 0.5; }
""")
	images = _capture(mesh, cutout)
	if images.size() == 4:
		_near(images[0].get_pixel(4, 4).a, 0, "cutout below threshold")
	cutout.set_shader_parameter("opacity", 0.75)
	images = _capture(mesh, cutout)
	if images.size() == 4:
		_near(images[0].get_pixel(4, 4).a, 1, "cutout above threshold")

	var texture_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	texture_image.fill(Color.RED)
	var texture := ImageTexture.create_from_image(texture_image)
	var standard := StandardMaterial3D.new()
	standard.albedo_texture = texture
	images = _capture(mesh, standard)
	if images.size() == 4:
		_near(images[0].get_pixel(4, 4).r, 1, "StandardMaterial3D texture")
	texture_image.fill(Color.GREEN)
	texture.update(texture_image)
	images = _capture(mesh, standard)
	if images.size() == 4:
		_near(images[0].get_pixel(4, 4).r, 0, "updated texture red")
		_near(images[0].get_pixel(4, 4).g, 1, "updated texture green")

	# Page sizing, clipping at the end of a surface, and source material selection.
	mesh.surface_set_material(0, standard)
	images = RenderingServer.bake_render_triangle_material(mesh.get_rid(), 0, 0, 64, 8)
	_check(images.size() == 4, "surface material capture")
	if images.size() == 4:
		_check(images[0].get_size() == Vector2i(16, 8), "page clips to the two source triangles")
		_near(images[0].get_pixel(2, 2).g, 1, "surface material first tile")
		_near(images[0].get_pixel(10, 2).g, 1, "surface material second tile")
		_near(images[0].get_pixel(7, 7).a, 0, "unused tile area is cleared")

	# Existing UV2 baking shares the material pass. It must retain its UV layout
	# and native indexed VERTEX_ID after a triangle capture has used the renderer.
	var uv_arrays := mesh.surface_get_arrays(0)
	uv_arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([
		Vector2.ZERO, Vector2(1, 0), Vector2(0, 1),
		Vector2(2, 2), Vector2(3, 2), Vector2(2, 3)])
	var uv_mesh := ArrayMesh.new()
	uv_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, uv_arrays, [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	images = RenderingServer.bake_render_uv2(uv_mesh.get_rid(), [material.get_rid()], Vector2i(16, 16))
	_check(images.size() == 4, "legacy UV2 capture")
	if images.size() == 4:
		_near(images[0].get_pixel(4, 4).r, 4.5 / 16, "legacy UV2 placement")
		_near(images[3].get_pixel(4, 4).r, 3 * 4.5 / 16, "legacy VERTEX_ID", 0.01)
		_near(images[3].get_pixel(4, 4).b, 2, "legacy material uniforms")
	# The automatic scene-budget fallback retains a native sample per triangle.
	# Check all source attributes at its actual barycentric position (1/4,1/4).
	var compact_material := _material("""
shader_type spatial;
varying float original_id;
void vertex() { original_id = float(VERTEX_ID); }
void fragment() {
    ALBEDO = vec3(UV2, COLOR.r);
    ROUGHNESS = UV.x;
    METALLIC = UV.y;
    EMISSION = vec3(original_id, 0.125, 2.0);
}
""")
	for compressed in [false, true]:
		var compact_mesh := _mesh(true, compressed)
		images = RenderingServer.bake_render_triangle_material(compact_mesh.get_rid(), 0, 0, 2, 2, Transform3D.IDENTITY, compact_material.get_rid())
		_check(images.size() == 4, "compact material capture must return all channels")
		if images.size() == 4:
			_check(images[0].get_size() == Vector2i(4, 2), "compact two-triangle placement")
			_near(images[0].get_pixel(0, 0).r, 0.8, "compact source UV2")
			_near(images[0].get_pixel(2, 0).r, 0.2, "compact second triangle UV2")
			_near(images[0].get_pixel(0, 0).a, 1, "compact coverage")
			_near(images[2].get_pixel(0, 0).g, 0.2, "compact UV roughness")
			_near(images[3].get_pixel(0, 0).r, 3.75, "compact original vertex IDs", 0.01)
	print("material capture checks finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
