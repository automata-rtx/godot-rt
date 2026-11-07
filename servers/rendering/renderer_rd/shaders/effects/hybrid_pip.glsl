#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#ifdef MODE_BACKGROUND_FXAA
layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D filtered_color;
layout(push_constant, std430) uniform FxaaParams {
	float luma_scale;
}
fxaa;

#include "fxaa_inc.glsl"

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(filtered_color);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	vec2 pixel_size = 1.0 / vec2(size);
	vec4 color = texelFetch(source_color, pixel, 0);
	if (fxaa.luma_scale > 0.0) {
		color.rgb = do_fxaa(color.rgb * fxaa.luma_scale, fxaa.luma_scale, (vec2(pixel) + 0.5) * pixel_size, pixel_size, 1.0) / fxaa.luma_scale;
	}
	imageStore(filtered_color, pixel, color);
}
#endif

#ifdef MODE_DOWNSAMPLE
layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D destination_color;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(destination_color);
	if (any(greaterThanEqual(pixel, size))) {
		return;
	}
	// A bilinear sample averages the corresponding 2x2 footprint. Normalized
	// coordinates also cover the last row/column of odd-sized source levels.
	imageStore(destination_color, pixel, textureLod(source_color, (vec2(pixel) + 0.5) / vec2(size), 0.0));
}
#endif

#ifdef MODE_COMPOSE
layout(set = 0, binding = 0) uniform sampler2D background_color;
layout(set = 0, binding = 1) uniform sampler2D background_depth;
layout(set = 0, binding = 2) uniform sampler2D native_color;
layout(set = 0, binding = 3) uniform sampler2D native_depth;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D composed_color;
layout(r32f, set = 0, binding = 5) uniform restrict writeonly image2D composed_depth;

layout(set = 0, binding = 6, std140) uniform LensAperture {
	vec4 vertices[16];
}
lens;

layout(push_constant, std430) uniform Params {
	vec4 depth_unproject;
	ivec2 output_size;
	ivec2 background_color_size;
	ivec2 background_depth_size;
	ivec2 native_color_size;
	ivec2 native_depth_size;
	ivec2 crop_position;
	ivec2 crop_size;
	ivec2 protected_position;
	ivec2 protected_size;
	vec2 lens_center;
	float lens_radius;
	uint lens_vertex_count;
	ivec2 source_offset;
	uint preview_resolve;
	uint lens_only;
}
params;
#endif

#ifdef MODE_BLUR
layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(set = 0, binding = 1) uniform sampler2D source_depth;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D blurred_color;

// CPU mirrors these exact std140 arrays. Disk samples are initialized once per
// owner during preparation; only the vertex prefix changes as the scope moves.
layout(set = 0, binding = 3, std140) uniform Aperture {
	vec4 vertices[16];
	vec4 disk[16];
}
aperture;

layout(push_constant, std430) uniform Params {
	vec4 depth_unproject;
	ivec2 output_size;
	uint aperture_count;
	uint blur_enabled;
	vec4 blur_range;
	vec2 aperture_feather;
}
params;
#endif

#if defined(MODE_COMPOSE) || defined(MODE_BLUR)
float view_distance(float depth) {
	float denominator = params.depth_unproject.z * depth + params.depth_unproject.w;
	// Infinite far planes legitimately produce a zero denominator for the sky.
	return abs(denominator) > 1e-20 ? max(-(params.depth_unproject.x * depth + params.depth_unproject.y) / denominator, 0.0) : 1e20;
}
#endif

#ifdef MODE_COMPOSE
bool matching_surface(float a, float b) {
	if (a <= 0.0 || b <= 0.0) {
		return a <= 0.0 && b <= 0.0;
	}
	float za = view_distance(a);
	float zb = view_distance(b);
	return abs(za - zb) <= 0.02 * max(min(za, zb), 1e-5);
}

float region_depth(sampler2D source, ivec2 valid_size, vec2 uv) {
	return texelFetch(source, clamp(ivec2(floor(uv * vec2(valid_size))), ivec2(0), valid_size - 1), 0).r;
}

vec4 reconstruct(sampler2D color, sampler2D depth, ivec2 color_size, ivec2 depth_size, vec2 uv, float reference_depth) {
	vec2 sample_pixel = uv * vec2(color_size) - 0.5;
	ivec2 base = ivec2(floor(sample_pixel));
	vec2 fraction = fract(sample_pixel);
	vec4 sum = vec4(0.0);
	float total = 0.0;
	for (int tap = 0; tap < 4; tap++) {
		ivec2 offset = ivec2(tap & 1, tap >> 1);
		ivec2 pixel = clamp(base + offset, ivec2(0), color_size - 1);
		vec2 weights = mix(vec2(1.0) - fraction, fraction, vec2(offset));
		float weight = weights.x * weights.y;
		vec2 depth_uv = (vec2(pixel) + 0.5) / vec2(color_size);
		if (weight > 0.0 && matching_surface(reference_depth, region_depth(depth, depth_size, depth_uv))) {
			sum += texelFetch(color, pixel, 0) * weight;
			total += weight;
		}
	}
	// If color is coarser than depth, a narrow surface can have no compatible tap.
	// Nearest available color is preferable to importing another surface's average.
	return total > 1e-6 ? sum / total : texelFetch(color, clamp(ivec2(floor(uv * vec2(color_size))), ivec2(0), color_size - 1), 0);
}

