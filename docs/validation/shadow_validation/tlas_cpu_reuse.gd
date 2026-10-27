extends SceneTree

# Real ray queries cover cached submission, BLAS lifetime, and several builds
# before submit. The native byte oracle additionally checks SBT/flag packing.
const SOURCE := """#version 460
#extension GL_EXT_ray_query : require
layout(local_size_x=1) in;
layout(set=0,binding=0) uniform accelerationStructureEXT scene;
layout(set=0,binding=1,std430) writeonly buffer Output { uint ids[]; } result;
layout(push_constant,std430) uniform Params { float origin_x; uint slot; uint mask; } params;
void main() {
 rayQueryEXT ray;
 rayQueryInitializeEXT(ray,scene,gl_RayFlagsOpaqueEXT,params.mask,vec3(params.origin_x,0,2),0.0,vec3(0,0,-1),4.0);
 while(rayQueryProceedEXT(ray)) {}
 result.ids[params.slot]=rayQueryGetIntersectionTypeEXT(ray,true)==gl_RayQueryCommittedIntersectionNoneEXT
  ? 0xffffffffu : rayQueryGetIntersectionInstanceCustomIndexEXT(ray,true);
}
"""

var rd: RenderingDevice
var tlas: RID
var output: RID
var pipeline: RID
var bindings: RID
var pending_expected := PackedInt32Array()
var pending_labels: Array[String] = []
var query_count := 0
var failures := 0


func _initialize() -> void:
	call_deferred("run_test")


func triangle_bytes(offset: float) -> PackedByteArray:
	return PackedVector3Array([Vector3(-0.5 + offset, -0.5, 0), Vector3(0.5 + offset, -0.5, 0), Vector3(offset, 0.5, 0)]).to_byte_array()


func make_blas(vertex_buffer: RID) -> RID:
	assert(rd.buffer_get_device_address(vertex_buffer) != 0, "BLAS input must have a device address")
	var geometry := RDAccelerationStructureGeometry.new()
	geometry.vertex_buffer = vertex_buffer
	geometry.vertex_count = 3
	geometry.vertex_stride = 12
	geometry.vertex_format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	geometry.flags = RenderingDevice.ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT
	var result := rd.blas_create([geometry], 0)
	assert(result.is_valid())
	var build_error := rd.blas_build(result)
	assert(build_error == OK)
	return result


func instance(blas: RID, id: int, x: float) -> RDAccelerationStructureInstance:
	var result := RDAccelerationStructureInstance.new()
	result.blas = blas
	result.hit_sbt_range = 1 << 32
	result.id = id
	result.flags = RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT
	result.transform = Transform3D(Basis.IDENTITY, Vector3(x, 0, 0))
	return result


func queue_query(label: String, instances: Array[RDAccelerationStructureInstance], origin_x: float, expected: int, ray_mask: int = 255) -> void:
	var build_error := rd.tlas_build(tlas, instances)
	assert(build_error == OK, label)
	var push := PackedByteArray()
	push.resize(12)
	push.encode_float(0, origin_x)
	push.encode_u32(4, pending_expected.size())
	push.encode_u32(8, ray_mask)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, bindings, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()
	pending_expected.append(expected)
	pending_labels.append(label)


func finish_batch(frame: int) -> void:
	rd.submit()
	rd.sync()
	var actual := rd.buffer_get_data(output).to_int32_array()
	for index in pending_expected.size():
		if actual[index] != pending_expected[index]:
			failures += 1
			push_error("TLAS CPU reuse frame %d %s: expected %d, got %d" % [frame, pending_labels[index], pending_expected[index], actual[index]])
	query_count += pending_expected.size()
	pending_expected.clear()
	pending_labels.clear()


