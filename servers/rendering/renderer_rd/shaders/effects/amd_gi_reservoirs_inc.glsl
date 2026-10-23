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

// Capsaicin 914b915: world_space_restir.hlsl and CompactReservoirs.
// Keep the reference's 262144 buckets, 16 collision slots, and a variable number
// of hit reservoirs per entry. These arrays share two Vulkan descriptors, not
// the radiance cache. Offsets are in uint words; the CPU allocation mirrors them.
const uint RESERVOIR_ENTRIES = 0x400000u;
const uint RESERVOIR_BLOCKS = RESERVOIR_ENTRIES / 256u;
const uint RESERVOIR_TOP_BLOCKS = RESERVOIR_BLOCKS / 256u;
uint reservoir_capacity() {
	return primary_ray_count() * (params.bounces != 0u ? 2u : 1u);
}
uint reservoir_normals_offset() {
	return 3u * RESERVOIR_ENTRIES + 4u * reservoir_capacity();
}
uint reservoir_entries_offset() {
	return 3u * RESERVOIR_ENTRIES + 5u * reservoir_capacity();
}
uint reservoir_slots_offset() {
	return 3u * RESERVOIR_ENTRIES + 6u * reservoir_capacity();
}
uint reservoir_values_offset() {
	return 3u * RESERVOIR_ENTRIES + 7u * reservoir_capacity();
}
uint reservoir_scan_offset() {
	return 3u * RESERVOIR_ENTRIES + 8u * reservoir_capacity();
}
uint pack_reservoir_normal(vec3 value) {
	uvec3 packed = uvec3(ivec3(clamp(value, -1.0, 1.0) * 511.0 + 0.5 * sign(value))) & 0x3ffu;
	return packed.x | (packed.y << 10u) | (packed.z << 20u);
}
vec3 unpack_reservoir_normal(uint packed) {
	return vec3(ivec3(packed << 22u, packed << 12u, packed << 2u) >> 22) / 511.0;
}
uint reservoir_xxhash(uint value) {
	uint result = value + 374761393u;
	result = 668265263u * ((result << 17u) | (result >> 15u));
	result = 2246822519u * (result ^ (result >> 15u));
	result = 3266489917u * (result ^ (result >> 13u));
	return result ^ (result >> 16u);
}
float reservoir_cell_size(vec3 position, vec3 eye) {
	float step = distance(eye, position) * tan(frame.settings.y * 16.0);
	uint level = uint(log2(1e3 * step));
	return 1e-3 * exp2(float(level));
}
uvec2 reservoir_index_hash(vec3 position, vec3 eye) {
	float step = distance(eye, position) * tan(frame.settings.y * 16.0);
	uint level = uint(log2(1e3 * step));
	float cell_size = 1e-3 * exp2(float(level));
	uvec3 cell = uvec3(ivec3(floor(position / cell_size)));
	uint index = pcg(level + pcg(cell.x + pcg(cell.y + pcg(cell.z))));
	uint hash = reservoir_xxhash(level + reservoir_xxhash(cell.x + reservoir_xxhash(cell.y + reservoir_xxhash(cell.z))));
	return uvec2(index % 0x40000u, max(hash, 1u));
}
vec3 reservoir_jitter(vec3 position, vec3 normal, inout uint state) {
	// GetOrthoVectors: preserve the reference frame used for the square jitter.
	bool select_z = abs(normal.z) > 0.0;
	vec3 p = select_z ? normal : normal.zyx;
	float k = inversesqrt(p.z * p.z + normal.y * normal.y);
	vec3 b1 = vec3(0.0, -p.z * k, normal.y * k);
	b1 = select_z ? b1 : b1.zyx;
	vec3 b2 = cross(normal, b1);
	vec2 jitter = 2.0 * vec2(random_float(state), random_float(state)) - 1.0;
	jitter *= reservoir_cell_size(position, params.camera_position.xyz) * sqrt(2.0);
	return position + jitter.x * b1 + jitter.y * b2;
}
void reservoir_reset(uint id) {
	if (id < RESERVOIR_ENTRIES) {
		light_reservoirs.data[id] = 0u;
		light_reservoirs.data[RESERVOIR_ENTRIES + id] = 0u;
		if (frame.grid.w != 0u) {
			previous_light_reservoirs.data[id] = 0u;
		}
	}
	if (id < reservoir_capacity()) {
		light_reservoirs.data[3u * RESERVOIR_ENTRIES + 4u * id + 3u] = 0u;
		light_reservoirs.data[reservoir_entries_offset() + id] = INVALID;
	}
}
void reservoir_insert(uint id, vec3 position) {
	uvec2 key = reservoir_index_hash(position, params.camera_position.xyz);
	for (uint i = 0u; i < 16u; i++) {
		uint entry = key.x * 16u + i;
		uint old = atomicCompSwap(light_reservoirs.data[entry], 0u, key.y);
		if (old != 0u && old != key.y) {
			continue;
		}
		uint slot = atomicAdd(light_reservoirs.data[RESERVOIR_ENTRIES + entry], 1u);
		light_reservoirs.data[reservoir_entries_offset() + id] = entry;
		light_reservoirs.data[reservoir_slots_offset() + id] = slot;
		return;
	}
}
uint reservoir_find_previous(vec3 position) {
	uvec2 key = reservoir_index_hash(position, frame.previous_eye.xyz);
	for (uint i = 0u; i < 16u; i++) {
		uint entry = key.x * 16u + i;
		uint hash = previous_light_reservoirs.data[entry];
		if (hash == 0u) {
			return INVALID;
		}
		if (hash == key.y) {
			return entry;
		}
	}
	return INVALID;
}
uvec4 reservoir_load_previous(uint id) {
	uint base = 3u * RESERVOIR_ENTRIES + 4u * id;
	return uvec4(previous_light_reservoirs.data[base], previous_light_reservoirs.data[base + 1u], previous_light_reservoirs.data[base + 2u], previous_light_reservoirs.data[base + 3u]);
}
void reservoir_store(uint id, uvec4 packed, vec3 normal) {
	uint base = 3u * RESERVOIR_ENTRIES + 4u * id;
	for (uint i = 0u; i < 4u; i++) {
		light_reservoirs.data[base + i] = packed[i];
	}
	light_reservoirs.data[reservoir_normals_offset() + id] = pack_reservoir_normal(normal);
}
uint reservoir_previous_prefix(uint entry) {
	uint block = entry / 256u;
	uint scan = reservoir_scan_offset();
	return previous_light_reservoirs.data[2u * RESERVOIR_ENTRIES + entry] + previous_light_reservoirs.data[scan + RESERVOIR_BLOCKS + block] + previous_light_reservoirs.data[scan + 2u * RESERVOIR_BLOCKS + RESERVOIR_TOP_BLOCKS + block / 256u];
}