vec4 scope_color(ivec2 crop_pixel, vec2 crop_uv) {
	if (params.native_color_size == params.crop_size) {
		return texelFetch(native_color, crop_pixel, 0);
	}
	vec2 extent = vec2(params.native_color_size);
	vec2 coord = clamp(crop_uv * extent, vec2(0.5), extent - 0.5);
	return textureLod(native_color, coord / vec2(textureSize(native_color, 0)), 0.0);
}

// The glass is circular. The projected opening of the housing occludes it
// along the octagon flats. Only its one-pixel coverage edge needs a blend.
float lens_coverage(vec2 pixel) {
	float distance_inside = params.lens_radius - distance(pixel, params.lens_center);
	if (distance_inside <= -0.5) {
		return 0.0;
	}
	vec2 previous = lens.vertices[params.lens_vertex_count - 1u].xy * vec2(params.output_size);
	for (uint i = 0u; i < params.lens_vertex_count; ++i) {
		vec2 current = lens.vertices[i].xy * vec2(params.output_size);
		vec2 edge = current - previous;
		vec2 normal = vec2(-edge.y, edge.x) / max(length(edge), 1e-6);
		if (dot(params.lens_center - previous, normal) < 0.0) {
			normal = -normal;
		}
		distance_inside = min(distance_inside, dot(pixel - previous, normal));
		previous = current;
	}
	return clamp(distance_inside + 0.5, 0.0, 1.0);
}

float native_weight(vec2 pixel) {
	vec2 crop_begin = vec2(params.crop_position);
	vec2 crop_end = crop_begin + vec2(params.crop_size);
	vec2 protected_begin = vec2(params.protected_position);
	vec2 protected_end = protected_begin + vec2(params.protected_size);
	float weight = 1.0;
	for (int axis = 0; axis < 2; axis++) {
		if (protected_begin[axis] > crop_begin[axis]) {
			weight = min(weight, smoothstep(crop_begin[axis], protected_begin[axis], pixel[axis]));
		}
		if (crop_end[axis] > protected_end[axis]) {
			weight = min(weight, 1.0 - smoothstep(protected_end[axis], crop_end[axis], pixel[axis]));
		}
	}
	return weight;
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.output_size))) {
		return;
	}
	// Editor capture witness. Show reconstructed texels in the upper-right
	// corner of this same frame, using the normal presentation tone mapping.
	if (params.preview_resolve != 0u) {
		ivec2 source = pos - ivec2(params.output_size.x - params.native_color_size.x, 0);
		if (all(greaterThanEqual(source, ivec2(0))) && all(lessThan(source, params.native_color_size))) {
			imageStore(composed_color, pos, texelFetch(native_color, source, 0));
			imageStore(composed_depth, pos, vec4(1.0));
			return;
		}
	}
	vec2 pixel = vec2(pos) + 0.5;
	ivec2 crop_pixel = pos - params.crop_position;
	bool in_crop = all(greaterThanEqual(crop_pixel, ivec2(0))) && all(lessThan(crop_pixel, params.crop_size));
	bool in_protected = all(greaterThanEqual(pos, params.protected_position)) && all(lessThan(pos, params.protected_position + params.protected_size));
	float glass = 0.0;
	ivec2 lens_texel = crop_pixel + params.source_offset;
	if (params.lens_only != 0u) {
		// Here the crop is the source field of view. The lens can extend
		// beyond that crop on the display while still having a 1:1 texel map.
		if (all(greaterThanEqual(lens_texel, ivec2(0))) && all(lessThan(lens_texel, params.native_color_size))) {
			glass = lens_coverage(pixel);
			if (glass >= 1.0) {
				vec2 uv = (vec2(lens_texel) + 0.5) / vec2(params.native_color_size);
				imageStore(composed_color, pos, texelFetch(native_color, lens_texel, 0));
				imageStore(composed_depth, pos, vec4(region_depth(native_depth, params.native_depth_size, uv), 0.0, 0.0, 0.0));
				return;
			}
		}
	} else if (in_protected) {
		// Native coverage is guaranteed by the layout; no background sampling is
		// needed for these pixels, and coarse color cannot contaminate the scope.
		vec2 crop_uv = (vec2(crop_pixel) + 0.5) / vec2(params.crop_size);
		float depth = region_depth(native_depth, params.native_depth_size, crop_uv);
		vec4 color = scope_color(crop_pixel, crop_uv);
		if (params.lens_vertex_count != 0u) {
			float coverage = lens_coverage(pixel);
			if (coverage > 0.0) {
				ivec2 source = clamp(crop_pixel + params.source_offset, ivec2(0), params.native_color_size - 1);
				vec2 uv = (vec2(source) + 0.5) / vec2(params.native_color_size);
				color = mix(color, texelFetch(native_color, source, 0), coverage);
				if (coverage >= 0.5) {
					depth = region_depth(native_depth, params.native_depth_size, uv);
				}
			}
		}
		imageStore(composed_color, pos, color);
		imageStore(composed_depth, pos, vec4(depth, 0.0, 0.0, 0.0));
		return;
	}
	vec2 background_uv = pixel / vec2(params.output_size);
	float depth = region_depth(background_depth, params.background_depth_size, background_uv);
	vec4 color = reconstruct(background_color, background_depth, params.background_color_size, params.background_depth_size, background_uv, depth);
	if (glass > 0.0) {
		color = mix(color, texelFetch(native_color, lens_texel, 0), glass);
		if (glass >= 0.5) {
			vec2 uv = (vec2(lens_texel) + 0.5) / vec2(params.native_color_size);
			depth = region_depth(native_depth, params.native_depth_size, uv);
		}
	} else if (params.lens_only == 0u && in_crop) {
		vec2 crop_uv = (vec2(crop_pixel) + 0.5) / vec2(params.crop_size);
		float precise_depth = region_depth(native_depth, params.native_depth_size, crop_uv);
		vec4 precise_color = scope_color(crop_pixel, crop_uv);
		// The crop is authoritative at a silhouette. Never blur its foreground
		// with a background/coarse sample just to hide the rectangle boundary.
		float weight = matching_surface(depth, precise_depth) ? native_weight(pixel) : 1.0;
		color = mix(color, precise_color, weight);
		depth = precise_depth;
	}
	imageStore(composed_color, pos, color);
	imageStore(composed_depth, pos, vec4(depth, 0.0, 0.0, 0.0));
}
#endif

