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

// Numerical oracle: arithmetic statements extracted from Capsaicin 914b9159
// gi1.comp ReprojectGI and FilterGI. Only GLSL type/intrinsic spelling changes.
// This is deliberately independent of the production helper.
float ref_saturate(float v) {
	return clamp(v, 0.0, 1.0);
}
float ref_luminance(vec3 color) {
	return dot(color, vec3(0.2126, 0.7152, 0.0722));
}
vec4 reference_accumulate(vec4 color, vec4 lighting, vec2 uv, bool is_sky_pixel, bool previous_uv_valid, inout float color_delta, out float blur_mask) {
	float alpha_blend = 1.0f;
	if (!is_sky_pixel && previous_uv_valid && color.w > 0.0f) {
		float lumaA = ref_luminance(color.xyz);
		float lumaB = ref_luminance(lighting.xyz / max(lighting.w, 1.0f));

		color_delta = mix(color_delta, lumaA - lumaB, 1.0f / 8.0f); // smoothed delta
		alpha_blend = ref_saturate(1.0f - abs(color_delta) / max(lumaB, 1e-4f));
	}
	blur_mask = (!is_sky_pixel ? max(8.0f - lighting.w, 0.0f) : -1.0f);

	if (color.w > 0.0f || lighting.w < 1.0f) // append new sample
	{
		lighting += vec4(color.xyz, color.w > 0.0f ? 1.0f : -1.0f);
	}

	vec2 vignette_uv = uv * (1.0f - uv.yx);
	float vignette = pow(15.0f * vignette_uv.x * vignette_uv.y, 0.25f);
	float max_sample_count = max(mix(4.0f, 8.0f * min(abs(lighting.w), 8.0f), alpha_blend) * vignette, 1.0f);

	if (lighting.w > max_sample_count) // evict old samples from the history
	{
		lighting *= (max_sample_count / lighting.w);
	}

	return lighting;
}
float reference_filter_weight(float count, float center_depth, float depth, vec3 center_normal, vec3 normal) {
	vec4 lighting = vec4(0, 0, 0, count);
	float depth_diff = 1.0f - (center_depth / depth);
	float depth_factor = exp2(-(lighting.w > 0.0f ? 2e2f : 2e1f) * abs(depth_diff));
	float normal_factor = max(dot(normal, center_normal), 0.0f);
	normal_factor *= normal_factor;
	normal_factor *= normal_factor;
	float w = depth_factor * (lighting.w > 0.0f ? normal_factor : 1.0f);
	return w;
}

// Independently extracted upstream bounded VNDF and matching PDF.
float reference_ndf(float roughnessAlphaSqr, float dotNH) {
	// Heaviside function for microfacet normal in the upper hemisphere.
	if (dotNH < 0.0f) {
		return 0.0f;
	}

	// Numerically stable form of Walter 2007 GGX NDF
	float eps = 1e-5f;
	float denom = (1.0f - dotNH * dotNH) / (roughnessAlphaSqr + eps) + dotNH * dotNH;
	return 1.0f / (3.14159265358979323846 * roughnessAlphaSqr * denom * denom);
}
vec3 reference_bounded(float roughnessAlpha, vec3 localView, vec2 samples) {
	// Bounded VNDF Sampling for Smith-GGX Reflections - Kenta transformed_eye and Yusuke Tokuyoshi 2023
	// https://doi.org/10.1145/3610543.3626163

	// Stretch the view vector as if roughness==1
	vec3 wiStd = normalize(vec3(roughnessAlpha * localView.xy, localView.z));

	float phi = 2.0f * 3.14159265358979323846 * samples.y;
	float a = roughnessAlpha;
	float s = 1.0f + sign(1.0f - a) * length(vec2(localView.x, localView.y));
	float a2 = a * a;
	float s2 = s * s;
	float k = (1.0f - a2) * s2 / (s2 + a2 * localView.z * localView.z);
	float b = localView.z > 0.0f ? k * wiStd.z : wiStd.z;

	float z = fma(-b, samples.x, 1.0f - samples.x);
	float sinTheta = sqrt(ref_saturate(1.0f - z * z));
	float x = sinTheta * cos(phi);
	float y = sinTheta * sin(phi);
	vec3 c = vec3(x, y, z);
	vec3 wmStd = c + wiStd;

	// Convert normal to un-stretched and normalize
	vec3 wm = normalize(vec3(roughnessAlpha * wmStd.xy, wmStd.z));
	return wm;
}
float reference_bounded_pdf(float roughnessAlpha, float roughnessAlphaSqr, float dotNH, vec3 localView) {
	// Kenta transformed_eye and Yusuke Tokuyoshi. 2023. Bounded VNDF Sampling for Smith-GGX Reflections.
	// https://doi.org/10.1145/3610543.3626163
	float ndf = reference_ndf(roughnessAlphaSqr, dotNH);
	vec2 ai = roughnessAlpha * localView.xy;
	float len2 = dot(ai, ai);
	float t = sqrt(len2 + localView.z * localView.z);
	if (localView.z >= 0.0f) {
		float a = roughnessAlpha;
		float s = 1.0f + sign(1.0f - a) * length(vec2(localView.x, localView.y));
		float a2 = a * a;
		float s2 = s * s;
		float k = (1.0f - a2) * s2 / (s2 + a2 * localView.z * localView.z);
		return ndf / (2.0f * (k * localView.z + t));
	}
	return ndf * (t - localView.z) / (2.0f * len2);
}