// Three-level exclusive integer scan, equivalent to gfxCommandScanSum. Keep
// dispatch barriers between levels and compaction; no floating-point atomics.
void reservoir_scan(uint group, uint lane, uint level) {
	uint scan = reservoir_scan_offset();
	uint count = level == 0u ? RESERVOIR_ENTRIES : (level == 1u ? RESERVOIR_BLOCKS : RESERVOIR_TOP_BLOCKS);
	uint source = level == 0u ? RESERVOIR_ENTRIES : (level == 1u ? scan : scan + 2u * RESERVOIR_BLOCKS);
	uint target = level == 0u ? 2u * RESERVOIR_ENTRIES : (level == 1u ? scan + RESERVOIR_BLOCKS : scan + 2u * RESERVOIR_BLOCKS + RESERVOIR_TOP_BLOCKS);
	for (uint i = lane; i < 256u; i += 64u) {
		uint id = group * 256u + i;
		prefix_scan[i] = id < count ? light_reservoirs.data[source + id] : 0u;
	}
	barrier();
	for (uint offset = 1u; offset < 256u; offset *= 2u) {
		uvec4 sums;
		for (uint j = 0u; j < 4u; j++) {
			uint i = lane + j * 64u;
			sums[j] = prefix_scan[i] + (i >= offset ? prefix_scan[i - offset] : 0u);
		}
		barrier();
		for (uint j = 0u; j < 4u; j++) {
			prefix_scan[lane + j * 64u] = sums[j];
		}
		barrier();
	}
	for (uint i = lane; i < 256u; i += 64u) {
		uint id = group * 256u + i;
		if (id < count) {
			light_reservoirs.data[target + id] = i == 0u ? 0u : prefix_scan[i - 1u];
		}
	}
	if (lane == 0u && level < 2u) {
		light_reservoirs.data[scan + (level == 0u ? 0u : 2u * RESERVOIR_BLOCKS) + group] = prefix_scan[255];
	}
}
void reservoir_compact(uint id) {
	if (id >= reservoir_capacity()) {
		return;
	}
	uint entry = light_reservoirs.data[reservoir_entries_offset() + id];
	if (entry == INVALID) {
		return;
	}
	uint block = entry / 256u;
	uint scan = reservoir_scan_offset();
	uint prefix = light_reservoirs.data[2u * RESERVOIR_ENTRIES + entry] + light_reservoirs.data[scan + RESERVOIR_BLOCKS + block] + light_reservoirs.data[scan + 2u * RESERVOIR_BLOCKS + RESERVOIR_TOP_BLOCKS + block / 256u];
	uint slot = light_reservoirs.data[reservoir_slots_offset() + id];
	light_reservoirs.data[reservoir_values_offset() + prefix + slot] = id;
}