#ifdef MODE_BLUR
float aperture_distance(vec2 pixel) {
	bool inside = false;
	float nearest_squared = 1e30;
	uint previous = params.aperture_count - 1u;
	for (uint vertex = 0u; vertex < params.aperture_count; vertex++) {
		vec2 a = aperture.vertices[previous].xy * vec2(params.output_size);
		vec2 b = aperture.vertices[vertex].xy * vec2(params.output_size);
		vec2 edge = b - a;
		float edge_squared = dot(edge, edge);
		float parameter = edge_squared > 0.0 ? clamp(dot(pixel - a, edge) / edge_squared, 0.0, 1.0) : 0.0;
		vec2 delta = pixel - (a + parameter * edge);
		nearest_squared = min(nearest_squared, dot(delta, delta));
		if ((a.y > pixel.y) != (b.y > pixel.y)) {
			float crossing = a.x + (pixel.y - a.y) * edge.x / edge.y;
			if (pixel.x < crossing) {
				inside = !inside;
			}
		}
		previous = vertex;
	}
	return (inside ? -1.0 : 1.0) * sqrt(nearest_squared);
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.output_size))) {
		return;
	}
	vec4 center = texelFetch(source_color, pos, 0);
	if (params.blur_enabled == 0u) {
		imageStore(blurred_color, pos, center);
		return;
	}
	vec2 pixel = vec2(pos) + 0.5;
	float outside = smoothstep(params.aperture_feather.x, params.aperture_feather.y, aperture_distance(pixel));
	float distance = view_distance(texelFetch(source_depth, pos, 0).r);
	float radius = mix(params.blur_range.x, params.blur_range.y, smoothstep(params.blur_range.z, params.blur_range.w, distance)) * outside;
	if (radius <= 0.25) {
		imageStore(blurred_color, pos, center);
		return;
	}
	// Broad kernels sample a prefiltered image; small kernels retain native
	// samples. Continuous LOD avoids visible depth bands. Compensate for the
	// box pyramid's added variance so the accepted radius curve stays intact.
	float lod = clamp(log2(max(radius / 3.0, 1.0)), 0.0, float(textureQueryLevels(source_color) - 1));
	float base_lod = floor(lod);
	float pyramid_variance = (mix(exp2(2.0 * base_lod), exp2(2.0 * (base_lod + 1.0)), fract(lod)) - 1.0) / 12.0;
	// Per-axis variance of the normalized exp(-2*r*r) unit disk.
	const float DISK_VARIANCE = 0.17174118;
	float sample_radius = sqrt(max(radius * radius - pyramid_variance / DISK_VARIANCE, 0.0));
	// Retain the old center's relative weight (0.5 for 96 samples).
	vec4 sum = center * (1.0 / 12.0);
	float total = 1.0 / 12.0;
	vec2 allocation_size = vec2(textureSize(source_color, 0));
	for (uint tap = 0u; tap < 16u; tap++) {
		vec3 sample_data = aperture.disk[tap].xyz;
		vec2 sample_pixel = clamp(pixel + sample_data.xy * sample_radius, vec2(0.5), vec2(params.output_size) - 0.5);
		// Presentation blur deliberately softens object silhouettes too, matching
		// the accepted depth-radius preview. Depth controls this pixel's footprint;
		// it is not a bilateral rejection that would leave those edges sharp.
		sum += textureLod(source_color, sample_pixel / allocation_size, lod) * sample_data.z;
		total += sample_data.z;
	}
	imageStore(blurred_color, pos, sum / total);
}
#endif
