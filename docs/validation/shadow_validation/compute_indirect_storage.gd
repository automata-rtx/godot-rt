extends SceneTree

# A descriptor-bound storage buffer also supplies indirect dispatch arguments.
# The graph must retain both shader and indirect-command access at each boundary.
const ITERATIONS = 256
const SOURCE = """#version 450
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
layout(set=0,binding=0,std430) buffer Arguments { uint data[]; } args;
layout(set=0,binding=1,std430) buffer Results { uint data[]; } results;
layout(push_constant,std430) uniform Params { uint iteration; uint producer; uint pad0; uint pad1; } params;
void main() {
 if (params.producer != 0u) {
  // Keep writes late enough to expose a missing indirect-read dependency.
  uint value=params.iteration;
  for (uint j=0u;j<4096u;j++) value=value*1664525u+1013904223u;
  args.data[0]=params.iteration%63u+1u;
  args.data[1]=1u;
  args.data[2]=1u;
  args.data[3]=value;
 } else {
  uint id=gl_GlobalInvocationID.x;
  if (id<64u) results.data[params.iteration*64u+id]=args.data[3];
 }
}
"""


func _initialize():
	call_deferred("run_test")


func run_test():
	var rd = RenderingServer.create_local_rendering_device()
	var source = RDShaderSource.new()
	source.source_compute = SOURCE
	var spirv = rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		quit(1)
		return
	var shader = rd.shader_create_from_spirv(spirv)
	var initial = PackedInt32Array([0, 1, 1, 0]).to_byte_array()
	var arguments = rd.storage_buffer_create(16, initial, RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	var zeros = PackedByteArray()
	zeros.resize(ITERATIONS * 64 * 4)
	var results = rd.storage_buffer_create(zeros.size(), zeros)
	var uniforms: Array[RDUniform] = []
	for buffer in [arguments, results]:
		var uniform = RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = uniforms.size()
		uniform.add_id(buffer)
		uniforms.append(uniform)
	var uniform_set = rd.uniform_set_create(uniforms, shader, 0)
	var pipeline = rd.compute_pipeline_create(shader)
	var list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	for iteration in ITERATIONS:
		var push = PackedInt32Array([iteration, 1, 0, 0]).to_byte_array()
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch(list, 1, 1, 1)
		rd.compute_list_add_barrier(list)
		push.encode_u32(4, 0)
		rd.compute_list_set_push_constant(list, push, push.size())
		rd.compute_list_dispatch_indirect(list, arguments, 0)
		rd.compute_list_add_barrier(list)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var actual = rd.buffer_get_data(results)
	var failures = 0
	for iteration in ITERATIONS:
		var value = iteration
		for j in 4096:
			value = (value * 1664525 + 1013904223) & 0xffffffff
		for lane in 64:
			var expected = value if lane < iteration % 63 + 1 else 0
			if actual.decode_u32((iteration * 64 + lane) * 4) != expected:
				failures += 1
	for rid in [pipeline, uniform_set, arguments, results, shader]:
		rd.free_rid(rid)
	rd.free()
	print("Indirect/storage dependency: %d dispatches, %d failures" % [ITERATIONS, failures])
	quit(0 if failures == 0 else 1)
