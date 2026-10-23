extends Node

# A closed native mesh must report outward-facing intersections from outside,
# inward-facing intersections from inside, including reflected instance bases.
func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	var arrays := BoxMesh.new().get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var expanded := PackedVector3Array()
	for index in indices:
		expanded.append(vertices[index])
	var bytes := expanded.to_byte_array()
	var vertex_buffer := rd.vertex_buffer_create(bytes.size(), bytes, RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT)
	var geometry := RDAccelerationStructureGeometry.new()
	geometry.vertex_buffer = vertex_buffer
	geometry.vertex_count = expanded.size()
	geometry.vertex_stride = 12
	geometry.vertex_format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	geometry.flags = RenderingDevice.ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT
	var blas := rd.blas_create([geometry], 0)
	rd.blas_build(blas)
	var tlas := rd.tlas_create(1, 0)
	var instance := RDAccelerationStructureInstance.new()
	instance.blas = blas
	instance.hit_sbt_range = 1 << 32
	var source := RDShaderSource.new()
	source.source_compute = """#version 460
#extension GL_EXT_ray_query : require
layout(local_size_x=12) in;
layout(set=0,binding=0) uniform accelerationStructureEXT scene;
layout(set=0,binding=1,std430) buffer Output { uint faces[]; };
void main() {
    uint id = gl_LocalInvocationID.x;
    vec3 axis = vec3(0);
    axis[(id % 6u) / 2u] = (id & 1u) != 0u ? 1.0 : -1.0;
    vec3 origin = id < 6u ? axis * 2.0 : vec3(0);
    vec3 direction = id < 6u ? -axis : axis;
    rayQueryEXT ray;
    rayQueryInitializeEXT(ray, scene, gl_RayFlagsOpaqueEXT, 255, origin, 0.0, direction, 10.0);
    while (rayQueryProceedEXT(ray)) {}
    faces[id] = rayQueryGetIntersectionTypeEXT(ray, true) == gl_RayQueryCommittedIntersectionNoneEXT ? 2u : uint(rayQueryGetIntersectionFrontFaceEXT(ray, true));
}
"""
	var spirv := rd.shader_compile_spirv_from_source(source)
	assert(spirv.compile_error_compute.is_empty(), spirv.compile_error_compute)
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var output := rd.storage_buffer_create(48)
	var as_uniform := RDUniform.new()
	as_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	as_uniform.binding = 0
	as_uniform.add_id(tlas)
	var out_uniform := RDUniform.new()
	out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	out_uniform.binding = 1
	out_uniform.add_id(output)
	var uniforms := rd.uniform_set_create([as_uniform, out_uniform], shader, 0)
	for flip in [false, true]:
		for mirrored in [false, true]:
			instance.flags = RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT
			if flip:
				instance.flags |= RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FLIP_FACING_BIT
			instance.transform = Transform3D(Basis.from_scale(Vector3(-1 if mirrored else 1, 1, 1)), Vector3.ZERO)
			rd.tlas_build(tlas, [instance])
			var list := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(list, pipeline)
			rd.compute_list_bind_uniform_set(list, uniforms, 0)
			rd.compute_list_dispatch(list, 1, 1, 1)
			rd.compute_list_end()
			rd.submit()
			rd.sync()
			var faces := rd.buffer_get_data(output).to_int32_array()
			for ray in 12:
				var expected := int((ray < 6) == flip)
				if faces[ray] != expected:
					push_error("Native mesh ray-query winding mismatch")
					get_tree().quit(1)
					return
			print("Native winding flip=%s mirrored=%s faces=%s" % [flip, mirrored, faces])
	for rid in [uniforms, pipeline, shader, output, tlas, blas, vertex_buffer]:
		rd.free_rid(rid)
	rd.free()
	print("AMD native winding: 48 ray queries passed")
	get_tree().quit()
