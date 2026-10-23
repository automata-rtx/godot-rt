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

// gi1.comp:UpdateTiles temporal accumulation, shared by direct and indirect.
// Both inputs and the output are radiance sums with sample counts, not means.
vec4 gi_cache_accumulate(vec4 radiance, vec4 update, float maximum_count) {
	float count = min(radiance.w + update.w, maximum_count);
	radiance /= max(radiance.w, 1.0);
	update /= max(update.w, 1.0);
	if (radiance.w <= 0.0) {
		radiance = update;
	} else {
		radiance = mix(radiance, update, 1.0 / count);
	}
	return radiance * count;
}

// hash_grid_cache.hlsl::QuantizeRadiance and Pack/UnpackRadiance.
// The hit-list traversal adds these integers, preserving the reference
// commutative uint accumulation (including its finite range).
uvec3 gi_cache_quantize(vec3 value) {
	return uvec3(round(value * 1000.0));
}
uvec2 gi_cache_pack(vec4 value) {
	return uvec2(packHalf2x16(value.xy), packHalf2x16(value.zw));
}
vec4 gi_cache_unpack(uvec2 value) {
	return vec4(unpackHalf2x16(value.x), unpackHalf2x16(value.y));
}
uint gi_cache_xxhash(uint value) {
	uint result = value + 374761393u;
	result = 668265263u * ((result << 17u) | (result >> 15u));
	result = 2246822519u * (result ^ (result >> 15u));
	result = 3266489917u * (result ^ (result >> 13u));
	return result ^ (result >> 16u);
}
