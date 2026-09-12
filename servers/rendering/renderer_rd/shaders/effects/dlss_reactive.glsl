#[compute]

#version 450

#VERSION_DEFINES

// Builds the reactive mask DLSS is tagged with, as a texture of its OWN.
//
// The renderer already has this information: the colour buffer's alpha channel
// holds accumulated transparent coverage, because `pass_alpha_multiplier` zeroes
// alpha across the opaque pass whenever the motion pass runs and the transparent
// pass then blends into it. FSR2 is simply handed an alpha-swizzled VIEW of that
// buffer and needs nothing else.
//
// DLSS cannot take the view. `texture_from_rid` resolves a view to its underlying
// VkImage, so tagging the view would hand Streamline the same image handle as the
// colour input, and with frame based resource tagging the two collide -- DLSS then
// samples the swizzled view AS its colour and every opaque pixel, whose alpha is
// zero, comes out black. That was tried on hardware. Hence this copy into a
// distinct single channel image, which is the whole reason this pass exists.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(r8, set = 0, binding = 1) uniform restrict writeonly image2D dest_reactive;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	// Scales coverage into the mask's range. Separate from the coverage itself so
	// the strength of the hint can be tuned without touching what it measures.
	float scale;
	float pad;
}
params;

void main() {
	const ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pos, params.size))) {
		return;
	}

	// Alpha, not luminance: this is coverage, and a fully covering black decal has
	// to read as reactive exactly like a bright one.
	const float coverage = texelFetch(source_color, pos, 0).a;
	imageStore(dest_reactive, pos, vec4(clamp(coverage * params.scale, 0.0, 1.0), 0.0, 0.0, 0.0));
}
