extends Node

# Exercise the production GI source-normal decoder with Godot-packed meshes.
# Expected world normals come from the original authored arrays on the CPU.
func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	var source := RDShaderSource.new()
	source.source_compute = """#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference_uvec2 : require
#extension GL_EXT_shader_16bit_storage : require
#extension GL_EXT_shader_explicit_arithmetic_types_int16 : require
layout(local_size_x=1) in;
const float PI = 3.14159265358979323846;
struct GIHitData {
    uvec4 material;
    uvec2 vertex_address;
    uvec2 index_address;
    uvec4 geometry;
    uvec2 normal_address;
    uvec2 padding;
};
layout(set=0,binding=4,std430) readonly buffer Hits { GIHitData data[]; } hits;
layout(set=0,binding=60,std430) writeonly buffer Results { vec4 shading; vec4 geometry; } result;
layout(push_constant,std430) uniform Push { mat4 transform; } params;
"""
	source.source_compute += FileAccess.get_file_as_string("res://../../../servers/rendering/renderer_rd/shaders/effects/amd_gi_geometry_inc.glsl")
	source.source_compute += """
void main() {
    vec3 a,b,c;
    gi_triangle_vertices(0u,0u,a,b,c);
    vec3 geometric = cross(c-a,b-a);
    vec3 shading = gi_triangle_normal(0u,0u,vec2(0.25),geometric);
    mat3 normal_transform = transpose(inverse(mat3(params.transform)));
    result.shading = vec4(normalize(normal_transform * shading),1);
    result.geometry = vec4(normalize(normal_transform * geometric),1);
}
"""
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		get_tree().quit(1)
		return
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var result := rd.storage_buffer_create(32)
	var hit_buffer := rd.storage_buffer_create(64)
	var uniforms: Array[RDUniform] = []
	for item in [[4, hit_buffer], [60, result]]:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = item[0]
		uniform.add_id(item[1])
		uniforms.append(uniform)
	var uniform_set := rd.uniform_set_create(uniforms, shader, 0)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.UP, Vector3.RIGHT])
	var normals := PackedVector3Array([Vector3(0.4, 0.2, 1).normalized(), Vector3(-0.2, 0.4, 1).normalized(), Vector3(0.1, -0.3, 1).normalized()])
	arrays[Mesh.ARRAY_NORMAL] = normals
	var tangents := PackedFloat32Array()
	for normal in normals:
		var tangent := normal.cross(Vector3.UP).normalized()
		tangents.append_array(PackedFloat32Array([tangent.x, tangent.y, tangent.z, 1]))
	var positions: PackedByteArray = arrays[Mesh.ARRAY_VERTEX].to_byte_array()
	var positions_buffer := rd.vertex_buffer_create(positions.size(), positions, RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT)
	# This local-RD fixture explicitly completes immutable BDA uploads. The
	# production renderer uses RD compute read dependencies, with no readback.
	assert(rd.buffer_get_data(positions_buffer) == positions)
	var cases := 0
	var max_error := 0.0
	for encoding in ["normal_only", "normal_tangent", "compressed"]:
		arrays[Mesh.ARRAY_TANGENT] = null if encoding == "normal_only" else tangents
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES if encoding == "compressed" else 0)
		var surface := RenderingServer.mesh_get_surface(mesh.get_rid(), 0)
		var packed: PackedByteArray = surface["vertex_data"]
		var packed_buffer := rd.vertex_buffer_create(packed.size(), packed, RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT)
		assert(rd.buffer_get_data(packed_buffer) == packed)
		var format: int = surface["format"]
		for index_stride in [0, 2, 4]:
			var index_bytes := PackedByteArray()
			index_bytes.resize(max(4, index_stride * 3))
			for vertex in 3:
				if index_stride == 2:
					index_bytes.encode_u16(vertex * 2, vertex)
				elif index_stride == 4:
					index_bytes.encode_u32(vertex * 4, vertex)
			var indices := rd.vertex_buffer_create(index_bytes.size(), index_bytes, RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT)
			assert(rd.buffer_get_data(indices) == index_bytes)
			var hit := PackedByteArray()
			hit.resize(64)
			hit.encode_u64(16, rd.buffer_get_device_address(positions_buffer))
			hit.encode_u64(24, rd.buffer_get_device_address(indices))
			hit.encode_u32(32, index_stride)
			hit.encode_u32(36, 8 if encoding == "compressed" else 0)
			hit.encode_u32(40, RenderingServer.mesh_surface_get_format_vertex_stride(format, 3) * 3 / 4)
			hit.encode_u32(44, RenderingServer.mesh_surface_get_format_normal_tangent_stride(format, 3) / 4)
			hit.encode_u64(48, rd.buffer_get_device_address(packed_buffer))
			rd.buffer_update(hit_buffer, 0, hit.size(), hit)
			for scale in [Vector3.ONE, Vector3(2, 3, 4), Vector3(-2, 3, 4), Vector3(2, -3, 4)]:
				var basis := Basis(Vector3.FORWARD, PI / 2) * Basis.from_scale(scale)
				var transform := PackedFloat32Array([basis.x.x, basis.x.y, basis.x.z, 0, basis.y.x, basis.y.y, basis.y.z, 0, basis.z.x, basis.z.y, basis.z.z, 0, 2, 3, 4, 1]).to_byte_array()
				var list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(list, pipeline)
				rd.compute_list_bind_uniform_set(list, uniform_set, 0)
				rd.compute_list_set_push_constant(list, transform, transform.size())
				rd.compute_list_dispatch(list, 1, 1, 1)
				rd.compute_list_end()
				rd.submit()
				rd.sync()
				var values := rd.buffer_get_data(result).to_float32_array()
				var normal_transform := basis.inverse().transposed()
				var expected := (normal_transform * (normals[0] * 0.5 + normals[1] * 0.25 + normals[2] * 0.25)).normalized()
				var expected_geometry := (normal_transform * Vector3.BACK).normalized()
				var actual := Vector3(values[0], values[1], values[2])
				var actual_geometry := Vector3(values[4], values[5], values[6])
				var error := maxf(actual.distance_to(expected), actual_geometry.distance_to(expected_geometry))
				max_error = maxf(max_error, error)
				if not is_finite(error) or error > 0.001:
					push_error("Source normal mismatch: %s indices=%d scale=%s actual=%s expected=%s geometry=%s expected_geometry=%s" % [encoding, index_stride, scale, actual, expected, actual_geometry, expected_geometry])
					get_tree().quit(1)
					return
				cases += 1
			rd.free_rid(indices)
		rd.free_rid(packed_buffer)
	for rid in [uniform_set, pipeline, shader, result, hit_buffer, positions_buffer]:
		rd.free_rid(rid)
	rd.free()
	print("AMD GI source normals: %d GPU cases passed, maximum vector error %.8f" % [cases, max_error])
	get_tree().quit()