// gi1.comp:UpdateTiles, direct/indirect accumulation share this equation.
vec4 reference_cache_accumulate(vec4 direct_radiance, vec4 new_direct_radiance, float maximum_count) {
	float direct_sample_count = min(direct_radiance.w + new_direct_radiance.w, maximum_count);
	direct_radiance /= max(direct_radiance.w, 1.0f);
	new_direct_radiance /= max(new_direct_radiance.w, 1.0f);
	if (direct_radiance.w <= 0.0f) {
		direct_radiance = new_direct_radiance;
	} else {
		direct_radiance = mix(direct_radiance, new_direct_radiance, 1.0f / direct_sample_count);
	}
	direct_radiance *= direct_sample_count; // sample count is used as a hint for picking prefiltering amount

	return direct_radiance;
}

vec3 reference_rough_brdf(vec3 color, vec3 normal, vec3 view, vec3 light) {
	vec3 half_vector = normalize(view + light);
	float nl = clamp(dot(normal, light), -1.0, 1.0);
	float nv = clamp(dot(normal, view), -1.0, 1.0);
	float nh = clamp(dot(normal, half_vector), -1.0, 1.0);
	float hv = clamp(dot(half_vector, view), 0.0, 1.0);
	float fresnel = 0.04 + (1.0 - 0.04) * pow(1.0 - clamp(abs(hv), 0.0, 1.0), 5.0);
	float denominator = (1.0 - nh * nh) / (1.0 + 1e-5) + nh * nh;
	float ndf = nh < 0.0 ? 0.0 : 1.0 / (3.14159265358979323846 * denominator * denominator);
	float reciprocal_visibility = (abs(nl) + sqrt(1.0)) * (abs(nv) + sqrt(1.0));
	vec3 specular = vec3(fresnel * ndf) / reciprocal_visibility;
	vec3 diffuse = color / 3.14159265358979323846;
	diffuse *= (1.0 - fresnel) * 1.05 * (1.0 - pow(1.0 - clamp(abs(hv), 0.0, 1.0), 5.0));
	return (specular + diffuse) * clamp(nl, 0.0, 1.0);
}

// geometry/geometry.hlsl::offsetPosition, scalar expansion independent of the
// production vector-select implementation. Exercise both signs and near zero.
vec3 reference_offset_position(vec3 position, vec3 normal) {
	vec3 result;
	for (int axis = 0; axis < 3; ++axis) {
		int step = int(normal[axis] * 256.0);
		int bits = floatBitsToInt(position[axis]);
		bits += position[axis] < 0.0 ? -step : step;
		result[axis] = abs(position[axis]) < 1.0 / 32.0 ? position[axis] + normal[axis] / 65536.0 : intBitsToFloat(bits);
	}
	return result;
}