func run_test() -> void:
	rd = RenderingServer.create_local_rendering_device()
	assert(rd != null, "TLAS CPU reuse requires a local Vulkan RenderingDevice")
	var bytes := triangle_bytes(0)
	var usage := RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT | RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT
	var vertex_buffer := rd.vertex_buffer_create(bytes.size(), bytes, usage)
	var second_buffer := rd.vertex_buffer_create(bytes.size(), bytes, usage)
	var blas := make_blas(vertex_buffer)
	var second_blas := make_blas(second_buffer)
	tlas = rd.tlas_create(4, 0)
	assert(tlas.is_valid())
	var source := RDShaderSource.new()
	source.source_compute = SOURCE
	var spirv := rd.shader_compile_spirv_from_source(source)
	assert(spirv.compile_error_compute.is_empty(), spirv.compile_error_compute)
	var shader := rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	output = rd.storage_buffer_create(256)
	var as_uniform := RDUniform.new()
	as_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	as_uniform.binding = 0
	as_uniform.add_id(tlas)
	var out_uniform := RDUniform.new()
	out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	out_uniform.binding = 1
	out_uniform.add_id(output)
	bindings = rd.uniform_set_create([as_uniform, out_uniform], shader, 0)
	assert(bindings.is_valid())
	for frame in 8:
		var a := instance(blas, 100 + frame * 10, 0)
		var b := instance(second_blas, 200 + frame * 10, 4)
		var inactive := RDAccelerationStructureInstance.new()
		queue_query("initial", [a, b], 0, a.id)
		queue_query("unchanged", [a, b], 4, b.id)
		a.id += 1
		queue_query("custom ID", [a, b], 0, a.id)
		a.transform.origin.x = 2
		queue_query("transform", [a, b], 2, a.id)
		a.mask = 0
		queue_query("mask zero", [a, b], 2, -1)
		a.mask = 1
		queue_query("mask rejection", [a, b], 2, -1, 2)
		queue_query("mask admission", [a, b], 2, a.id, 1)
		a.flags |= RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FLIP_FACING_BIT
		a.hit_sbt_range = (1 << 32) | 37
		queue_query("flags and SBT offset", [a, b], 2, a.id)
		queue_query("inactive slot", [inactive, b], 2, -1)
		queue_query("restored active slot", [a, b], 2, a.id)
		queue_query("reordered BLAS topology", [b, a], 2, a.id)
		queue_query("count zero", [], 2, -1)
		queue_query("one instance after empty", [a], 2, a.id)
		queue_query("shared BLAS and count growth", [a, instance(blas, 300, 8), b], 8, 300)
		# Same RID, new contents and bounds: rebuilding the BLAS must invalidate
		# retained references and reattach both directions before TLAS reuse.
		bytes = triangle_bytes(1)
		var update_error := rd.buffer_update(vertex_buffer, 0, bytes.size(), bytes)
		assert(update_error == OK)
		var build_error := rd.blas_build(blas)
		assert(build_error == OK)
		queue_query("same RID BLAS rebuild", [a, b], 3, a.id)
		queue_query("rebuilt BLAS retained again", [a, b], 3, a.id)
		queue_query("old geometry no longer present", [a, b], 2, -1)
		finish_batch(frame)
		# Source-buffer free implicitly frees the BLAS. Replace both after the
		# submitted queries complete, then reuse this same TLAS next frame.
		rd.free_rid(vertex_buffer)
		bytes = triangle_bytes(0)
		vertex_buffer = rd.vertex_buffer_create(bytes.size(), bytes, usage)
		var previous_blas := blas
		blas = make_blas(vertex_buffer)
		assert(blas != previous_blas)
	# Flush the final replacement BLAS before destroying the local device.
	rd.submit()
	rd.sync()
	for rid in [bindings, pipeline, shader, output, tlas, blas, second_blas, vertex_buffer, second_buffer]:
		rd.free_rid(rid)
	rd.free()
	print("RT TLAS CPU reuse: %d queued ray queries, %d failures" % [query_count, failures])
	quit(0 if failures == 0 else 1)
