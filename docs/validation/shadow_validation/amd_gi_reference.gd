extends Node

# Compare compiled production equations with the upstream-source oracle on GPU.
# The fixtures exercise history growth/eviction, fallback hints, lighting changes,
# screen edges, sky, relative-depth rejection and normal discontinuities.
const CASES := 4096


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Reference comparison requires Vulkan")
		get_tree().quit(1)
		return
	var helper := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/shaders/effects/amd_gi_denoiser_inc.glsl"))
	helper += FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/shaders/effects/amd_gi_sampling_inc.glsl"))
	helper += FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://../../../servers/rendering/renderer_rd/shaders/effects/amd_gi_cache_inc.glsl"))
	var oracle := FileAccess.get_file_as_string("res://amd_gi_reference_oracle.glsl")
	var source := RDShaderSource.new()
	source.source_compute = "#version 450\nlayout(local_size_x=64) in;\n" + helper + oracle + """
layout(set=0,binding=0,std430) buffer Output { vec4 errors[]; };
void main() {
    uint id = gl_GlobalInvocationID.x;
    float count = float(id % 80u);
    vec3 average = vec3(float((id * 17u) % 101u), float((id * 31u) % 103u), float((id * 47u) % 107u)) / 16.0;
    vec4 history = vec4(average * count, count);
    vec4 color = vec4(average * (float((id / 80u) % 4u) + 0.5), (id & 1u) == 0u ? 1.0 : 0.0);
    vec2 uv = vec2(float(id % 17u) + 0.5, float((id / 17u) % 19u) + 0.5) / vec2(17, 19);
    bool sky = (id % 7u) == 0u, previous_valid = (id % 11u) != 0u;
    float delta_a = float(int(id % 13u) - 6) / 10.0, delta_b = delta_a;
    float blur_a, blur_b;
    vec4 actual = gi_denoiser_accumulate(color, history, uv, sky, previous_valid, delta_a, blur_a);
    vec4 expected = reference_accumulate(color, history, uv, sky, previous_valid, delta_b, blur_b);
    vec4 difference = abs(actual - expected) / max(abs(expected), vec4(1.0));
    float depth = 0.5 + float(id % 97u), other_depth = depth * (0.9 + float(id % 31u) / 100.0);
    vec3 normal = vec3(0, 0, 1), other_normal = normalize(vec3(float(id % 19u) / 10.0, 0, 1));
    float wa = gi_denoiser_filter_weight(count, depth, other_depth, normal, other_normal);
    float wb = reference_filter_weight(count, depth, other_depth, normal, other_normal);
    errors[id * 6u] = vec4(max(max(difference.x, difference.y), max(difference.z, difference.w)), abs(delta_a-delta_b), abs(blur_a-blur_b), abs(wa-wb));
    float alpha = max(pow(float(id % 67u) / 66.0, 2.0), 1e-6);
    vec3 view = normalize(vec3(float(id % 29u) / 28.0, 0.3, (id & 1u) == 0u ? 0.8 : -0.8));
    vec2 samples = vec2(float(id % 101u) + 0.5, float(id % 103u) + 0.5) / vec2(101, 103);
    vec3 na = gi_sample_ggx_bounded(alpha, view, samples);
    vec3 nb = reference_bounded(alpha, view, samples);
    float nh = clamp(na.z, -1.0, 1.0);
    float pa = gi_ggx_bounded_pdf(alpha, max(alpha*alpha, 1e-6), nh, view);
    float pb = reference_bounded_pdf(alpha, max(alpha*alpha, 1e-6), nh, view);
    errors[id * 6u + 1u] = vec4(abs(na-nb), abs(pa-pb) / max(abs(pb), 1.0));
    float update_count = float(id % 23u);
    vec4 cache_history = vec4(average * count, count);
    vec4 cache_update = vec4(average.yzx * update_count, update_count);
    vec4 ca = gi_cache_accumulate(cache_history, cache_update, 16.0);
    vec4 cb = reference_cache_accumulate(cache_history, cache_update, 16.0);
    errors[id * 6u + 2u] = abs(ca - cb) / max(abs(cb), vec4(1.0));
    vec3 light = normalize(vec3(samples * 2.0 - 1.0, 0.3));
    vec3 ba = gi_rough_brdf(average, normal, view, light);
    vec3 bb = reference_rough_brdf(average, normal, view, light);
    errors[id * 6u + 3u] = vec4(abs(ba-bb), 0);
    vec3 origin = vec3(float(int(id % 73u) - 36), float(int(id % 89u) - 44), float(int(id % 97u) - 48)) * exp2(float(int(id % 32u) - 16));
    vec3 offset_normal = normalize(vec3(samples * 2.0 - 1.0, 0.3));
    errors[id * 6u + 4u] = vec4(abs(gi_offset_position(origin, offset_normal) - reference_offset_position(origin, offset_normal)), 0);
    float solid_angle = 12.566370614359172 / (8.0 * ((id & 1u) == 0u ? 1.5 : 12000.0));
    float mip_levels = float(1u + id % 13u);
    float expected_lod = log2(solid_angle * (1.0 / 12.566370614359172)) + mip_levels;
    errors[id * 6u + 5u] = vec4(abs(gi_environment_lod(solid_angle, mip_levels) - expected_lod), 0, 0, 0);
}
"""
	var spirv := rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error(spirv.compile_error_compute)
		get_tree().quit(1)
		return
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var buffer := rd.storage_buffer_create(CASES * 96)
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0
	uniform.add_id(buffer)
	var uniforms := rd.uniform_set_create([uniform], shader, 0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_dispatch(list, CASES / 64, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var values := rd.buffer_get_data(buffer).to_float32_array()
	var worst := 0.0
	var failures := 0
	for value in values:
		if not is_finite(value) or value > 0.00001:
			failures += 1
		worst = maxf(worst, value)
	for handle in [uniforms, buffer, pipeline, shader]:
		rd.free_rid(handle)
	rd.free()
	print("AMD reference equations: %d cases, max error %.9f, %d failures" % [CASES, worst, failures])
	get_tree().quit(1 if failures else 0)
