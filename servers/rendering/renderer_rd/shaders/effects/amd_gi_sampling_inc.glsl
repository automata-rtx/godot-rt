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

// Capsaicin 914b9159 materials/material_sampling.hlsl: bounded VNDF is the
// default, with its matching PDF. math/quaternion.hlsl supplies the local frame.
// lights/light_evaluation.hlsl::evaluateEnvironmentLightCone.
float gi_environment_lod(float solid_angle, float mip_levels) {
	return log2(solid_angle / (4.0 * 3.14159265358979323846)) + mip_levels;
}
vec4 gi_rotation_z(vec3 direction) {
	return direction.z >= -0.99999 ? normalize(vec4(direction.y, -direction.x, 0.0, 1.0 + direction.z)) : vec4(1, 0, 0, 0);
}
vec3 gi_rotate(vec4 q, vec3 direction) {
	return 2.0 * dot(q.xyz, direction) * q.xyz + (q.w * q.w - dot(q.xyz, q.xyz)) * direction + 2.0 * q.w * cross(q.xyz, direction);
}
vec3 gi_sample_ggx_bounded(float alpha, vec3 view, vec2 samples) {
	vec3 stretched = normalize(vec3(alpha * view.xy, view.z));
	float phi = 2.0 * 3.14159265358979323846 * samples.y;
	float s = 1.0 + sign(1.0 - alpha) * length(view.xy);
	float a2 = alpha * alpha;
	float s2 = s * s;
	float k = (1.0 - a2) * s2 / (s2 + a2 * view.z * view.z);
	float b = view.z > 0.0 ? k * stretched.z : stretched.z;
	float z = fma(-b, samples.x, 1.0 - samples.x);
	float sine = sqrt(clamp(1.0 - z * z, 0.0, 1.0));
	vec3 normal = vec3(sine * cos(phi), sine * sin(phi), z) + stretched;
	return normalize(vec3(alpha * normal.xy, normal.z));
}
float gi_ggx_ndf(float alpha_squared, float nh) {
	if (nh < 0.0) {
		return 0.0;
	}
	float denominator = (1.0 - nh * nh) / (alpha_squared + 1e-5) + nh * nh;
	return 1.0 / (3.14159265358979323846 * alpha_squared * denominator * denominator);
}
float gi_ggx_bounded_pdf(float alpha, float alpha_squared, float nh, vec3 view) {
	float ndf = gi_ggx_ndf(alpha_squared, nh);
	vec2 ai = alpha * view.xy;
	float length_squared = dot(ai, ai);
	float t = sqrt(length_squared + view.z * view.z);
	if (view.z >= 0.0) {
		float s = 1.0 + sign(1.0 - alpha) * length(view.xy);
		float a2 = alpha * alpha;
		float s2 = s * s;
		float k = (1.0 - a2) * s2 / (s2 + a2 * view.z * view.z);
		return ndf / (2.0 * (k * view.z + t));
	}
	return ndf * (t - view.z) / (2.0 * length_squared);
}

// material_evaluation.hlsl::evaluateBRDF, with the GI-1 secondary-bounce
// material override metallicity=0, roughness=1. Includes Fresnel compensation.
vec3 gi_rough_brdf(vec3 albedo, vec3 n, vec3 v, vec3 l) {
	float nl = clamp(dot(n, l), -1.0, 1.0), nv = clamp(dot(n, v), -1.0, 1.0);
	vec3 half_vector = v + l;
	if (dot(half_vector, half_vector) == 0.0 || nl <= 0.0) {
		return vec3(0);
	}
	vec3 h = normalize(half_vector);
	float hv = clamp(dot(h, v), 0.0, 1.0), nh = clamp(dot(n, h), -1.0, 1.0);
	float f = 0.04 + 0.96 * pow(1.0 - hv, 5.0);
	float denominator = (1.0 - nh * nh) / 1.00001 + nh * nh;
	float d = nh < 0.0 ? 0.0 : 1.0 / (3.14159265358979323846 * denominator * denominator);
	float visibility = (abs(nl) + 1.0) * (abs(nv) + 1.0);
	return (vec3(f * d / visibility) + albedo / 3.14159265358979323846 * ((1.0 - f) * 1.05 * (1.0 - pow(1.0 - hv, 5.0)))) * nl;
}

// geometry/geometry.hlsl::offsetPosition (Ray Tracing Gems, chapter 6).
vec3 gi_offset_position(vec3 position, vec3 normal) {
	ivec3 integer_normal = ivec3(normal * 256.0);
	ivec3 offset = mix(integer_normal, -integer_normal, lessThan(position, vec3(0)));
	vec3 integer_position = intBitsToFloat(floatBitsToInt(position) + offset);
	return mix(integer_position, position + normal / 65536.0, lessThan(abs(position), vec3(1.0 / 32.0)));
}
