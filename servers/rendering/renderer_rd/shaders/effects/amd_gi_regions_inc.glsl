// HybridPiP: screen feedback is selected in the logical camera's coordinates.
// World cache shading never inherits the crop projection of its dispatch owner.
#ifdef AMD_GI_REGIONAL_BATCH
bool batch_rect_contains(vec4 rect, vec2 uv) {
	vec2 local = (uv - rect.xy) / rect.zw;
	return all(greaterThan(local, vec2(0))) && all(lessThan(local, vec2(1)));
}
int batch_feedback_region(vec2 uv, bool previous) {
	int selected = -1;
	float density = 0.0;
	for (int region = 0; region < int(frame.batch_info.z); region++) {
		vec4 rect = previous ? frame.feedback_previous_rect[region] : frame.feedback_rect[region];
		if ((previous && frame.feedback_size[region].z == 0u) || !batch_rect_contains(rect, uv)) {
			continue;
		}
		vec2 rate = vec2(frame.feedback_size[region].xy) / rect.zw;
		float candidate = rate.x * rate.y;
		if (candidate > density) {
			density = candidate;
			selected = region;
		}
	}
	return selected;
}
vec3 batch_world(vec2 parent_uv) {
	int region = batch_feedback_region(parent_uv, false);
	if (region < 0) {
		// Preserve the normal screen-edge clamp in logical view coordinates.
		region = batch_feedback_region(clamp(parent_uv, vec2(1e-6), vec2(1.0 - 1e-6)), false);
	}
	vec2 uv = (parent_uv - frame.feedback_rect[region].xy) / frame.feedback_rect[region].zw;
	float depth = region == 0 ? textureLod(depth_buffer, uv, 0).r : textureLod(other_depth, uv, 0).r;
	vec4 position = frame.parent_inverse_view_projection * vec4(parent_uv * 2.0 - 1.0, depth, 1);
	return position.xyz / position.w;
}
vec3 batch_shading_normal(vec2 parent_uv) {
	parent_uv = clamp(parent_uv, vec2(1e-6), vec2(1.0 - 1e-6));
	int region = batch_feedback_region(parent_uv, false);
	vec2 uv = (parent_uv - frame.feedback_rect[region].xy) / frame.feedback_rect[region].zw;
	vec3 n = region == 0 ? textureLod(primary_shading_normal, uv, 0).xyz : textureLod(other_shading_normal, uv, 0).xyz;
	return normalize(n * 2.0 - 1.0);
}
vec3 batch_previous_lighting(vec2 parent_uv) {
	int region = batch_feedback_region(clamp(parent_uv, vec2(1e-6), vec2(1.0 - 1e-6)), true);
	if (region < 0 || frame.feedback_exposure[region] <= 0.0) {
		return vec3(0);
	}
	vec2 uv = (parent_uv - frame.feedback_previous_rect[region].xy) / frame.feedback_previous_rect[region].zw;
	vec3 value = region == 0 ? textureLod(previous_lighting, uv, 0).rgb : textureLod(other_previous_lighting, uv, 0).rgb;
	return value / frame.feedback_exposure[region];
}
bool batch_previous_hit_lighting(vec2 uv, RayHit hit, bool glossy, int previous_region, out vec3 outgoing) {
	outgoing = vec3(0);
	if (previous_region < 0 || previous_region >= int(frame.batch_info.z) || frame.feedback_size[previous_region].z == 0u || frame.feedback_exposure[previous_region] <= 0.0 || !batch_rect_contains(frame.feedback_previous_rect[previous_region], uv)) {
		return false;
	}
	vec4 previous_rect = frame.feedback_previous_rect[previous_region];
	ivec2 pixel = ivec2((uv - previous_rect.xy) / previous_rect.zw * vec2(frame.feedback_size[previous_region].xy));
	uint id = uint(pixel.x) + uint(pixel.y) * frame.feedback_size[previous_region].x;
	Pixel old = unpack_pixel(previous_region == 0 ? previous_pixels.data[id] : other_previous_pixels.data[id]);
	float expected_depth = dot(hit.position.xyz - frame.previous_parent_eye.xyz, frame.previous_parent_forward.xyz);
	float previous_depth = dot(old.position.xyz - frame.previous_parent_eye.xyz, frame.previous_parent_forward.xyz);
	vec3 previous_normal = (previous_region == 0 ? texelFetch(previous_geometry_normal, pixel, 0).xyz : texelFetch(other_previous_geometry, pixel, 0).xyz) * 2.0 - 1.0;
	if (old.position.w == 0.0 || expected_depth <= 0.0 || dot(normalize(previous_normal), hit.normal_mask.xyz) <= (glossy ? 0.95 : 0.5) || abs(previous_depth - expected_depth) / expected_depth >= (glossy ? 0.01 : 0.05)) {
		return false;
	}
	vec4 value = previous_region == 0 ? texelFetch(previous_lighting, pixel, 0) : texelFetch(other_previous_lighting, pixel, 0);
	outgoing = value.rgb / frame.feedback_exposure[previous_region];
	if (frame.reflections.w > 0.0) {
		atomicAdd(queues.counts.w, 1u);
	}
	return true;
}
bool batch_screen_lighting(RayHit hit, bool glossy, out vec3 outgoing) {
	outgoing = vec3(0);
	if (world_history_reset() || (!glossy && (params.bounces != 0u || frame.motion.z == 0u))) {
		return false;
	}
	vec4 clip = frame.parent_view_projection * vec4(hit.position.xyz, 1);
	vec2 current_uv = clip.xy / max(clip.w, 0.00001) * 0.5 + 0.5;
	int current_region = batch_feedback_region(current_uv, false);
	if (clip.w <= 0.0 || clip.z <= 0.0 || current_region < 0) {
		return false;
	}
	vec4 rect = frame.feedback_rect[current_region];
	ivec2 current_pixel = ivec2((current_uv - rect.xy) / rect.zw * vec2(frame.feedback_size[current_region].xy));
	float depth = current_region == 0 ? texelFetch(depth_buffer, current_pixel, 0).r : texelFetch(other_depth, current_pixel, 0).r;
	vec3 shading = (current_region == 0 ? texelFetch(primary_shading_normal, current_pixel, 0).xyz : texelFetch(other_shading_normal, current_pixel, 0).xyz) * 2.0 - 1.0;
	vec2 uv = current_uv;
	if (depth > 0.0 && dot(shading, shading) >= 0.01) {
		vec2 sample_uv = rect.xy + (vec2(current_pixel) + 0.5) / vec2(frame.feedback_size[current_region].xy) * rect.zw;
		vec4 visible_world = frame.parent_inverse_view_projection * vec4(sample_uv * 2.0 - 1.0, depth, 1);
		vec3 visible_position = visible_world.xyz / visible_world.w;
		vec4 previous_position = current_region == 0 ? texelFetch(previous_surface_position, current_pixel, 0) : texelFetch(other_previous_position, current_pixel, 0);
		float previous_valid = current_region == 0 ? texelFetch(geometry_normal_buffer, current_pixel, 0).a : texelFetch(other_geometry_normal, current_pixel, 0).a;
		vec4 previous_clip = frame.previous_parent_view_projection * vec4(previous_valid > 0.0 ? previous_position.xyz : visible_position, 1);
		if (previous_clip.w <= 0.0) {
			return false;
		}
		vec4 visible_clip = frame.parent_view_projection * vec4(visible_position, 1);
		uv += (previous_clip.xy / previous_clip.w - visible_clip.xy / visible_clip.w) * 0.5;
	}
	int previous_region = batch_feedback_region(uv, true);
	if (previous_region < 0 || frame.feedback_exposure[previous_region] <= 0.0) {
		return false;
	}
	if (batch_previous_hit_lighting(uv, hit, glossy, previous_region, outgoing)) {
		return true;
	}
	// A native crop can have valid frame history but reject this particular
	// surface. Try the overlapping lower-density history independently; never
	// blend unrelated surfaces or accept a failed depth/normal test.
	return frame.batch_info.z == 2u && batch_previous_hit_lighting(uv, hit, glossy, 1 - previous_region, outgoing);
}
#endif
