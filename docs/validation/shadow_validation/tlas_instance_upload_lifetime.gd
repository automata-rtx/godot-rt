extends SceneTree

# Queue several builds of one TLAS, interleaved with ray queries, before submit.
# Distinct transforms/IDs reveal host upload ranges overwritten by later builds.
const SOURCE := """#version 460
#extension GL_EXT_ray_query : require
layout(local_size_x=1) in;
layout(set=0,binding=0) uniform accelerationStructureEXT scene;
layout(set=0,binding=1,std430) writeonly buffer Output { uint ids[]; } result;
layout(push_constant,std430) uniform Params { float origin_x; uint slot; } params;
void main() {
 rayQueryEXT ray;
 rayQueryInitializeEXT(ray,scene,gl_RayFlagsOpaqueEXT,255,vec3(params.origin_x,0,2),0.0,vec3(0,0,-1),4.0);
 while(rayQueryProceedEXT(ray)) {}
 result.ids[params.slot]=rayQueryGetIntersectionTypeEXT(ray,true)==gl_RayQueryCommittedIntersectionNoneEXT
  ? 0xffffffffu : rayQueryGetIntersectionInstanceCustomIndexEXT(ray,true);
}
"""


func _initialize():
	call_deferred("run_test")


func run_test():
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("TLAS upload lifetime requires a local Vulkan RenderingDevice")
		quit(1)
		return
	var vertices := PackedVector3Array([Vector3(-0.5, -0.5, 0), Vector3(0.5, -0.5, 0), Vector3(0, 0.5, 0)]).to_byte_array()
	var vertex_buffer := rd.vertex_buffer_create(vertices.size(), vertices, RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT)
	var geometry := RDAccelerationStructureGeometry.new()
	geometry.vertex_buffer = vertex_buffer
	geometry.vertex_count = 3
	geometry.vertex_stride = 12
	geometry.vertex_format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	geometry.flags = RenderingDevice.ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT
	var blas := rd.blas_create([geometry], 0)
	var tlas := rd.tlas_create(2, 0)
	if not blas.is_valid() or not tlas.is_valid() or rd.blas_build(blas) != OK:
		push_error("TLAS upload lifetime acceleration structure creation failed")
		rd.free()
		quit(1)
		return
	var source := RDShaderSource.new()
	source.source_compute = SOURCE
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		rd.free()
		quit(1)
		return
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var output := rd.storage_buffer_create(12)
	var as_uniform := RDUniform.new()
	as_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	as_uniform.binding = 0
	as_uniform.add_id(tlas)
	var out_uniform := RDUniform.new()
	out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	out_uniform.binding = 1
	out_uniform.add_id(output)
	var bindings := rd.uniform_set_create([as_uniform, out_uniform], shader, 0)
	var failures := 0
	# Exercises initial allocation, capacity exhaustion, and later-frame reuse.
	for frame in 8:
		var expected := PackedInt32Array()
		for build in 3:
			var instance := RDAccelerationStructureInstance.new()
			instance.blas = blas
			instance.hit_sbt_range = 1 << 32
			instance.id = 100 + frame * 3 + build
			instance.flags = RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT
			var origin_x := float(build * 4)
			instance.transform = Transform3D(Basis.IDENTITY, Vector3(origin_x, 0, 0))
			var instances: Array[RDAccelerationStructureInstance] = [instance]
			if build == 2:
				var extra := RDAccelerationStructureInstance.new()
				extra.blas = blas
				extra.hit_sbt_range = 1 << 32
				extra.id = 999
				extra.transform = Transform3D(Basis.IDENTITY, Vector3(40, 0, 0))
				instances.append(extra)
			if rd.tlas_build(tlas, instances) != OK:
				push_error("TLAS upload lifetime build failed")
				rd.free()
				quit(1)
				return
			expected.append(instance.id)
			var push := PackedByteArray()
			push.resize(8)
			push.encode_float(0, origin_x)
			push.encode_u32(4, build)
			var list := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(list, pipeline)
			rd.compute_list_bind_uniform_set(list, bindings, 0)
			rd.compute_list_set_push_constant(list, push, push.size())
			rd.compute_list_dispatch(list, 1, 1, 1)
			rd.compute_list_end()
		# Intentionally no submit/sync/readback inside the build loop.
		rd.submit()
		rd.sync()
		var actual := rd.buffer_get_data(output).to_int32_array()
		if actual != expected:
			failures += 1
			push_error("TLAS upload lifetime frame %d expected %s, got %s" % [frame, expected, actual])
	for rid in [bindings, pipeline, shader, output, tlas, blas, vertex_buffer]:
		rd.free_rid(rid)
	rd.free()
	print("TLAS upload lifetime: 24 queued ray queries, %d failures" % failures)
	quit(0 if failures == 0 else 1)
