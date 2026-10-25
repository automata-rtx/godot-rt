extends SceneTree

# Queries must remain valid across writes, and allocator reuse must not retain
# another buffer's address. Read back uploads explicitly: this fixture tests
# address lifetime, not the production graph's indirect-address dependencies.
const SOURCE = """#version 450
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference_uvec2 : require
layout(local_size_x=1) in;
layout(buffer_reference,std430,buffer_reference_align=4) readonly buffer Input { uint words[]; };
layout(set=0,binding=0,std430) writeonly buffer Output { uint words[]; } result;
layout(push_constant,std430) uniform Params { uvec2 a; uvec2 b; uint last; } params;
void main() {
 Input a=Input(params.a), b=Input(params.b);
 result.words[0]=a.words[0]; result.words[1]=a.words[params.last];
 result.words[2]=b.words[0]; result.words[3]=b.words[params.last];
}
"""


func _initialize():
	call_deferred("run_test")


func run_test():
	var rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Buffer address lifetime: no local RenderingDevice")
		quit(1)
		return
	var source = RDShaderSource.new()
	source.source_compute = SOURCE
	var spirv = rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		rd.free()
		quit(1)
		return
	var shader = rd.shader_create_from_spirv(spirv)
	var pipeline = rd.compute_pipeline_create(shader)
	var output = rd.storage_buffer_create(16)
	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0
	uniform.add_id(output)
	var bindings = rd.uniform_set_create([uniform], shader, 0)
	var failures = 0
	for iteration in 64:
		var size = 16 + (iteration % 7) * 16
		var data = PackedByteArray()
		data.resize(size)
		var a = rd.vertex_buffer_create(size, data, RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT)
		var b = rd.storage_buffer_create(size, data, 0, RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT)
		var address_a = rd.buffer_get_device_address(a)
		var address_b = rd.buffer_get_device_address(b)
		if address_a == 0 or address_b == 0:
			failures += 1
		else:
			for update in 2:
				var expected = PackedInt32Array([iteration * 4 + update + 1, 101 + iteration, 1001 + update, 3001 + iteration])
				for item in [[a, 0, address_a], [b, 2, address_b]]:
					data.encode_u32(0, expected[item[1]])
					data.encode_u32(size - 4, expected[item[1] + 1])
					rd.buffer_update(item[0], 0, size, data)
					if rd.buffer_get_data(item[0]) != data or rd.buffer_get_device_address(item[0]) != item[2]:
						failures += 1
				var push = PackedByteArray()
				push.resize(20)
				push.encode_u64(0, address_a)
				push.encode_u64(8, address_b)
				push.encode_u32(16, size / 4 - 1)
				var list = rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(list, pipeline)
				rd.compute_list_bind_uniform_set(list, bindings, 0)
				rd.compute_list_set_push_constant(list, push, push.size())
				rd.compute_list_dispatch(list, 1, 1, 1)
				rd.compute_list_end()
				rd.submit()
				rd.sync()
				if rd.buffer_get_data(output).to_int32_array() != expected:
					failures += 1
		rd.free_rid(a)
		rd.free_rid(b)
	for rid in [bindings, pipeline, output, shader]:
		rd.free_rid(rid)
	rd.free()
	print("Buffer address lifetime: 128 GPU cases, %d failures" % failures)
	quit(0 if failures == 0 else 1)
