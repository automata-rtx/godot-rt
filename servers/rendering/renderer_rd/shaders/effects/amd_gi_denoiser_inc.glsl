/**********************************************************************
Copyright (c) 2025 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/

// Direct equation translation from Capsaicin 914b9159, gi1.comp:
// ReprojectGI / FilterGI, and gi_denoiser.hlsl:GIDenoiser_RemoveNaNs.
// History RGB stores a SUM, alpha stores its sample count.
vec4 gi_denoiser_remove_nans(vec4 color) {
	color /= 1.0 + color;
	color = clamp(color, vec4(0.0), vec4(1.0));
	color /= max(vec4(1.0) - color, vec4(1e-4));
	return color;
}

vec4 gi_denoiser_accumulate(vec4 color, vec4 lighting, vec2 uv, bool sky, bool previous_uv_valid, float response, inout float color_delta, out float blur_mask) {
	if ((frame.options.z & 1u) != 0u && !sky && color.w > 0.0 && lighting.w > 1.0) {
		// Consume the upstream confidence before adding this frame. Merely
		// clamping the count after accumulation would retain the same old mean.
		float limit = mix(64.0, 3.0, clamp(response, 0.0, 1.0));
		lighting *= min(1.0, limit / lighting.w);
	}
	float alpha_blend = 1.0;
	if (!sky && previous_uv_valid && color.w > 0.0) {
		float luma_a = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
		float luma_b = dot(lighting.rgb / max(lighting.w, 1.0), vec3(0.2126, 0.7152, 0.0722));
		color_delta = mix(color_delta, luma_a - luma_b, 1.0 / 8.0);
		alpha_blend = clamp(1.0 - abs(color_delta) / max(luma_b, 1e-4), 0.0, 1.0);
	}
	blur_mask = !sky ? max(8.0 - lighting.w, 0.0) : -1.0;
	if (color.w > 0.0 || lighting.w < 1.0) {
		lighting += vec4(color.rgb, color.w > 0.0 ? 1.0 : -1.0);
	}
	vec2 vignette_uv = uv * (vec2(1.0) - uv.yx);
	float vignette = pow(15.0 * vignette_uv.x * vignette_uv.y, 0.25);
	float max_samples = max(mix(4.0, 8.0 * min(abs(lighting.w), 8.0), alpha_blend) * vignette * frame.tuning.y, 1.0);
	if (lighting.w > max_samples) {
		lighting *= max_samples / lighting.w;
	}
	return lighting;
}

float gi_denoiser_filter_weight(float count, float center_depth, float depth, vec3 center_normal, vec3 normal) {
	float depth_difference = 1.0 - center_depth / depth;
	float depth_factor = exp2(-(count > 0.0 ? 200.0 : 20.0) * abs(depth_difference));
	float normal_factor = max(dot(normal, center_normal), 0.0);
	normal_factor *= normal_factor;
	normal_factor *= normal_factor;
	return depth_factor * (count > 0.0 ? normal_factor : 1.0);
}
