extends Node


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	var source := RDShaderSource.new()
	var production := FileAccess.get_file_as_string("res://../../../servers/rendering/renderer_rd/shaders/effects/amd_gi.glsl")
	var first := production.find("shared uvec4 bin_sum[64];")
	var last := production.find("// Exclusive scan", first)
	assert(first >= 0 and last > first)
	source.source_compute = """#version 450
layout(local_size_x=64) in;
layout(set=0,binding=0,std430) buffer Results { vec4 mean; uvec4 integers; } result;
layout(push_constant,std430) uniform Push { vec4 value; uvec4 counts; vec4 camera_position; } params;
struct TestLightGrid { uvec4 minimum; uvec4 maximum; }; TestLightGrid light_grid;
"""
	source.source_compute += FileAccess.get_file_as_string("res://../../../servers/rendering/renderer_rd/shaders/effects/amd_gi_cache_inc.glsl")
	source.source_compute += production.substr(first, last - first)
	var grid_source := FileAccess.get_file_as_string("res://../../../servers/rendering/renderer_rd/shaders/effects/amd_gi_lights_inc.glsl")
	var float_first := grid_source.find("uint ordered_float(")
	var float_last := grid_source.find("void reset_light_bounds(", float_first)
	var grid_first := grid_source.find("void light_grid_configuration(")
	var grid_last := grid_source.find("float gi_volume_weight(", grid_first)
	assert(float_first >= 0 and grid_first >= 0)
	source.source_compute += grid_source.substr(float_first, float_last - float_first)
	source.source_compute += grid_source.substr(grid_first, grid_last - grid_first)
	source.source_compute += """
void main() {
    uint lane = gl_LocalInvocationIndex;
    if (params.counts.y == 1u) {
        if (lane == 0u) {
            light_grid.minimum = uvec4(ordered_float(0.0));
            light_grid.maximum = uvec4(ordered_float(params.value.x), ordered_float(params.value.y), ordered_float(params.value.z), 0);
            vec3 minimum, size; uvec3 dimensions;
            light_grid_configuration(minimum, size, dimensions);
            uvec3 cell = light_grid_cell(vec3(100), minimum, size, dimensions, vec3(0.25));
            result.mean = vec4(size, 0);
            result.integers = uvec4(dimensions, cell.x | (cell.y << 8u) | (cell.z << 16u));
        }
        return;
    }
    clear_bins(lane);
    vec4 value = gi_cache_unpack(pack_probe_radiance(params.value));
    for (uint i = lane; i < params.counts.x; i += 64u) {
        insert_bin(0u, lane, value);
    }
    barrier();
    if (lane == 0u) {
        uint count;
        result.mean = sum_bin(0u, count) / float(count);
        result.integers = uvec4(bin_sum[0].w, bin_distance_high[0], count, 0);
    }
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
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0
	uniform.add_id(result)
	var uniform_set := rd.uniform_set_create([uniform], shader, 0)
	var cases := 0
	for distance in [1.0, 50.0, 65504.0, 1e9]:
		for count in [1, 6, 7, 64, 1024]:
			var push := PackedByteArray()
			push.resize(48)
			for component in 3:
				push.encode_float(component * 4, 1.0)
			push.encode_float(12, distance)
			push.encode_u32(16, count)
			var list := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(list, pipeline)
			rd.compute_list_bind_uniform_set(list, uniform_set, 0)
			rd.compute_list_set_push_constant(list, push, 48)
			rd.compute_list_dispatch(list, 1, 1, 1)
			rd.compute_list_end()
			rd.submit()
			rd.sync()
			var bytes := rd.buffer_get_data(result)
			var expected := minf(distance, 65504.0)
			var exact_sum: int = int(expected * 10000.0) * count
			if bytes.decode_u32(16) != (exact_sum & 0xffffffff) or bytes.decode_u32(20) != (exact_sum >> 32) or bytes.decode_u32(24) != count:
				push_error("Distance sum/carry mismatch: distance=%s count=%d" % [distance, count])
				get_tree().quit(1)
				return
			if not is_equal_approx(bytes.decode_float(12), expected) or bytes.decode_float(0) != 1.0:
				push_error("Distance mean or untouched RGB mismatch")
				get_tree().quit(1)
				return
			cases += 1
	var grid_cases := 0
	for extent in [Vector3.ZERO, Vector3(0, 2, 1), Vector3(4, 0, 0), Vector3(0.01, 2, 0), Vector3(1, 2, 3)]:
		var push := PackedByteArray()
		push.resize(48)
		for axis in 3:
			push.encode_float(axis * 4, extent[axis])
		push.encode_u32(20, 1)
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_set_push_constant(list, push, 48)
		rd.compute_list_dispatch(list, 1, 1, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var bytes := rd.buffer_get_data(result)
		var scale: float = max(extent.x, extent.y, extent.z) / 16.0
		var packed_cell := 0
		for axis in 3:
			var dimension: int = 1 if scale == 0 else max(ceil(extent[axis] / scale), 1)
			var expected: float = extent[axis] / dimension
			if bytes.decode_u32(16 + axis * 4) != dimension or not is_equal_approx(bytes.decode_float(axis * 4), expected):
				push_error("Flat-grid bounds changed: extent=%s axis=%d" % [extent, axis])
				get_tree().quit(1)
				return
			packed_cell |= (dimension - 1) << (axis * 8)
		if bytes.decode_u32(28) != packed_cell:
			push_error("Flat-grid lookup did not select the sole cell")
			get_tree().quit(1)
			return
		grid_cases += 1
	for rid in [uniform_set, pipeline, shader, result]:
		rd.free_rid(rid)
	rd.free()
	print("AMD GI distance: %d GPU cases passed, exact integer sums/carries and unchanged RGB" % cases)
	print("AMD GI flat grid: %d GPU cases passed, actual zero extents and sole-cell lookup" % grid_cases)
	get_tree().quit()
