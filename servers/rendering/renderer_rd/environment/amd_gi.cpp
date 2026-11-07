/**************************************************************************/
/*  amd_gi.cpp                                                            */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "amd_gi.h"

#include "core/config/engine.h"
#include "core/config/project_settings.h"
#include "core/io/dir_access.h"
#include "core/io/file_access.h"
#include "core/io/json.h"
#include "core/os/os.h"
#include "core/templates/hash_set.h"
#include "servers/rendering/renderer_rd/storage_rd/light_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/texture_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

#include <thirdparty/amd_gi/blue_noise.h>

#include <random>
#include <utility>

using namespace RendererRD;

// world_space_restir.hlsl: separate spatial hash, not directional radiance cells.
static constexpr uint32_t RESERVOIR_ENTRIES = 0x400000;
static constexpr uint32_t RESERVOIR_BLOCKS = RESERVOIR_ENTRIES / 256;
static constexpr uint32_t RESERVOIR_TOP_BLOCKS = RESERVOIR_BLOCKS / 256;
static uint32_t reservoir_buffer_bytes(uint32_t p_capacity) {
	return (3 * RESERVOIR_ENTRIES + 8 * p_capacity + 2 * RESERVOIR_BLOCKS + 2 * RESERVOIR_TOP_BLOCKS) * sizeof(uint32_t);
}

// Explicit diagnostic readback, never enabled by a graphics preset. Validate
// ownership and LRU permutation on the actual GPU results, not a CPU simulation.
static bool validate_probe_cache(RID p_queues, RID p_spawn, RID p_state, RID p_order, uint32_t p_probe_count, uint32_t p_update_count, uint32_t p_cached_count, uint32_t p_frame) {
	RD *rd = RD::get_singleton();
	Vector<uint8_t> queue_bytes = rd->buffer_get_data(p_queues);
	Vector<uint8_t> spawn_bytes = rd->buffer_get_data(p_spawn);
	Vector<uint8_t> state_bytes = rd->buffer_get_data(p_state);
	Vector<uint8_t> order_bytes = rd->buffer_get_data(p_order);
	ERR_FAIL_COND_V(queue_bytes.size() < int64_t(16 + (3 * p_probe_count + 2 * p_update_count) * 4), false);
	ERR_FAIL_COND_V(spawn_bytes.size() != int64_t(p_update_count * 16), false);
	ERR_FAIL_COND_V(state_bytes.size() != int64_t(p_cached_count * 16) || order_bytes.size() != int64_t(p_cached_count * 4), false);
	const uint32_t *queues = reinterpret_cast<const uint32_t *>(queue_bytes.ptr());
	const uint32_t *spawn = reinterpret_cast<const uint32_t *>(spawn_bytes.ptr());
	const uint32_t *state = reinterpret_cast<const uint32_t *>(state_bytes.ptr());
	const uint32_t *order = reinterpret_cast<const uint32_t *>(order_bytes.ptr());
	ERR_FAIL_COND_V(queues[0] > p_probe_count || queues[1] > p_update_count || queues[2] > p_update_count, false);
	HashSet<uint32_t> scheduled;
	for (uint32_t i = 0; i < p_update_count; i++) {
		uint32_t probe = spawn[4 * i];
		if (probe == UINT32_MAX) {
			continue;
		}
		ERR_FAIL_COND_V_MSG(probe >= p_probe_count || scheduled.has(probe), false, "AMD GI scheduled a duplicate or out-of-range probe.");
		scheduled.insert(probe);
	}
	HashSet<uint32_t> evicted;
	for (uint32_t i = 0; i < queues[2]; i++) {
		uint32_t slot = queues[4 + 3 * p_probe_count + p_update_count + i];
		ERR_FAIL_COND_V(slot >= p_update_count, false);
		uint32_t probe = spawn[4 * slot + 3];
		ERR_FAIL_COND_V_MSG(probe >= p_probe_count || evicted.has(probe), false, "AMD GI queued a duplicate or out-of-range eviction.");
		evicted.insert(probe);
	}
	HashSet<uint32_t> permutation;
	HashSet<uint32_t> allocated;
	uint32_t reused = 0;
	for (uint32_t i = 0; i < p_cached_count; i++) {
		ERR_FAIL_COND_V_MSG(order[i] >= p_cached_count || permutation.has(order[i]), false, "AMD GI LRU order is not a permutation.");
		permutation.insert(order[i]);
		ERR_FAIL_COND_V(state[4 * i + 1] > 1, false);
		reused += state[4 * i + 1];
		uint32_t owner = state[4 * i + 2];
		if (owner == UINT32_MAX) {
			ERR_FAIL_COND_V(state[4 * i + 1] != 1, false);
		} else if (owner & 0x80000000u) {
			uint32_t index = owner & 0x7fffffffu;
			ERR_FAIL_COND_V(index >= queues[2] || allocated.has(index) || state[4 * i + 1] != 0, false);
			allocated.insert(index);
		} else {
			const bool eviction = (owner & 0x40000000u) != 0;
			const uint32_t slot = owner & 0x3fffffffu;
			ERR_FAIL_COND_V(slot >= p_update_count || spawn[4 * slot] == UINT32_MAX || state[4 * i + 1] != uint32_t(!eviction), false);
			ERR_FAIL_COND_V(eviction && spawn[4 * slot + 3] >= p_probe_count, false);
		}
	}
	ERR_FAIL_COND_V(allocated.size() != MIN(queues[2], p_cached_count), false);
	print_line(vformat("AMD GI cache validation: frame=%d scheduled=%d budget=%d evicted=%d reused=%d", p_frame, scheduled.size(), p_update_count, allocated.size(), reused));
	return true;
}

bool AMDGI::is_enabled() {
	return GLOBAL_GET("rendering/global_illumination/amd_gi/enabled");
}

bool AMDGI::is_supported() {
	RD *rd = RD::get_singleton();
	// Include the optional debug image/counters and capture buffer in the
	// declared shader interface, even when their runtime branches are inactive.
	return rd->has_feature(RD::SUPPORTS_HALF_FLOAT) && rd->limit_get(RD::LIMIT_MAX_STORAGE_BUFFERS_PER_SHADER_STAGE) >= 38 && rd->limit_get(RD::LIMIT_MAX_STORAGE_BUFFERS_PER_UNIFORM_SET) >= 38 && rd->limit_get(RD::LIMIT_MAX_COMPUTE_SHARED_MEMORY_SIZE) >= 32768 && rd->limit_get(RD::LIMIT_MAX_STORAGE_IMAGES_PER_SHADER_STAGE) >= 12 && rd->limit_get(RD::LIMIT_MAX_STORAGE_IMAGES_PER_UNIFORM_SET) >= 12 && rd->limit_get(RD::LIMIT_MAX_FRAMEBUFFER_COLOR_ATTACHMENTS) >= 8;
}

bool AMDGI::is_regional_supported() {
	RD *rd = RD::get_singleton();
	return is_supported() && rd->limit_get(RD::LIMIT_MAX_STORAGE_BUFFERS_PER_SHADER_STAGE) >= 41 && rd->limit_get(RD::LIMIT_MAX_STORAGE_BUFFERS_PER_UNIFORM_SET) >= 41 && rd->limit_get(RD::LIMIT_MAX_TEXTURES_PER_SHADER_STAGE) >= 32 && rd->limit_get(RD::LIMIT_MAX_SAMPLERS_PER_SHADER_STAGE) >= 34 && rd->limit_get(RD::LIMIT_MAX_TEXTURES_PER_UNIFORM_SET) >= 32 && rd->limit_get(RD::LIMIT_MAX_SAMPLERS_PER_UNIFORM_SET) >= 32;
}

// Explicit GPU readback diagnostic: verify the complete hash prefix, unique
// hit ownership, slot compaction and packed reservoir bounds, not just weights.
static bool validate_light_reservoirs(RID p_buffer, uint32_t p_capacity, uint32_t p_lights) {
	Vector<uint8_t> bytes = RD::get_singleton()->buffer_get_data(p_buffer);
	ERR_FAIL_COND_V(bytes.size() != reservoir_buffer_bytes(p_capacity), false);
	const uint32_t *data = reinterpret_cast<const uint32_t *>(bytes.ptr());
	const uint32_t records = 3 * RESERVOIR_ENTRIES;
	const uint32_t entries = records + 5 * p_capacity;
	const uint32_t slots = records + 6 * p_capacity;
	const uint32_t values = records + 7 * p_capacity;
	const uint32_t scan = records + 8 * p_capacity;
	Vector<uint8_t> seen;
	seen.resize(p_capacity);
	seen.fill(0);
	uint32_t prefix = 0, reused = 0, occupied = 0, multiple = 0;
	for (uint32_t entry = 0; entry < RESERVOIR_ENTRIES; entry++) {
		uint32_t block = entry / 256;
		uint32_t gpu_prefix = data[2 * RESERVOIR_ENTRIES + entry] + data[scan + RESERVOIR_BLOCKS + block] + data[scan + 2 * RESERVOIR_BLOCKS + RESERVOIR_TOP_BLOCKS + block / 256];
		uint32_t count = data[RESERVOIR_ENTRIES + entry];
		ERR_FAIL_COND_V(gpu_prefix != prefix || count > p_capacity - prefix || (data[entry] == 0) != (count == 0), false);
		occupied += count > 0;
		multiple += count > 1;
		for (uint32_t slot = 0; slot < count; slot++) {
			uint32_t id = data[values + prefix + slot];
			ERR_FAIL_COND_V(id >= p_capacity || seen[id] || data[entries + id] != entry || data[slots + id] != slot, false);
			seen.write[id] = 1;
			const uint32_t *record = data + records + id * 4;
			float weight;
			memcpy(&weight, record + 2, sizeof(float));
			float confidence = Math::half_to_float(uint16_t(record[3]));
			ERR_FAIL_COND_V(record[0] >= p_lights || !Math::is_finite(weight) || weight < 0.0f || !Math::is_finite(confidence) || confidence < 1.0f || confidence > 81.0f, false);
			reused += confidence > 1.0f;
		}
		prefix += count;
	}
	for (uint32_t id = 0; id < p_capacity; id++) {
		ERR_FAIL_COND_V((data[entries + id] != UINT32_MAX) != (seen[id] != 0), false);
	}
	print_line(vformat("AMD GI reservoir validation: valid=%d reused=%d entries=%d multiple=%d", prefix, reused, occupied, multiple));
	return true;
}

static Vector<uint32_t> validation_active_cells(RID p_keys, uint32_t p_cells, uint32_t p_frame) {
	Vector<uint8_t> bytes = RD::get_singleton()->buffer_get_data(p_keys);
	const uint32_t tiles = p_cells / 85;
	ERR_FAIL_COND_V(bytes.size() != int64_t(48 + tiles * 64), Vector<uint32_t>());
	const uint32_t *data = reinterpret_cast<const uint32_t *>(bytes.ptr());
	const uint32_t count = data[3];
	ERR_FAIL_COND_V(count > tiles || data[0] != MIN(count, 256u) || data[1] != MAX((count + 255u) / 256u, 1u) || data[2] != 1, Vector<uint32_t>());
	HashSet<uint32_t> occupied;
	uint32_t occupied_count = data[8 + (p_frame & 1)];
	ERR_FAIL_COND_V(occupied_count > tiles, Vector<uint32_t>());
	for (uint32_t i = 0; i < occupied_count; i++) {
		uint32_t tile = data[12 + (tiles + i) * 8 + (p_frame & 1)];
		ERR_FAIL_COND_V(tile >= tiles || occupied.has(tile) || data[12 + tile * 8 + 4] == 0, Vector<uint32_t>());
		occupied.insert(tile);
	}
	for (uint32_t tile = 0; tile < tiles; tile++) {
		ERR_FAIL_COND_V((data[12 + tile * 8 + 4] != 0) != occupied.has(tile), Vector<uint32_t>());
	}
	HashSet<uint32_t> seen;
	Vector<uint32_t> cells;
	for (uint32_t i = 0; i < count; i++) {
		uint32_t tile = data[12 + (tiles + i) * 8 + 4];
		ERR_FAIL_COND_V(tile >= tiles || seen.has(tile) || data[12 + tile * 8 + 4] == 0 || data[12 + tile * 8 + 5] != p_frame, Vector<uint32_t>());
		seen.insert(tile);
		for (uint32_t local = 0; local < 64; local++) {
			cells.push_back(tile * 85 + local);
		}
	}
	return cells;
}

// Two vec4 fields and packed visibility in RayRecord. StoredReflection is 64 bytes with half direction, color and deviation.
static constexpr uint32_t AMD_GI_RAY_BYTES = 48;
static constexpr uint32_t AMD_GI_RAY_WORDS = AMD_GI_RAY_BYTES / sizeof(uint32_t);

static bool validate_multibounce(RID p_keys, uint32_t p_frame, RID p_owners, RID p_primary, RID p_secondary, uint32_t p_cells, uint32_t p_rays, bool p_all_hits, uint32_t p_active_rays = UINT32_MAX) {
	ERR_FAIL_COND_V(p_rays == 0 || (p_active_rays != UINT32_MAX && p_active_rays > p_rays), false);
	const uint32_t active_rays = MIN(p_active_rays, p_rays);
	RD *rd = RD::get_singleton();
	Vector<uint8_t> owner_bytes = rd->buffer_get_data(p_owners, 0, p_cells * 4);
	Vector<uint8_t> primary_bytes = rd->buffer_get_data(p_primary);
	Vector<uint8_t> secondary_bytes = rd->buffer_get_data(p_secondary);
	ERR_FAIL_COND_V(owner_bytes.size() != int64_t(p_cells * 4) || primary_bytes.size() != int64_t(p_rays * AMD_GI_RAY_BYTES) || secondary_bytes.size() != int64_t(p_rays * AMD_GI_RAY_BYTES), false);
	const uint32_t *owners = reinterpret_cast<const uint32_t *>(owner_bytes.ptr());
	const uint32_t *primary = reinterpret_cast<const uint32_t *>(primary_bytes.ptr());
	const uint32_t *secondary = reinterpret_cast<const uint32_t *>(secondary_bytes.ptr());
	uint32_t primary_count = 0, secondary_cells = 0, secondary_hits = 0;
	for (uint32_t cell : validation_active_cells(p_keys, p_cells, p_frame)) {
		uint32_t owner = owners[cell];
		if (owner == UINT32_MAX) {
			continue;
		}
		ERR_FAIL_COND_V(cell % 85 >= 64 || owner >= 2 * p_rays || owner % p_rays >= active_rays, false);
		const uint32_t *ray = owner < p_rays ? primary + owner * AMD_GI_RAY_WORDS : secondary + (owner - p_rays) * AMD_GI_RAY_WORDS;
		float distance;
		memcpy(&distance, ray + 3, sizeof(float));
		ERR_FAIL_COND_V(!Math::is_finite(distance) || distance < 0.0f || ray[7] != cell, false);
		primary_count += owner < p_rays;
		secondary_cells += owner >= p_rays;
	}
	if (p_all_hits) {
		primary_count = 0;
		for (uint32_t ray = 0; ray < active_rays; ray++) {
			primary_count += primary[ray * AMD_GI_RAY_WORDS + 7] != UINT32_MAX;
		}
	}
	for (uint32_t ray = 0; ray < active_rays; ray++) {
		float distance;
		memcpy(&distance, secondary + ray * AMD_GI_RAY_WORDS + 3, sizeof(float));
		ERR_FAIL_COND_V(!Math::is_finite(distance), false);
		if (distance < 0.0f) {
			continue;
		}
		uint32_t parent = primary[ray * AMD_GI_RAY_WORDS + 7];
		ERR_FAIL_COND_V(parent >= p_cells || (!p_all_hits && owners[parent] != ray), false);
		secondary_hits++;
	}
	ERR_FAIL_COND_V(secondary_hits > primary_count, false);
	print_line(vformat("AMD GI multibounce validation: primary=%d secondary_hits=%d secondary_cells=%d", primary_count, secondary_hits, secondary_cells));
	return true;
}

static bool diagnostic_source_enabled() {
	static const bool enabled = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_SOURCE").is_empty();
	return enabled;
}

// Explicit opt-in, bounded readback. No descriptor or sampling changes in normal variants.
struct ReflectionDiagnosticConfig {
	String directory;
	Rect2 roi = Rect2(704.0 / 1280.0, 419.0 / 720.0, 52.0 / 1280.0, 121.0 / 720.0);
	uint32_t first = 300;
	uint32_t count = 64;
	bool enabled = false;
};

static const ReflectionDiagnosticConfig &reflection_diagnostic_config() {
	static const ReflectionDiagnosticConfig config = [] {
		ReflectionDiagnosticConfig result;
		result.directory = OS::get_singleton()->get_environment("GODOT_AMD_GI_REFLECTION_DIAGNOSTICS");
		if (!result.directory.is_empty()) {
			result.enabled = DirAccess::dir_exists_absolute(result.directory) && !diagnostic_source_enabled();
			ERR_FAIL_COND_V_MSG(!result.enabled, result, "Reflection diagnostics require an existing output directory and cannot run with GODOT_AMD_GI_VALIDATE_SOURCE.");
			String first = OS::get_singleton()->get_environment("GODOT_AMD_GI_REFLECTION_DIAGNOSTICS_FIRST");
			String count = OS::get_singleton()->get_environment("GODOT_AMD_GI_REFLECTION_DIAGNOSTICS_COUNT");
			if (!first.is_empty()) {
				result.first = uint32_t(CLAMP(first.to_int(), int64_t(0), int64_t(1000000)));
			}
			if (!count.is_empty()) {
				result.count = uint32_t(CLAMP(count.to_int(), int64_t(1), int64_t(64)));
			}
			String roi = OS::get_singleton()->get_environment("GODOT_AMD_GI_REFLECTION_DIAGNOSTICS_ROI");
			if (!roi.is_empty()) {
				Vector<String> coordinates = roi.split(",");
				bool valid = coordinates.size() == 4;
				float values[4] = {};
				for (int i = 0; valid && i < 4; i++) {
					valid = coordinates[i].strip_edges().is_valid_float();
					values[i] = coordinates[i].to_float();
					valid = valid && Math::is_finite(values[i]) && values[i] >= 0.0f && values[i] <= 1.0f;
				}
				valid = valid && values[2] > values[0] && values[3] > values[1];
				if (!valid) {
					result.enabled = false;
					ERR_PRINT("Reflection diagnostic ROI must be normalized x0,y0,x1,y1 with positive area inside [0,1].");
					return result;
				}
				result.roi = Rect2(values[0], values[1], values[2] - values[0], values[3] - values[1]);
			}
		}
		return result;
	}();
	return config;
}

static constexpr uint32_t REFLECTION_DIAGNOSTIC_HEADER = 37; // Original 33 source records plus four diagnostic header records.
static constexpr uint32_t REFLECTION_DIAGNOSTIC_STRIDE = 48;
static constexpr uint32_t REFLECTION_DIAGNOSTIC_BYTES = (REFLECTION_DIAGNOSTIC_HEADER + 32 * 80 * REFLECTION_DIAGNOSTIC_STRIDE) * 16;

static bool diagnostic_hits_enabled() {
	static const bool enabled = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_HITS").is_empty();
	return enabled;
}

static bool validate_hit_updates(RID p_keys, uint32_t p_frame, RID p_owners, RID p_samples, RID p_updates, RID p_primary, RID p_secondary, uint32_t p_cells, uint32_t p_rays, bool p_multibounce, uint32_t p_active_rays = UINT32_MAX) {
	ERR_FAIL_COND_V(p_rays == 0 || (p_active_rays != UINT32_MAX && p_active_rays > p_rays), false);
	const uint32_t active_rays = MIN(p_active_rays, p_rays);
	RD *rd = RD::get_singleton();
	Vector<uint8_t> owner_bytes = rd->buffer_get_data(p_owners);
	Vector<uint8_t> sample_bytes = rd->buffer_get_data(p_samples);
	Vector<uint8_t> update_bytes = rd->buffer_get_data(p_updates);
	ERR_FAIL_COND_V(update_bytes.size() != int64_t(p_cells / 85 * 64 * 16), false);
	const uint32_t *updates = reinterpret_cast<const uint32_t *>(update_bytes.ptr());
	Vector<uint8_t> primary_bytes = rd->buffer_get_data(p_primary);
	Vector<uint8_t> secondary_bytes = p_multibounce ? rd->buffer_get_data(p_secondary) : Vector<uint8_t>();
	const uint32_t count = p_rays * (p_multibounce ? 2 : 1);
	ERR_FAIL_COND_V(owner_bytes.size() != int64_t(p_cells * 8) || sample_bytes.size() != int64_t(count * 48) || primary_bytes.size() != int64_t(p_rays * AMD_GI_RAY_BYTES), false);
	ERR_FAIL_COND_V(p_multibounce && secondary_bytes.size() != int64_t(p_rays * AMD_GI_RAY_BYTES), false);
	const uint32_t *owners = reinterpret_cast<const uint32_t *>(owner_bytes.ptr());
	const uint32_t *samples = reinterpret_cast<const uint32_t *>(sample_bytes.ptr());
	const uint32_t *primary = reinterpret_cast<const uint32_t *>(primary_bytes.ptr());
	const uint32_t *secondary = reinterpret_cast<const uint32_t *>(secondary_bytes.ptr());
	Vector<uint8_t> visited;
	visited.resize_initialized(count);
	uint8_t *seen = visited.ptrw();
	uint32_t primary_count = 0, secondary_count = 0, shared_cells = 0;
	for (uint32_t cell : validation_active_cells(p_keys, p_cells, p_frame)) {
		uint32_t length = 0;
		uint32_t quantized_sum[3] = {}, rounding_ties[3] = {}, direct_samples = 0;
		for (uint32_t id = owners[p_cells + cell]; id != UINT32_MAX; id = samples[id * 12 + 8]) {
			ERR_FAIL_COND_V_MSG(id >= count || id % p_rays >= active_rays || seen[id] || cell % 85 >= 64, false, "AMD GI hit list contains a cycle, duplicate or invalid index.");
			seen[id] = 1;
			const uint32_t *ray = id < p_rays ? primary + id * AMD_GI_RAY_WORDS : secondary + (id - p_rays) * AMD_GI_RAY_WORDS;
			ERR_FAIL_COND_V(ray[7] != cell, false);
			for (uint32_t channel = 0; channel < (p_multibounce && id < p_rays ? 8u : 4u); channel++) {
				float value;
				memcpy(&value, samples + id * 12 + channel, sizeof(float));
				ERR_FAIL_COND_V_MSG(!Math::is_finite(value) || value < 0, false, vformat("AMD GI invalid hit contribution: frame=%d hit=%d channel=%d value=%f instance/front=%d primitive=%d bary=%d", p_frame, id, channel, value, ray[8], ray[10], ray[11]));
			}
			for (uint32_t channel = 0; channel < 3; channel++) {
				float value;
				memcpy(&value, samples + id * 12 + channel, sizeof(float));
				const float scaled = value * 1000.0f;
				ERR_FAIL_COND_V(double(scaled) >= double(UINT32_MAX), false);
				const float lower = Math::floor(scaled);
				if (scaled - lower == 0.5f) {
					quantized_sum[channel] += uint32_t(lower);
					rounding_ties[channel]++;
				} else {
					quantized_sum[channel] += uint32_t(Math::round(scaled));
				}
			}
			float direct_count, indirect_count;
			memcpy(&direct_count, samples + id * 12 + 3, sizeof(float));
			// Material attributes are reconstructed on the GPU from compact
			// visibility. The hit flags report emissive termination explicitly;
			// there is no longer an emission vector in the ray-record buffer.
			const bool emissive_primary = (samples[id * 12 + 9] & 2u) != 0u;
			ERR_FAIL_COND_V(emissive_primary && id >= p_rays, false);
			const bool valid_direct = (samples[id * 12 + 9] & 4u) != 0u;
			ERR_FAIL_COND_V(direct_count != (valid_direct ? 1.0f : 0.0f) || (emissive_primary && valid_direct), false);
			direct_samples += uint32_t(direct_count);
			if (p_multibounce && id < p_rays) {
				memcpy(&indirect_count, samples + id * 12 + 7, sizeof(float));
				float distance;
				memcpy(&distance, secondary + id * AMD_GI_RAY_WORDS + 3, sizeof(float));
				bool continued = distance >= 0 && secondary[id * AMD_GI_RAY_WORDS + 7] != UINT32_MAX;
				ERR_FAIL_COND_V_MSG(indirect_count != (continued ? 1.0f : 0.0f), false, vformat("AMD GI continuation membership mismatch: hit=%d query_distance=%.9f cell=%d indirect_count=%f", id, distance, secondary[id * AMD_GI_RAY_WORDS + 7], indirect_count));
			}
			primary_count += id < p_rays;
			secondary_count += id >= p_rays;
			length++;
		}
		const uint32_t update = (cell / 85 * 64 + cell % 85) * 4;
		ERR_FAIL_COND_V_MSG(updates[update + 3] != direct_samples, false, "AMD GI atomic cache update lost a sample.");
		for (uint32_t channel = 0; channel < 3; channel++) {
			// GLSL round permits either neighbor at an exact half-integer.
			ERR_FAIL_COND_V_MSG(updates[update + channel] - quantized_sum[channel] > rounding_ties[channel], false, "AMD GI atomic cache sum differs from its registered contributions.");
		}
		shared_cells += length > 1;
	}
	for (uint32_t id = 0; id < count; id++) {
		if (id % p_rays >= active_rays) {
			continue;
		}
		const uint32_t *ray = id < p_rays ? primary + id * AMD_GI_RAY_WORDS : secondary + (id - p_rays) * AMD_GI_RAY_WORDS;
		ERR_FAIL_COND_V_MSG(bool(seen[id]) != (ray[7] != UINT32_MAX), false, "AMD GI dropped a registered hit from cache shading.");
	}
	print_line(vformat("AMD GI hit update validation: primary=%d secondary=%d shared_cells=%d", primary_count, secondary_count, shared_cells));
	return true;
}

static void unpack_reflection_sample(const uint8_t *p_bytes, float (&r_values)[20]) {
	// std430 StoredReflection: two vec4, three half4, then eight pad bytes.
	memcpy(r_values, p_bytes, 8 * sizeof(float));
	const uint16_t *half = reinterpret_cast<const uint16_t *>(p_bytes + 32);
	for (uint32_t i = 0; i < 12; i++) {
		r_values[8 + i] = Math::half_to_float(half[i]);
	}
}

static bool validate_reflections(RID p_buffer, uint32_t p_count, RID p_queue, uint32_t p_offset, bool p_compacted) {
	Vector<uint8_t> bytes = RD::get_singleton()->buffer_get_data(p_buffer);
	ERR_FAIL_COND_V(bytes.size() != int64_t(p_count * 64), false);
	HashSet<uint32_t> queued;
	if (p_compacted) {
		Vector<uint8_t> commands = RD::get_singleton()->buffer_get_data(p_queue, 16 + p_offset * 4, (4 + p_count) * 4);
		ERR_FAIL_COND_V(commands.size() != int64_t((4 + p_count) * 4), false);
		const uint32_t *queue = reinterpret_cast<const uint32_t *>(commands.ptr());
		ERR_FAIL_COND_V(queue[3] > p_count, false);
		const uint32_t groups = (queue[3] + 63) / 64;
		ERR_FAIL_COND_V(queue[0] != MIN(groups, 65535u) || queue[1] != MAX((groups + 65534) / 65535, 1u) || queue[2] != 1, false);
		for (uint32_t i = 0; i < queue[3]; i++) {
			uint32_t sample = queue[4 + i];
			ERR_FAIL_COND_V_MSG(sample >= p_count || queued.has(sample), false, "AMD GI glossy queue contains an invalid or duplicate sample.");
			queued.insert(sample);
		}
	}
	uint32_t traced = 0, reused = 0;
	for (uint32_t i = 0; i < p_count; i++) {
		float sample[20];
		unpack_reflection_sample(bytes.ptr() + i * 64, sample);
		for (uint32_t j = 0; j < 20; j++) {
			ERR_FAIL_COND_V_MSG(!Math::is_finite(sample[j]), false, "AMD GI reflection contains non-finite data.");
		}
		if (p_compacted) {
			ERR_FAIL_COND_V_MSG(queued.has(i) != (sample[3] >= 0.0f && sample[11] >= 0.0f), false, "AMD GI glossy queue omitted a ray or scheduled a resolved probe/sky pixel.");
		}
		if (sample[3] < 0.0f) {
			continue;
		}
		ERR_FAIL_COND_V(sample[3] > 1.0f || sample[15] < 0.0f || sample[15] > 1.0f, false);
		traced += sample[11] > 0.0f && sample[15] > 0.0f;
		reused += sample[11] < 0.0f;
	}
	print_line(vformat("AMD GI reflection validation: budget=%d traced=%d probes=%d", p_count, traced, reused));
	return true;
}

Dictionary AMDGI::get_diagnostics(const Ref<RenderSceneBuffersRD> &p_buffers) {
	if (p_buffers.is_null() || !is_enabled()) {
		return Dictionary();
	}
	Dictionary result;
	const bool detailed = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/statistics")) || bool(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/exclusion_reports"));
	if (detailed) {
		if (p_buffers->has_custom_data(RB_SCOPE_AMD_GI)) {
			Ref<ViewData> data = p_buffers->get_custom_data(RB_SCOPE_AMD_GI);
			result = data->diagnostics.duplicate(true);
		}
		Dictionary collection = p_buffers->get_amd_gi_collection_diagnostics();
		if (!collection.is_empty()) {
			result["collection"] = collection.duplicate(true);
		}
	}
	if (p_buffers->has_custom_data(RB_SCOPE_AMD_GI_BATCH)) {
		Ref<BatchData> data = p_buffers->get_custom_data(RB_SCOPE_AMD_GI_BATCH);
		Dictionary batch;
		batch["frame"] = data->last_completed_frame;
		batch["valid"] = data->valid;
		batch["capacity"] = data->capacity;
		result["batch"] = batch;
	}
	// The RenderingServer query is serialized onto the rendering thread.
	// Querying this detached snapshot never schedules a GPU readback.
	return result;
}

bool AMDGI::has_material_pipelines(const RaytracingGIScene &p_scene) const {
	return material_preparation.is_ready(&p_scene, p_scene.get_source_materials().get_shader_revision());
}

Dictionary AMDGI::get_preparation_status(const RaytracingGIScene &p_scene) const {
	const bool ready = !preparation_hold && has_material_pipelines(p_scene);
	Dictionary status;
	status["state"] = preparation_hold ? "gathering" : (ready ? "ready" : (preparation_failed ? "failed" : "compiling"));
	status["ready"] = ready;
	status["revision"] = p_scene.get_source_materials().get_shader_revision();
	status["material_errors"] = p_scene.get_preparation_material_errors();
	status["completed_passes"] = ready ? (PASS_COUNT - uint32_t(!diagnostic_source_enabled()) - uint32_t(!regional_batch)) : (pending ? pending->completed_passes.get() : 0);
	status["total_passes"] = PASS_COUNT - uint32_t(!diagnostic_source_enabled()) - uint32_t(!regional_batch);
	status["bytecode_or_resident_cache_hit"] = preparation_cache_hit;
	return status;
}

void AMDGI::prepare_scene_material_pipelines(const RaytracingGIScene &p_scene, bool p_hold) {
	preparation_hold = p_hold;
	if (p_hold) {
		update_material_pipelines(nullptr);
		return;
	}
	update_material_pipelines(&p_scene);
	// Legacy image fixtures advance scripted phases after a fixed number of
	// frames. Their launcher can hold the fixture clock during preparation.
	static const bool wait_for_fixture = OS::get_singleton()->get_environment("GODOT_AMD_GI_FIXTURE_WAIT_FOR_PIPELINES") == "1";
	if (wait_for_fixture) {
		while (pending) {
			OS::get_singleton()->delay_usec(1000);
			update_material_pipelines(&p_scene);
		}
	}
}

void AMDGI::build_material_passes(void *p_data) {
	MaterialBuild &build = *static_cast<MaterialBuild *>(p_data);
#ifdef THREADS_ENABLED
	Thread::set_name("AMD GI pipelines");
#endif
	OS *os = OS::get_singleton();
	const bool trace = os->is_stdout_verbose();
	while (!build.cancel.is_set() && !build.failed.is_set()) {
		const uint32_t slot = build.next_pass.postincrement();
		if (slot >= build.pass_count) {
			break;
		}
		const uint32_t pass = build.pass_order[slot];
		if (build.inject_failure && slot + 1 == build.pass_count) {
			build.failed.set();
			break;
		}
		const uint64_t start = trace ? os->get_ticks_usec() : 0;
		const RID pipeline = RD::get_singleton()->compute_pipeline_create(build.shaders[pass]);
		build.pipelines[pass] = pipeline;
		if (pipeline.is_valid()) {
			build.completed_passes.increment();
		} else {
			build.failed.set();
		}
		if (trace) {
			print_verbose(vformat("AMD GI pipeline revision=%d pass=%d driver_ms=%.3f", build.revision, pass, (os->get_ticks_usec() - start) / 1000.0));
		}
	}
}

void AMDGI::build_material_pipelines(void *p_data) {
	MaterialBuild &build = *static_cast<MaterialBuild *>(p_data);
#ifdef THREADS_ENABLED
	Thread workers[3];
	Thread::Settings settings;
	settings.priority = Thread::PRIORITY_LOW;
	for (uint32_t i = 1; i < build.worker_count; i++) {
		workers[i - 1].start(build_material_passes, p_data, settings);
	}
#endif
	build_material_passes(p_data);
#ifdef THREADS_ENABLED
	for (uint32_t i = 1; i < build.worker_count; i++) {
		workers[i - 1].wait_to_finish();
	}
#endif
	for (uint32_t i = 0; i < PASS_COUNT; i++) {
		if (build.shaders[i].is_valid() && build.pipelines[i].is_null()) {
			build.failed_pass = i;
			break;
		}
	}
	build.finished.set();
}

void AMDGI::free_material_build() {
	amd_gi_release_pipeline_candidate(pending->pipelines, [](RID p_pipeline) { RD::get_singleton()->free_rid(p_pipeline); });
	if (pending->version.is_valid()) {
		shader.version_free(pending->version);
	}
	memdelete(pending);
	pending = nullptr;
}

bool AMDGI::suspend_material_pipelines() {
	// A new scene may reuse the old object's address and revision. Only exact
	// generated source (including case IDs and descriptor capacities) can rebind it.
	material_preparation = {};
	preparation_hold = false;
	preparation_failed = false;
	if (blue_noise.is_valid()) {
		RD::get_singleton()->free_rid(blue_noise);
		blue_noise = RID();
		random_seed_count = 0;
	}
	update_material_pipelines(nullptr);
	return pending == nullptr;
}

// Only join finished work during scene updates. The version owns all the
// worker's shader IDs until the render thread publishes or releases the build.
bool AMDGI::poll_material_build() {
	if (pending->worker.is_started()) {
		if (!pending->finished.is_set()) {
			return false;
		}
		pending->worker.wait_to_finish();
		return true;
	}
	if (pending->version.is_null()) {
		return true;
	}
	if (shader.version_group_is_compiling(pending->version, 0, pending->bytecode_cache_hit)) {
		return false;
	}
	if (pending->cancel.is_set()) {
		return true;
	}
	for (uint32_t i = 0; i < PASS_COUNT; i++) {
		if (!shader.is_variant_enabled(i)) {
			continue;
		}
		pending->shaders[i] = shader.version_get_shader(pending->version, i);
		if (pending->shaders[i].is_null()) {
			pending->failed_pass = i;
			return true;
		}
	}
	// Schedule the material-evaluating programs first so short passes can fill
	// the remaining worker time instead of leaving one long compiler tail.
	const uint32_t heavy_passes[] = { RESOLVE, SHADE_HITS, UPDATE, REFLECTION_TRACE, TRACE, POPULATE, LIGHT_GRID, SHADE_INDIRECT_HITS, PREPARE_LIGHTS };
	bool scheduled[PASS_COUNT] = {};
	for (uint32_t pass : heavy_passes) {
		pending->pass_order[pending->pass_count++] = pass;
		scheduled[pass] = true;
	}
	for (uint32_t i = 0; i < PASS_COUNT; i++) {
		if (!scheduled[i] && pending->shaders[i].is_valid()) {
			pending->pass_order[pending->pass_count++] = i;
		}
	}
#ifdef THREADS_ENABLED
	Thread::Settings settings;
	settings.priority = Thread::PRIORITY_LOW;
	pending->worker.start(build_material_pipelines, pending, settings);
	return false;
#else
	build_material_pipelines(pending);
	return true;
#endif
}

void AMDGI::update_material_pipelines(const RaytracingGIScene *p_scene) {
	const uint64_t revision = p_scene ? p_scene->get_source_materials().get_shader_revision() : 0;
	if (p_scene && material_preparation.is_ready(p_scene, revision)) {
		return;
	}
	OS *os = OS::get_singleton();
	if (pending) {
		if (pending->scene != p_scene || pending->revision != revision) {
			pending->cancel.set();
		}
		if (!poll_material_build()) {
			return;
		}
		if (!pending->cancel.is_set() && pending->failed_pass == PASS_COUNT) {
			SWAP(version, pending->version);
			SWAP(published_source, pending->source);
			for (uint32_t i = 0; i < PASS_COUNT; i++) {
				SWAP(pipelines[i], pending->pipelines[i]);
			}
			material_preparation.publish(p_scene, revision);
			preparation_cache_hit = pending->bytecode_cache_hit;
			// Save even small GI additions before gameplay, rather than depending
			// on the generic cache-size threshold or an eventual clean shutdown.
			RD::get_singleton()->update_pipeline_cache(false, true);
			print_verbose(vformat("AMD GI material pipelines ready revision=%d bytecode_cache_hit=%s elapsed_ms=%.3f", revision, pending->bytecode_cache_hit, (os->get_ticks_usec() - pending->start_usec) / 1000.0));
			free_material_build();
			return;
		}
		if (!pending->cancel.is_set()) {
			preparation_failed = true;
			if (pending->inject_failure && pending->failed_pass != PASS_COUNT) {
				material_failure_injected = true;
			}
			if (material_preparation.record_failure(os->get_ticks_usec())) {
				WARN_PRINT(vformat("AMD GI material revision %d could not prepare pass %d. Using native lighting until a retry succeeds (up to 30 seconds between attempts).", revision, pending->failed_pass));
			}
		} else {
			print_verbose(vformat("AMD GI discarded superseded material revision %d.", pending->revision));
		}
		free_material_build();
	}
	if (!p_scene || !material_preparation.can_attempt(p_scene, revision, os->get_ticks_usec())) {
		return;
	}
	String source = p_scene->get_source_materials().get_shader_source();
	if (version.is_valid() && published_source == source) {
		material_preparation.publish(p_scene, revision);
		preparation_failed = false;
		preparation_cache_hit = true;
		print_verbose(vformat("AMD GI material pipelines ready revision=%d resident_cache_hit=true", revision));
		return;
	}
	start_material_build(p_scene, revision, source);
}

void AMDGI::start_material_build(const RaytracingGIScene *p_scene, uint64_t p_revision, const String &p_source) {
	OS *os = OS::get_singleton();
	preparation_failed = false;
	preparation_cache_hit = false;
	pending = memnew(MaterialBuild);
	pending->scene = p_scene;
	pending->source = p_source;
	pending->revision = p_revision;
	pending->start_usec = os->get_ticks_usec();
	pending->worker_count = CLAMP(os->get_processor_count() / 2, 1, 4);
	const String workers = os->get_environment("GODOT_AMD_GI_PIPELINE_WORKERS");
	if (workers.is_valid_int()) {
		pending->worker_count = CLAMP(workers.to_int(), 1, 4);
	}
	pending->version = shader.version_create();
	if (pending->version.is_null()) {
		pending->failed_pass = 0;
		return;
	}
	Vector<String> defines;
	if (regional_batch) {
		defines.push_back("#define AMD_GI_REGIONAL_BATCH\n");
	}
	if (os->get_environment("GODOT_AMD_GI_VALIDATE_LIGHT_GRID") == "1") {
		defines.push_back("#define AMD_GI_VALIDATE_LIGHT_GRID\n");
	}
	if (diagnostic_hits_enabled()) {
		defines.push_back("#define AMD_GI_DIAGNOSTIC_HITS\n");
	}
	if (diagnostic_source_enabled()) {
		defines.push_back("#define AMD_GI_DIAGNOSTIC_SOURCE\n");
	}
	if (reflection_diagnostic_config().enabled) {
		defines.push_back("#define AMD_GI_DIAGNOSTIC_REFLECTION\n");
	}
	const String injection = os->get_environment("GODOT_AMD_GI_FAIL_MATERIAL_PIPELINE");
	pending->inject_failure = injection == "always:last" || (injection == "once:last" && !material_failure_injected);
	if (os->is_stdout_verbose()) {
		print_verbose(vformat("AMD GI preparing material revision=%d source_sha256=%s", p_revision, p_source.sha256_text()));
	}
	shader.version_set_compute_code(pending->version, {}, "", p_source, defines);
}

AMDGI::AMDGI(bool p_regional_batch) :
		regional_batch(p_regional_batch) {
	ERR_FAIL_COND(regional_batch ? !is_regional_supported() : !is_supported());
	Vector<String> modes;
	// Remove unrelated entry points before SPIR-V generation. A specialization
	// constant leaves the native material call trees in every driver's input.
	for (uint32_t i = 0; i < PASS_COUNT; i++) {
		modes.push_back("#define AMD_GI_PASS " + itos(i) + "\n");
	}
	shader.initialize(modes);
	shader.set_variant_enabled(VALIDATE_SOURCE, diagnostic_source_enabled());
	shader.set_variant_enabled(BATCH_JOIN, regional_batch);
	environment_shader.initialize({ "#define CONVERT_OCTMAP\n", "" });
	environment_version = environment_shader.version_create();
	for (int i = 0; i < 2; i++) {
		environment_pipelines[i] = RD::get_singleton()->compute_pipeline_create(environment_shader.version_get_shader(environment_version, i));
	}
}

RID AMDGI::prepare_environment(WorldData &p_data, const Environment &p_environment) {
	RD *rd = RD::get_singleton();
	if (p_data.environment_source != p_environment.radiance) {
		if (p_data.environment_cube.is_valid()) {
			rd->free_rid(p_data.environment_cube);
		}
		p_data.environment_cube = RID();
		p_data.environment_mips.clear();
		p_data.environment_source = p_environment.radiance;
	}
	if (p_environment.radiance.is_null()) {
		return TextureStorage::get_singleton()->texture_rd_get_default(TextureStorage::DEFAULT_RD_TEXTURE_CUBEMAP_BLACK);
	}
	if (p_data.environment_cube.is_valid() && p_environment.revision != 0 && p_data.environment_revision == p_environment.revision && p_data.environment_border == p_environment.border) {
		return p_data.environment_cube;
	}
	const uint32_t size = rd->texture_get_format(p_environment.radiance).width;
	if (p_data.environment_cube.is_null()) {
		RD::TextureFormat format;
		format.texture_type = RD::TEXTURE_TYPE_CUBE;
		format.format = RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
		format.width = size;
		format.height = size;
		format.array_layers = 6;
		format.mipmaps = Image::get_image_required_mipmaps(size, size, Image::FORMAT_RGBAH) + 1;
		format.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT;
		p_data.environment_cube = rd->texture_create(format, RD::TextureView());
		rd->set_resource_name(p_data.environment_cube, "AMD GI unfiltered environment and cone mips");
		for (uint32_t mip = 0; mip < format.mipmaps; mip++) {
			p_data.environment_mips.push_back(rd->texture_create_shared_from_slice(RD::TextureView(), p_data.environment_cube, 0, mip, 1, RD::TEXTURE_SLICE_2D_ARRAY, 6));
		}
	}
	// Capsaicin samples a complete, ordinary cubemap mip chain, not a GGX
	// roughness prefilter. Convert Godot's native octahedral sky once per sky
	// update; the cube remains in sky space so orientation/energy edits reuse it.
	const RID sampler = MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	RD::ComputeListID list = rd->compute_list_begin();
	for (int mip = 0; mip < p_data.environment_mips.size(); mip++) {
		const uint32_t mode = mip == 0 ? 0 : 1;
		const RID source = mip == 0 ? p_environment.radiance : p_data.environment_mips[mip - 1];
		LocalVector<RD::Uniform> uniforms;
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, Vector<RID>{ sampler, source }));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 1, Vector<RID>{ p_data.environment_mips[mip] }));
		RID uniform_set = UniformSetCacheRD::get_singleton()->get_cache_vec(environment_shader.version_get_shader(environment_version, mode), 0, uniforms);
		struct {
			uint32_t size;
			float border;
			uint32_t padding[2];
		} push = { MAX(size >> mip, 1u), p_environment.border, { 0, 0 } };
		rd->compute_list_bind_compute_pipeline(list, environment_pipelines[mode]);
		rd->compute_list_bind_uniform_set(list, uniform_set, 0);
		rd->compute_list_set_push_constant(list, &push, sizeof(push));
		rd->compute_list_dispatch_threads(list, push.size, push.size, 6);
		rd->compute_list_add_barrier(list);
	}
	rd->compute_list_end();
	p_data.environment_revision = p_environment.revision;
	p_data.environment_border = p_environment.border;
	return p_data.environment_cube;
}

void AMDGI::ensure_sampling_data(const Size2i &p_size) {
	const uint32_t count = MAX(p_size.x, 1920) * MAX(p_size.y, 1080);
	if (count <= random_seed_count) {
		return;
	}
	Vector<uint8_t> data;
	data.resize(sizeof(AMD_GI_BLUE_NOISE) + (count + 1) * sizeof(uint32_t));
	memcpy(data.ptrw(), AMD_GI_BLUE_NOISE, sizeof(AMD_GI_BLUE_NOISE));
	uint32_t *seeds = reinterpret_cast<uint32_t *>(data.ptrw() + sizeof(AMD_GI_BLUE_NOISE));
	seeds[0] = count;
	// Capsaicin RandomNumberGenerator's deterministic default.
	std::mt19937 generator(5489);
	for (uint32_t i = 0; i < count; i++) {
		seeds[i + 1] = generator();
	}
	if (blue_noise.is_valid()) {
		RD::get_singleton()->free_rid(blue_noise);
	}
	blue_noise = RD::get_singleton()->storage_buffer_create(data.size(), data);
	random_seed_count = count;
}

AMDGI::~AMDGI() {
	if (pending) {
		pending->cancel.set();
		if (pending->worker.is_started()) {
			pending->worker.wait_to_finish();
		}
		free_material_build();
	}
	if (blue_noise.is_valid()) {
		RD::get_singleton()->free_rid(blue_noise);
	}
	for (RID pipeline : pipelines) {
		if (pipeline.is_valid()) {
			RD::get_singleton()->free_rid(pipeline);
		}
	}
	if (version.is_valid()) {
		shader.version_free(version);
	}
	for (RID pipeline : environment_pipelines) {
		if (pipeline.is_valid()) {
			RD::get_singleton()->free_rid(pipeline);
		}
	}
	if (environment_version.is_valid()) {
		environment_shader.version_free(environment_version);
	}
}

void AMDGI::BindingReuse::clear() {
	uniforms.clear();
	for (RID &set : sets) {
		set = RID();
	}
}

void AMDGI::BindingReuse::update(const LocalVector<RD::Uniform> &p_uniforms) {
	// Compare the complete request once per render, including entries a given
	// shader variant does not consume. This preserves UniformSetCacheRD's key.
	bool matches = uniforms.size() == p_uniforms.size();
	for (uint32_t i = 0; matches && i < uniforms.size(); i++) {
		const RD::Uniform &previous = uniforms[i];
		const RD::Uniform &current = p_uniforms[i];
		matches = previous.uniform_type == current.uniform_type && previous.binding == current.binding && previous.get_id_count() == current.get_id_count();
		for (uint32_t j = 0; matches && j < current.get_id_count(); j++) {
			matches = previous.get_id(j) == current.get_id(j);
		}
	}
	if (matches) {
		return;
	}
	uniforms = p_uniforms;
	for (RID &set : sets) {
		set = RID();
	}
}

RID AMDGI::BindingReuse::get_uniform_set(uint32_t p_pass, RID p_shader, uint32_t p_set, const LocalVector<RD::Uniform> &p_uniforms, bool p_validate) {
	RID &set = sets[p_pass];
	// A resource can invalidate a descriptor even when our requested RIDs have
	// not changed. RD and its ordinary cache remain the lifetime authority.
	if (set.is_valid() && RD::get_singleton()->uniform_set_is_valid(set)) {
		if (p_validate) {
			RID reference = UniformSetCacheRD::get_singleton()->get_cache_vec(p_shader, p_set, p_uniforms);
			ERR_FAIL_COND_V_MSG(set != reference, RID(), "AMDGI binding reuse differs from the ordinary uniform set cache.");
			static bool reported = false;
			if (!reported) {
				print_line("AMDGI bindings oracle: checked=true");
				reported = true;
			}
		}
		return set;
	}
	set = UniformSetCacheRD::get_singleton()->get_cache_vec(p_shader, p_set, p_uniforms);
	return set;
}

AMDGI::WorldData::LightHistoryAction AMDGI::WorldData::update_light_order(const RaytracingGIScene &p_scene, uint32_t p_environment_count, bool p_retain_on_emitter_transitions, bool p_light_resampling) {
	const auto &lights = p_scene.get_lights();
	const bool prefix_boundary = previous_environment_count != p_environment_count || (previous_analytic_count > 0) != !lights.is_empty();
	const bool emitter_boundary = (previous_emitter_count > 0) != (p_scene.get_emitter_count() > 0);
	LightHistoryAction action = (prefix_boundary || emitter_boundary) ? LightHistoryAction::RESET_VIEW : LightHistoryAction::KEEP;
	if (p_retain_on_emitter_transitions) {
		// The dense list ends with emitter triangles. Adding its first or dropping its last
		// preserves indices in the sky/analytic prefix if its ordering is identical.
		bool same_order = true;
		if (p_light_resampling) {
			same_order = previous_analytic_order.size() == lights.size();
			previous_analytic_order.resize(lights.size());
		}
		bool lit_by_analytic_light = false;
		for (uint32_t i = 0; i < lights.size(); i++) {
			const auto &light = lights[i];
			lit_by_analytic_light |= light.mask != 0 && (light.type == 0 || light.range > 0.0f) && (light.color[0] > 0.0f || light.color[1] > 0.0f || light.color[2] > 0.0f);
			if (p_light_resampling) {
				const uint64_t id = (uint64_t(light.identity[1]) << 32) | light.identity[0];
				const AnalyticLightKey &old = previous_analytic_order[i];
				same_order = same_order && old.id == id && old.type == light.type;
				previous_analytic_order[i] = { id, light.type };
			} else if (lit_by_analytic_light) {
				break;
			}
		}
		// A bound sky can be black. Keep the reference clear when the emitter might
		// be the only light. Out-of-list emitter samples are rejected by resampled_direct.
		if (emitter_boundary && !prefix_boundary && previously_lit_by_analytic_light && lit_by_analytic_light) {
			action = same_order ? LightHistoryAction::KEEP : LightHistoryAction::RESET_RESERVOIRS;
		}
		previously_lit_by_analytic_light = lit_by_analytic_light;
	} else {
		previous_analytic_order.clear();
		previously_lit_by_analytic_light = false;
	}
	previous_analytic_count = lights.size();
	previous_emitter_count = p_scene.get_emitter_count();
	previous_environment_count = p_environment_count;
	return action;
}

bool AMDGI::WorldData::ensure_light_grid(uint32_t p_emitters, uint32_t p_lights) {
	const uint32_t strata = MIN(64u, MAX(p_lights, 1u));
	const uint64_t leaves = (uint64_t(p_lights) + strata * 64 - 1) / (strata * 64);
	const uint64_t tops = (leaves + 63) / 64;
	// Reuse binding 44: reservoirs, current-frame native proposal colors, and
	// two levels of per-stratum masks. Original light IDs never change.
	const uint64_t bytes = 32ull + (16ull * 16 * 16 * 64 + p_emitters + (leaves + tops) * 64) * 16;
	ERR_FAIL_COND_V(bytes > UINT32_MAX, false);
	if (light_grid.is_null() || light_grid_bytes < bytes) {
		if (light_grid.is_valid()) {
			RD::get_singleton()->free_rid(light_grid);
		}
		light_grid = RD::get_singleton()->storage_buffer_create(bytes);
		light_grid_bytes = bytes;
	}
	return light_grid.is_valid();
}

AMDGI::WorldData::~WorldData() {
	// Uniform sets only borrow these handles. RD retains submitted GPU users
	// through its normal deferred destruction; the final CPU owner releases once.
	for (RID handle : { keys, cache[0], cache[1], owners, indirect_cache[0], indirect_cache[1], direct_updates, light_reservoirs[0], light_reservoirs[1], light_grid, environment_cube }) {
		if (handle.is_valid()) {
			RD::get_singleton()->free_rid(handle);
		}
	}
}

void AMDGI::ViewData::free_data() {
	binding_version = RID();
	for (BindingReuse &binding : bindings) {
		binding.clear();
	}
	material_bindings.clear();
	for (RID *handle : { &feedback_lights, &frame_uniform, &debug_stats, &probes[0], &probes[1], &radiance[0], &radiance[1], &pixels[0], &pixels[1], &rays, &scratch, &spawn, &queues, &probe_mask, &work, &cached_probes, &cached_state, &cached_order[0], &cached_order[1], &secondary_rays, &reflection_samples, &reflection_history[0], &reflection_history[1], &hit_samples, &source_validation }) {
		if (handle->is_valid()) {
			RD::get_singleton()->free_rid(*handle);
			*handle = RID();
		}
	}
	world.unref();
	feedback_light_bytes = 0;
	debug_stats_bytes = 0;
	diagnostics.clear();
	valid = false;
	size = Size2i();
}

void AMDGI::BatchData::free_data() {
	for (RID *handle : { &rays, &secondary_rays, &hit_samples, &work, &origins }) {
		if (handle->is_valid()) {
			RD::get_singleton()->free_rid(*handle);
			*handle = RID();
		}
	}
	world.unref();
	capacity = 0;
	last_completed_frame = -1;
	valid = false;
	reservoirs_valid = false;
	prepared_version = RID();
	prepared_layout = 0;
}

uint32_t AMDGI::get_region_guard_pixels() {
	// Finite reconstruction kernels only. The closest-probe mip fallback and
	// temporal reprojection do not have a finite full-view equivalence bound.
	// Near-field sampling explicitly consults the other regional surface.
	uint32_t guard = 64; // 3 probe tiles + interpolation + separable diffuse blur.
	if (!bool(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/enabled"))) {
		return guard;
	}
	const uint32_t stride = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/half_resolution")) ? 2u : 1u;
	const String suffix = stride == 2 ? "half" : "full";
	const uint32_t mode = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/denoiser")), 0, 2);
	uint32_t radius = 0;
	if (mode == 0) {
		radius = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/split_radius_" + suffix)), 1, 32) + stride;
	} else if (mode == 1) {
		const uint32_t passes = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/filter_passes")), 2, 8);
		for (uint32_t pass = 0; pass < passes; pass++) {
			const uint32_t step = 1u << pass;
			radius += ((2 * step + stride - 1) / stride) * stride;
		}
		radius += (1u << (passes - 1)) / 2u + stride + 4; // final jitter, phase, roughness neighborhood
	}
	if (bool(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/firefly_filter"))) {
		radius += stride * (CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/firefly_mark_radius_" + suffix)), 0, 16) + CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/firefly_cleanup_radius_" + suffix)), 0, 16));
	}
	return MAX(guard, (radius + 7u) & ~7u);
}

void AMDGI::prepare_feedback_lights(const Ref<RenderSceneBuffersRD> &p_buffers, const PagedArray<RID> &p_lights) {
	ERR_FAIL_COND(!p_buffers->has_custom_data(RB_SCOPE_AMD_GI));
	Ref<ViewData> data = p_buffers->get_custom_data(RB_SCOPE_AMD_GI);
	Vector<uint8_t> bytes = LightStorage::get_singleton()->get_gi_feedback_light_data(p_lights);
	RD *rd = RD::get_singleton();
	if (data->feedback_light_bytes < uint32_t(bytes.size())) {
		if (data->feedback_lights.is_valid()) {
			rd->free_rid(data->feedback_lights);
		}
		data->feedback_light_bytes = Math::nearest_power_of_2_templated(uint32_t(bytes.size()));
		data->feedback_lights = rd->storage_buffer_create(data->feedback_light_bytes);
	}
	rd->buffer_update(data->feedback_lights, 0, bytes.size(), bytes.ptr());
}

RID AMDGI::get_feedback_lights(const Ref<RenderSceneBuffersRD> &p_buffers) const {
	if (p_buffers.is_valid() && p_buffers->has_custom_data(RB_SCOPE_AMD_GI)) {
		Ref<ViewData> data = p_buffers->get_custom_data(RB_SCOPE_AMD_GI);
		return data->feedback_lights;
	}
	return RID();
}

void AMDGI::clear(const Ref<RenderSceneBuffersRD> &p_buffers) {
	if (p_buffers->has_custom_data(RB_SCOPE_AMD_GI_BATCH)) {
		p_buffers->set_custom_data(RB_SCOPE_AMD_GI_BATCH, Ref<RenderBufferCustomDataRD>());
	}
	if (p_buffers->has_custom_data(RB_SCOPE_AMD_GI)) {
		p_buffers->set_custom_data(RB_SCOPE_AMD_GI, Ref<RenderBufferCustomDataRD>());
	}
	p_buffers->clear_context(RB_SCOPE_AMD_GI);
	p_buffers->clear_context(RB_SCOPE_AMD_GI_GEOMETRY);
	p_buffers->clear_context(SNAME("amd_gi_debug"));
}

// Prepared synchronously on the render thread. Strong references and owned
// vectors outlive every pass range; no closure borrows preparation-stack data.
// The scene and shader version are borrowed from the same synchronous render.
struct AMDGI::RenderContext {
	const RaytracingGIScene *scene = nullptr;
	Ref<RenderSceneBuffersRD> buffers;
	Transform3D camera;
	float exposure = 0.0f;
	RID shader_version;
	LocalVector<RD::Uniform> uniforms;
	LocalVector<RD::Uniform> material_uniforms;
	RD::BufferReadGroup source_buffer_reads;
	// Borrowed only from context0 in the same synchronous stack-array batch.
	// Never stored in ViewData/BatchData; the owner outlives every replay.
	const RD::BufferReadGroup *shared_source_reads = nullptr;
	bool disable_binding_reuse = false;
	bool validate_bindings = false;
	bool disable_buffer_read_groups = false;
	bool prepared = false;
	uint32_t next_pass = RESERVOIR_RESET;
	Size2i size;
	uint32_t columns = 0;
	uint32_t rows = 0;
	uint32_t probe_count = 0;
	uint32_t mask_levels = 0;
	uint32_t update_count = 0;
	uint32_t ray_count = 0;
	uint32_t cache_buckets = 0;
	uint32_t cache_tiles = 0;
	uint32_t cells = 0;
	bool cache_all_hits = false;
	bool multibounce = false;
	bool denoiser = false;
	bool probe_cache = false;
	bool light_resampling = false;
	float distant_cell_scale = 0.0f;
	float cell_size = 0.0f;
	float probability = 0.0f;
	float max_distance = 0.0f;
	bool reflections = false;
	bool screen_feedback = false;
	uint32_t reflection_stride = 0;
	float reflection_roughness = 0.0f;
	float reflection_trace_roughness = 0.0f;
	float firefly_low = 0.0f;
	float firefly_high = 0.0f;
	bool reflection_compaction = false;
	bool reflection_fireflies = false;
	uint32_t sky_sampling = 0;
	uint32_t reflection_mode = 0;
	uint32_t reflection_radii = 0;
	bool debug_statistics = false;
	uint32_t reflection_filter_passes = 0;
	Size2i reflection_size;
	uint32_t configuration = 0;
	uint32_t improvements = 0;
	Ref<ViewData> data;
	Ref<BatchData> batch_data;
	BatchUniform batch_uniform = {};
	uint32_t proposal_lights = 0;
	uint32_t environment_count = 0;
	bool reset = false;
	FrameUniform frame = {};
	Projection view_projection;
	uint32_t index = 0;
	uint32_t binding_index = 0;
	bool debug_compute_view = false;
	uint32_t debug_bytes = 0;
	bool readback_statistics = false;
	Size2i split_size;
	RID feedback;
	PushConstant push = {};
	bool reflection_capture = false;
	uint32_t reflection_diagnostic_header[16] = {};
	uint32_t proposal_leaves = 0;
};

RID AMDGI::get_render_uniform_set(RenderContext &r_context, uint32_t p_pass, RID p_shader, uint32_t p_set) {
	const LocalVector<RD::Uniform> &uniforms = p_set == 0 ? r_context.uniforms : r_context.material_uniforms;
	if (r_context.disable_binding_reuse) {
		return UniformSetCacheRD::get_singleton()->get_cache_vec(p_shader, p_set, uniforms);
	}
	BindingReuse &reuse = p_set == 0 ? r_context.data->bindings[r_context.binding_index] : r_context.data->material_bindings;
	return reuse.get_uniform_set(p_pass, p_shader, p_set, uniforms, r_context.validate_bindings);
}

Error AMDGI::add_render_source_reads(RenderContext &r_context, RD::ComputeListID p_list) {
	if (r_context.disable_buffer_read_groups) {
		r_context.scene->add_geometry_reads(p_list);
		r_context.scene->get_source_materials().add_buffer_reads(p_list);
		return OK;
	}
	static const bool validate_buffer_read_groups = OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_BUFFER_READ_GROUPS") == "1";
	const Error error = RD::get_singleton()->compute_list_add_buffer_read_group(p_list, r_context.shared_source_reads ? *r_context.shared_source_reads : r_context.source_buffer_reads, validate_buffer_read_groups);
	if (validate_buffer_read_groups && error == OK) {
		static bool reported_validation = false;
		if (!reported_validation) {
			reported_validation = true;
			print_line("AMD GI buffer-read group validation enabled: typed owners match original RID resolution.");
		}
	}
	return error;
}

bool AMDGI::prepare_render_context(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_buffers, RID p_normals, const Projection &p_projection, const Transform3D &p_camera, float p_exposure, const Environment &p_environment, RenderContext &r_context, const Ref<BatchData> &p_batch, const RD::BufferReadGroup *p_shared_source_reads) {
	ERR_FAIL_COND_V(r_context.prepared, false);
	r_context.next_pass = RESERVOIR_RESET;
	if (p_projection.is_orthogonal() || !p_scene.is_ready() || p_normals.is_null() || !has_material_pipelines(p_scene)) {
		return false;
	}
	RD *rd = RD::get_singleton();
	const Size2i size = p_buffers->get_internal_size();
	ensure_sampling_data(size);
	const int requested_stride = GLOBAL_GET("rendering/global_illumination/amd_gi/probe_spacing");
	const uint32_t stride = requested_stride <= 8 ? 8 : (requested_stride <= 16 ? 16 : 32);
	const uint32_t columns = (size.x + 7) / 8;
	const uint32_t rows = (size.y + 7) / 8;
	const uint32_t probe_count = columns * rows;
	uint32_t mask_cells = probe_count;
	uint32_t mask_levels = 1;
	for (uint32_t width = columns, height = rows; width > 1 || height > 1;) {
		width = MAX(width / 2, 1u);
		height = MAX(height / 2, 1u);
		mask_cells += width * height;
		mask_levels++;
	}
	const uint32_t update_columns = (size.x + stride - 1) / stride;
	const uint32_t update_rows = (size.y + stride - 1) / stride;
	const uint32_t update_count = update_columns * update_rows;
	const uint32_t ray_count = update_count * 64;
	const uint32_t cache_buckets = 1u << CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/cache_bucket_exponent")), 8, 14);
	const uint32_t cache_tiles = cache_buckets * 16;
	const uint32_t cells = cache_tiles * CACHE_CELLS_PER_TILE;
	const bool cache_all_hits = GLOBAL_GET("rendering/global_illumination/amd_gi/cache_all_hits");
	const bool multibounce = GLOBAL_GET("rendering/global_illumination/amd_gi/multibounce");
	const bool denoiser = GLOBAL_GET("rendering/global_illumination/amd_gi/denoiser");
	const bool brdf_sampling = GLOBAL_GET("rendering/global_illumination/amd_gi/brdf_sampling");
	const bool importance_sampling = GLOBAL_GET("rendering/global_illumination/amd_gi/importance_sampling");
	const bool adaptive_sampling = GLOBAL_GET("rendering/global_illumination/amd_gi/adaptive_sampling");
	const bool probe_cache = GLOBAL_GET("rendering/global_illumination/amd_gi/probe_cache");
	const bool light_resampling = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/light_resampling"));
	// Range hints only constrain the editor. Enforce bounds for scripts too;
	// nonfinite input restores the reference value rather than reaching shaders.
	const auto bounded_tuning = [](const char *p_name, float p_min, float p_max) {
		const float value = GLOBAL_GET(p_name);
		return Math::is_finite(value) ? CLAMP(value, p_min, p_max) : p_max;
	};
	const float cache_history_updates = Math::round(bounded_tuning("rendering/global_illumination/amd_gi/tuning/cache_history_updates", 12.0f, 16.0f));
	const float denoiser_history_scale = bounded_tuning("rendering/global_illumination/amd_gi/tuning/denoiser_history_scale", 0.75f, 1.0f);
	const float distant_cell_scale = bounded_tuning("rendering/global_illumination/amd_gi/tuning/distant_cell_scale", 0.75f, 1.0f);
	const float cell_size = MAX(float(GLOBAL_GET("rendering/global_illumination/amd_gi/minimum_cell_size")), 0.01f);
	const float probability = CLAMP(float(GLOBAL_GET("rendering/global_illumination/amd_gi/continuation_probability")), 0.05f, 1.0f);
	const float max_distance = MAX(float(GLOBAL_GET("rendering/global_illumination/amd_gi/max_distance")), 1.0f);
	const bool reflections = GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/enabled");
	const bool diffuse_feedback = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/screen_feedback")) && !multibounce;
	// SSGI and reflection-hit reuse always need previous native outgoing radiance.
	const bool screen_feedback = true;
	const uint32_t reflection_stride = reflections ? (bool(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/half_resolution")) ? 2 : 1) : 0;
	const float reflection_roughness = CLAMP(float(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/probe_roughness_threshold")), 0.2f, 1.0f);
	const float reflection_trace_roughness = CLAMP(float(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/trace_roughness_threshold")), 0.0f, reflection_roughness);
	const float firefly_low = CLAMP(float(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/firefly_low_threshold")), 0.0f, 1.0f);
	const float firefly_high = CLAMP(float(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/firefly_high_threshold")), 0.0f, 1.0f);
	const bool reflection_compaction = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/ray_compaction"));
	const bool reflection_fireflies = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/firefly_filter"));
	const uint32_t sky_sampling = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/sky_sampling")), 0, 2);
	const uint32_t reflection_mode = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/denoiser")), 0, 2);
	const char *radius_suffix = reflection_stride == 2 ? "half" : "full";
	const uint32_t split_radius = CLAMP(int(GLOBAL_GET(String("rendering/global_illumination/amd_gi/reflections/split_radius_") + radius_suffix)), 1, 32);
	const uint32_t mark_radius = CLAMP(int(GLOBAL_GET(String("rendering/global_illumination/amd_gi/reflections/firefly_mark_radius_") + radius_suffix)), 0, 16);
	const uint32_t cleanup_radius = CLAMP(int(GLOBAL_GET(String("rendering/global_illumination/amd_gi/reflections/firefly_cleanup_radius_") + radius_suffix)), 0, 16);
	const uint32_t reflection_radii = split_radius | (mark_radius << 8) | (cleanup_radius << 16);
	const uint32_t debug_view = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/view")), 0, 37);
	const bool debug_statistics = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/statistics"));
	const uint32_t reflection_filter_passes = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/filter_passes")), 2, 8);
	const Size2i reflection_size = reflections ? Size2i((size.x + reflection_stride - 1) / reflection_stride, (size.y + reflection_stride - 1) / reflection_stride) : Size2i(1, 1);
	const uint32_t configuration = uint32_t(multibounce) | (uint32_t(denoiser) << 1) | (uint32_t(importance_sampling) << 2) | (uint32_t(adaptive_sampling) << 3) | (uint32_t(bool(GLOBAL_GET("rendering/global_illumination/amd_gi/emissive_sampling"))) << 4) | (uint32_t(reflection_fireflies) << 5) | (uint32_t(brdf_sampling) << 6) | (sky_sampling << 7);
	const bool retain_emitter_history = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/improvements/retain_history_on_emitter_transitions"));
	const uint32_t improvements = uint32_t(bool(GLOBAL_GET("rendering/global_illumination/amd_gi/improvements/responsive_history"))) |
			(uint32_t(bool(GLOBAL_GET("rendering/global_illumination/amd_gi/improvements/demand_scheduling"))) << 1) |
			(uint32_t(bool(GLOBAL_GET("rendering/global_illumination/amd_gi/improvements/cache_transitions"))) << 2) |
			(uint32_t(retain_emitter_history) << 3);
	Ref<ViewData> data;
	if (p_buffers->has_custom_data(RB_SCOPE_AMD_GI)) {
		data = p_buffers->get_custom_data(RB_SCOPE_AMD_GI);
	}
	if (data.is_null()) {
		data.instantiate();
		p_buffers->set_custom_data(RB_SCOPE_AMD_GI, data);
	}
	if (data->world.is_null() || (p_batch.is_valid() && data->world != p_batch->world) || data->batch_screen != regional_batch || data->size != size || data->stride != stride || data->probe_cache != probe_cache || data->light_resampling != light_resampling || data->multibounce != multibounce || data->reflection_stride != reflection_stride || data->screen_feedback != screen_feedback || data->cache_all_hits != cache_all_hits || data->cache_buckets != cache_buckets || data->reflection_mode != reflection_mode || ((data->improvements ^ improvements) & 1u) != 0u) {
		data->free_data();
		if (p_batch.is_valid()) {
			data->world = p_batch->world;
		} else {
			data->world.instantiate();
		}
		data->batch_screen = regional_batch;
		if (regional_batch) {
			data->improvements = improvements;
		}
		p_buffers->clear_context(RB_SCOPE_AMD_GI);
		data->size = size;
		data->stride = stride;
		data->probe_cache = probe_cache;
		data->light_resampling = light_resampling;
		data->multibounce = multibounce;
		data->screen_feedback = screen_feedback;
		data->cache_all_hits = cache_all_hits;
		data->cache_buckets = cache_buckets;
		data->reflection_stride = reflection_stride;
		data->reflection_mode = reflection_mode;
		const uint32_t reflection_bytes = reflections ? reflection_size.x * reflection_size.y * 64 : 16;
		data->reflection_samples = rd->storage_buffer_create(reflection_bytes);
		for (int i = 0; i < 2; i++) {
			data->reflection_history[i] = rd->storage_buffer_create(reflections ? size.x * size.y * 64 : 16);
		}
		data->frame_uniform = rd->uniform_buffer_create(sizeof(FrameUniform) + (regional_batch ? sizeof(BatchUniform) : 0));
		if (diagnostic_source_enabled() || reflection_diagnostic_config().enabled) {
			data->source_validation = rd->storage_buffer_create(reflection_diagnostic_config().enabled ? REFLECTION_DIAGNOSTIC_BYTES : 33 * 16);
		}
		for (int i = 0; i < 2; i++) {
			data->probes[i] = rd->storage_buffer_create(probe_count * 128); // position, normal, SH9, seed/age/update slot
			data->radiance[i] = rd->storage_buffer_create(probe_count * 64 * 8);
			data->pixels[i] = rd->storage_buffer_create(size.x * size.y * 32); // position, R10 normal, half delta and half4 color/count
			if (p_batch.is_valid()) {
				continue; // The logical camera owns cache/reservoir storage.
			}
			if (i == 0) {
				// Packed response metadata is absent on the original AMD path.
				const uint32_t cache_bytes = cells * 8 + ((improvements & 1u) != 0u ? cache_tiles * 88 : 0);
				data->world->cache[i] = rd->storage_buffer_create(cache_bytes);
				data->world->indirect_cache[i] = rd->storage_buffer_create(multibounce ? cache_bytes : 16);
			} else {
				data->world->indirect_cache[i] = rd->storage_buffer_create(multibounce ? cache_tiles * 64 * 16 : 16);
			}
		}
		if (p_batch.is_null()) {
			data->rays = rd->storage_buffer_create(ray_count * AMD_GI_RAY_BYTES);
		}
		if (p_batch.is_null()) {
			data->secondary_rays = rd->storage_buffer_create(multibounce ? ray_count * AMD_GI_RAY_BYTES : 16);
		}
		if (p_batch.is_null()) {
			data->world->keys = rd->storage_buffer_create(48 + cache_tiles * 2 * 32, Vector<uint8_t>(), RD::STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT);
		}
		if (p_batch.is_null()) {
			data->world->owners = rd->storage_buffer_create(cells * 4 * (cache_all_hits && diagnostic_hits_enabled() ? 2 : 1));
		}
		if (p_batch.is_null()) {
			data->world->direct_updates = rd->storage_buffer_create(cache_all_hits ? cache_tiles * 64u * 16u : 16u);
		}
		if (p_batch.is_null()) {
			data->hit_samples = rd->storage_buffer_create(cache_all_hits ? ray_count * (multibounce ? 2 : 1) * 48 : 16);
		}
		data->scratch = rd->storage_buffer_create(probe_count * 64 * 8);
		data->spawn = rd->storage_buffer_create(update_count * 16);
		data->work = rd->storage_buffer_create(80 + (cache_all_hits ? ray_count * (multibounce ? 2 : 1) * 4 : 0), {}, RD::STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT);
		// Reuse one storage binding; the appended reflection queue does not
		// overwrite diffuse/LRU queues used by validation after the dispatches.
		data->queues = rd->storage_buffer_create(16 + (probe_count * 3 + update_count * 2 + (reflections ? 4 + reflection_size.x * reflection_size.y : 0)) * 4, Vector<uint8_t>(), RD::STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT);
		data->probe_mask = rd->storage_buffer_create(mask_cells * 4);
		// Disabled cache variants bind tiny valid placeholders; no cache pass
		// or conditional access runs against them.
		data->cached_probes = rd->storage_buffer_create(probe_cache ? (probe_count + update_count) * (128 + 64 * 8) : 16);
		data->cached_state = rd->storage_buffer_create(probe_cache ? probe_count * 16 : 16);
		for (int i = 0; i < 2; i++) {
			data->cached_order[i] = rd->storage_buffer_create(probe_cache ? probe_count * 4 : 4);
			if (p_batch.is_null()) {
				data->world->light_reservoirs[i] = rd->storage_buffer_create(light_resampling ? reservoir_buffer_bytes(ray_count * (multibounce ? 2 : 1)) : 16);
			}
		}
	}
	const uint32_t proposal_lights = p_scene.get_light_count() + p_scene.get_emitter_count() + 1;
	if (!data->world->ensure_light_grid(p_scene.get_emitter_count(), proposal_lights)) {
		data->valid = false;
		return false;
	}
	const uint32_t environment_count = p_environment.radiance.is_valid() ? 1u : 0u;
	const WorldData::LightHistoryAction light_history = p_batch.is_valid() ? WorldData::LightHistoryAction::KEEP : data->world->update_light_order(p_scene, environment_count, retain_emitter_history, light_resampling);
	const bool light_settings_changed = light_history == WorldData::LightHistoryAction::RESET_VIEW;
	const bool configuration_changed = data->configuration != configuration || data->cell_size != cell_size || data->distant_cell_scale != distant_cell_scale || data->continuation != probability || data->max_distance != max_distance || data->reflection_roughness != reflection_roughness || data->reflection_filter_passes != reflection_filter_passes || data->reflection_trace_roughness != reflection_trace_roughness || data->firefly_low != firefly_low || data->firefly_high != firefly_high || data->reflection_radii != reflection_radii;
	const bool reset = !data->valid || configuration_changed || light_settings_changed || data->improvements != improvements;
	static const bool trace_history = !OS::get_singleton()->get_environment("GODOT_AMD_GI_TRACE_HISTORY").is_empty();
	if (trace_history && reset) {
		print_line(vformat("AMD GI reset reasons: frame=%d invalid=%s configuration=%s light_settings=%s", data->frame, !data->valid, configuration_changed, light_settings_changed));
	}
	FrameUniform frame = {};
	frame.tuning[0] = cache_history_updates;
	frame.tuning[1] = denoiser_history_scale;
	frame.tuning[2] = distant_cell_scale;
	frame.options[2] = improvements;
	frame.options[3] = light_history == WorldData::LightHistoryAction::RESET_RESERVOIRS;
	frame.options[0] = sky_sampling;
	frame.options[1] = reflections;
	frame.reflection_options[0] = reflection_mode;
	frame.reflection_options[1] = split_radius;
	frame.reflection_options[2] = mark_radius;
	frame.reflection_options[3] = cleanup_radius;
	frame.debug_options[0] = debug_view;
	frame.debug_options[1] = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/mip")), 0, 3);
	frame.debug_options[2] = uint32_t(debug_statistics || debug_view == 17) | (uint32_t(bool(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/indirect_cache"))) << 1);
	frame.debug_options[3] = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/max_age")), 0, 1000);
	frame.debug_settings[0] = CLAMP(float(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/exposure")), -16.0f, 16.0f);
	frame.debug_settings[1] = CLAMP(float(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/sample_scale")), 1.0f, 1000.0f);
	frame.debug_settings[2] = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/atlas_page")), 0, 65535);
	frame.cache_config[0] = cache_buckets;
	frame.cache_config[1] = 16;
	for (int axis = 0; axis < 3; axis++) {
		frame.previous_eye[axis] = data->previous_camera.origin[axis];
		frame.previous_forward[axis] = -data->previous_camera.basis.get_column(2)[axis];
	}
	frame.near_field[0] = 0.1f * MAX(Math::abs(p_projection.columns[0][0]), Math::abs(p_projection.columns[1][1]));
	frame.near_field[1] = SIGN(p_projection.columns[0][0]);
	frame.near_field[2] = SIGN(p_projection.columns[1][1]);
	frame.near_field[3] = p_environment.auto_exposure.is_valid();
	frame.glossy[0] = reflection_trace_roughness;
	frame.glossy[1] = firefly_low;
	frame.glossy[2] = firefly_high;
	frame.glossy[3] = p_environment.temporal_exposure_scale;
	frame.emitters[0] = p_scene.get_emitter_count();
	frame.emitters[1] = p_scene.get_emitter_buffer_offset() / 16u; // Physical uvec4 offset; logical light IDs stay dense.
	frame.emitters[2] = probe_count * 3 + update_count * 2;
	frame.emitters[3] = reflection_compaction && reflections;
	frame.motion[0] = p_scene.get_motion_bounds().size();
	frame.motion[1] = cache_all_hits;
	frame.motion[2] = diffuse_feedback;
	frame.motion[3] = 0;
	if (trace_history && frame.motion[0]) {
		print_line(vformat("AMD GI dirty regions: frame=%d count=%d", data->frame, frame.motion[0]));
	}
	MaterialStorage::store_camera(data->previous_view_projection, frame.previous_view_projection);
	MaterialStorage::store_camera(data->previous_view_projection.inverse(), frame.previous_inverse_view_projection);
	const Projection view_projection = p_projection * Projection(p_camera.affine_inverse());
	MaterialStorage::store_camera(view_projection, frame.view_projection);
	frame.grid[0] = columns;
	frame.grid[1] = rows;
	frame.grid[2] = stride;
	frame.grid[3] = reset;
	frame.settings[0] = cell_size;
	// GI-1's angular footprint also handles portrait aspect ratios.
	const float fov_y = 2.0f * Math::atan(1.0f / Math::abs(p_projection.columns[1][1]));
	frame.settings[1] = fov_y * MAX(1.0f / size.y, float(size.y) / (float(size.x) * size.x));
	frame.settings[2] = probability;
	frame.settings[3] = screen_feedback ? data->previous_exposure : 0.0f;
	frame.flags[0] = denoiser;
	frame.flags[1] = importance_sampling;
	frame.flags[2] = mask_levels;
	frame.flags[3] = probe_cache;
	frame.tracing[0] = update_columns;
	frame.tracing[1] = update_rows;
	frame.tracing[2] = adaptive_sampling;
	frame.tracing[3] = light_resampling;
	MaterialStorage::store_transform_3x3(p_environment.world_to_sky, frame.world_to_sky);
	frame.sky[0] = p_environment.diffuse_energy;
	frame.sky[1] = p_environment.reflection_energy;
	frame.sky[2] = p_environment.border;
	// Packed small option flags, represented exactly in this unused float lane.
	frame.sky[3] = uint32_t(reflection_fireflies) | (uint32_t(brdf_sampling) << 1) | (environment_count << 2);
	frame.reflections[0] = MAX(reflection_stride, 1u);
	frame.reflections[1] = reflection_roughness;
	frame.reflections[2] = reflection_filter_passes;
	static const bool validate_feedback = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_FEEDBACK").is_empty();
	frame.reflections[3] = validate_feedback ? 1.0f : 0.0f;
	for (int i = 0; i < 4; i++) {
		frame.ambient[i] = p_environment.ambient[i];
	}
	rd->buffer_update(data->frame_uniform, 0, sizeof(frame), &frame);
	const uint32_t index = data->index;
	const uint32_t usage = RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT;
	RID output = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("diffuse"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage);
	const bool debug_compute_view = debug_view != 0 && debug_view != 1 && !(debug_view >= 18 && debug_view <= 21);
	if (!debug_compute_view) {
		p_buffers->clear_context(SNAME("amd_gi_debug"));
	}
	RID debug_output = p_buffers->create_texture(debug_compute_view ? SNAME("amd_gi_debug") : RB_SCOPE_AMD_GI, debug_compute_view ? SNAME("debug_output") : SNAME("debug_placeholder"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage, RD::TEXTURE_SAMPLES_1, debug_compute_view ? size : Size2i(1, 1));
	const uint32_t debug_bytes = (debug_statistics || debug_view == 17) ? (16 + cache_buckets + 2 * 17) * sizeof(uint32_t) : 16;
	if (data->debug_stats_bytes != debug_bytes) {
		if (data->debug_stats.is_valid()) {
			rd->free_rid(data->debug_stats);
		}
		data->debug_stats = rd->storage_buffer_create(debug_bytes);
		data->debug_stats_bytes = debug_bytes;
		data->diagnostics.clear();
	}
	if (debug_statistics || debug_view == 17) {
		rd->buffer_clear(data->debug_stats, 0, debug_bytes);
	}
	const uint32_t readback_interval = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/readback_interval")), 1, 3600);
	const bool readback_statistics = debug_statistics && (data->frame % readback_interval == 0 || !data->diagnostics.has("gpu"));
	RID blur_mask = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("blur_mask"), RD::DATA_FORMAT_R8_SNORM, usage);
	RID intermediate = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("filter"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage);
	RID reflection_output = p_buffers->create_texture(RB_SCOPE_AMD_GI, reflections ? SNAME("reflection") : SNAME("reflection_placeholder"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage, RD::TEXTURE_SAMPLES_1, reflections ? size : Size2i(1, 1));
	const Size2i split_size = reflections && reflection_mode == 0 ? Size2i(size.x, reflection_size.y) : reflection_size;
	RID reflection_filter_a = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("reflection_filter_a"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage, RD::TEXTURE_SAMPLES_1, split_size);
	RID reflection_filter_b = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("reflection_filter_b"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage, RD::TEXTURE_SAMPLES_1, reflection_size);
	RID reflection_moments_a = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("reflection_moments_a"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage, RD::TEXTURE_SAMPLES_1, split_size);
	RID reflection_moments_b = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("reflection_moments_b"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage, RD::TEXTURE_SAMPLES_1, reflection_size);
	RID near_field_occlusion = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("near_field_occlusion"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage);
	RID near_field_lighting = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("near_field_lighting"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage);
	RID history_geometry = p_buffers->create_texture(RB_SCOPE_AMD_GI, index == 0 ? SNAME("geometry_history_0") : SNAME("geometry_history_1"), RD::DATA_FORMAT_A2B10G10R10_UNORM_PACK32, usage);
	RID previous_geometry = p_buffers->create_texture(RB_SCOPE_AMD_GI, index == 0 ? SNAME("geometry_history_1") : SNAME("geometry_history_0"), RD::DATA_FORMAT_A2B10G10R10_UNORM_PACK32, usage);
	RID feedback = screen_feedback ? p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("feedback"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT) : TextureStorage::get_singleton()->texture_rd_get_default(TextureStorage::DEFAULT_RD_TEXTURE_BLACK);
	RID sampler = MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	LocalVector<RD::Uniform> uniforms;
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 64, debug_output));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 65, data->debug_stats));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 67, Vector<RID>{ sampler, reflection_output }));
	p_scene.append_uniforms(uniforms, sampler);
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>{ sampler, p_buffers->get_depth_texture() }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>{ sampler, p_normals }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 3, output));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 10, data->frame_uniform));
	const RID storage[] = { data->probes[index], data->probes[1 - index], (p_batch.is_valid() ? p_batch->rays : data->rays), data->radiance[index], data->radiance[1 - index], data->world->keys, data->world->cache[0], data->world->cache[0], data->world->owners, data->scratch, data->pixels[1 - index], data->pixels[index] };
	for (uint32_t i = 0; i < 12; i++) {
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 11 + i, storage[i]));
	}
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 23, intermediate));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 24, data->spawn));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 25, data->queues));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 26, data->probe_mask));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 27, data->cached_probes));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 28, data->cached_state));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 29, data->cached_order[1 - index]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 30, data->cached_order[index]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 31, blue_noise));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 32, data->world->light_reservoirs[1 - (p_batch.is_valid() ? p_batch->reservoir_index : index)]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 33, data->world->light_reservoirs[p_batch.is_valid() ? p_batch->reservoir_index : index]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 34, data->world->indirect_cache[1]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 35, data->world->indirect_cache[0]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 36, p_batch.is_valid() ? p_batch->secondary_rays : data->secondary_rays));
	RID sky_texture = prepare_environment(*data->world.ptr(), p_environment);
	RID sky_sampler = MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 37, Vector<RID>{ sky_sampler, sky_texture }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 38, data->reflection_samples));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 39, data->reflection_history[1 - index]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 40, data->reflection_history[index]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 41, reflection_filter_a));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 42, reflection_filter_b));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 43, reflection_output));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 44, data->world->light_grid));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 45, Vector<RID>{ sampler, feedback }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 46, p_batch.is_valid() ? p_batch->hit_samples : data->hit_samples));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 48, Vector<RID>{ sampler, p_buffers->get_texture(RB_SCOPE_AMD_GI_GEOMETRY, SNAME("previous_position")) }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 49, blur_mask));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 50, reflection_moments_a));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 51, reflection_moments_b));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 52, Vector<RID>{ sampler, p_buffers->get_texture(RB_SCOPE_AMD_GI_GEOMETRY, SNAME("geometry_normal")) }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 53, Vector<RID>{ sampler, p_buffers->get_texture(RB_SCOPE_AMD_GI_GEOMETRY, SNAME("primary_material")) }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 54, history_geometry));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 55, Vector<RID>{ sampler, previous_geometry }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 56, near_field_occlusion));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 57, near_field_lighting));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 59, data->work));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 62, data->world->direct_updates));
	if (diagnostic_source_enabled() || reflection_diagnostic_config().enabled) {
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 63, data->source_validation));
	}
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 60, Vector<RID>{ sampler, p_buffers->get_texture(RB_SCOPE_AMD_GI_GEOMETRY, SNAME("shading_normal")) }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 61, Vector<RID>{ sampler, p_buffers->get_texture(RB_SCOPE_AMD_GI_GEOMETRY, SNAME("roughness")) }));
	const RID exposure_texture = p_environment.auto_exposure.is_valid() ? p_environment.auto_exposure : TextureStorage::get_singleton()->texture_rd_get_default(TextureStorage::DEFAULT_RD_TEXTURE_WHITE);
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 58, Vector<RID>{ sampler, exposure_texture }));
	LocalVector<RD::Uniform> material_uniforms;
	p_scene.get_source_materials().append_uniforms(material_uniforms);
	static const bool disable_binding_reuse = OS::get_singleton()->get_environment("GODOT_AMD_GI_DISABLE_BINDING_REUSE") == "1";
	static const bool validate_bindings = OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_BINDINGS") == "1";
	if (!disable_binding_reuse) {
		// Shader versions are published atomically after complete preparation.
		// Their full RID identity also covers same-layout shader replacements.
		if (data->binding_version != version) {
			for (BindingReuse &binding : data->bindings) {
				binding.clear();
			}
			data->material_bindings.clear();
			data->binding_version = version;
		}
		if (p_batch.is_null()) {
			data->bindings[index].update(uniforms);
		}
		data->material_bindings.update(material_uniforms);
	}
	PushConstant push = {};
	MaterialStorage::store_camera(view_projection.inverse(), push.inv_view_projection);
	const Quaternion rotation = p_camera.basis.get_rotation_quaternion();
	push.camera_rotation[0] = rotation.x;
	push.camera_rotation[1] = rotation.y;
	push.camera_rotation[2] = rotation.z;
	push.camera_rotation[3] = rotation.w;
	for (int axis = 0; axis < 3; axis++) {
		push.camera_position[axis] = p_camera.origin[axis];
	}
	push.size[0] = size.x;
	push.size[1] = size.y;
	push.multibounce = multibounce;
	push.max_distance = max_distance;
	push.light_count = p_scene.get_light_count();
	push.exposure = p_exposure;
	// Capsaicin reserves UINT_MAX for startup and never wraps back to frame
	// zero (which denotes a new history lifetime).
	if (data->frame == UINT32_MAX) {
		data->frame = 1;
	}
	push.frame = p_batch.is_valid() ? p_batch->frame : data->frame++;
	const ReflectionDiagnosticConfig &reflection_diagnostic = reflection_diagnostic_config();
	const bool reflection_capture = reflection_diagnostic.enabled && reflections && reflection_compaction && push.frame >= reflection_diagnostic.first && push.frame - reflection_diagnostic.first < reflection_diagnostic.count;
	uint32_t reflection_diagnostic_header[16] = {};
	if (reflection_diagnostic.enabled) {
		// Normalized output coordinates map to internal pixels, including DLSS scaling.
		const Rect2 &roi = reflection_diagnostic.roi;
		const Vector2 center = roi.get_center();
		const uint32_t width = MIN(32u, MAX(1u, uint32_t(size.x * roi.size.x)));
		const uint32_t height = MIN(80u, MAX(1u, uint32_t(size.y * roi.size.y)));
		reflection_diagnostic_header[0] = uint32_t(CLAMP(int32_t(size.x * center.x) - int32_t(width / 2), 0, size.x - int32_t(width)));
		reflection_diagnostic_header[1] = uint32_t(CLAMP(int32_t(size.y * center.y) - int32_t(height / 2), 0, size.y - int32_t(height)));
		reflection_diagnostic_header[2] = width;
		reflection_diagnostic_header[3] = height;
		reflection_diagnostic_header[4] = reflection_capture;
		reflection_diagnostic_header[5] = push.frame;
		reflection_diagnostic_header[6] = size.x;
		reflection_diagnostic_header[7] = size.y;
		reflection_diagnostic_header[8] = reflection_stride;
		reflection_diagnostic_header[9] = reset;
		reflection_diagnostic_header[10] = reflection_mode != 2;
		reflection_diagnostic_header[11] = 2; // Layout version.
		if (reflection_capture) {
			rd->buffer_clear(data->source_validation, 0, REFLECTION_DIAGNOSTIC_BYTES);
		}
		rd->buffer_update(data->source_validation, 33 * 16, sizeof(reflection_diagnostic_header), reflection_diagnostic_header);
		WARN_PRINT_ONCE("Reflection diagnostics synchronously read GPU data during the selected frames; do not use these frames for performance measurements. Compaction must be enabled.");
	}
	const uint32_t proposal_strata = MIN(64u, MAX(proposal_lights, 1u));
	const uint32_t proposal_leaves = (proposal_lights + proposal_strata * 64 - 1) / (proposal_strata * 64);
	const uint32_t proposal_tops = (proposal_leaves + 63) / 64;
	if (p_batch.is_null()) {
		rd->buffer_clear(data->world->light_grid, 32 + (16 * 16 * 16 * 64 + p_scene.get_emitter_count()) * 16, (proposal_leaves + proposal_tops) * 64 * 16);
	}
	static const bool disable_buffer_read_groups = OS::get_singleton()->get_environment("GODOT_AMD_GI_DISABLE_BUFFER_READ_GROUPS") == "1";
	RD::BufferReadGroup source_buffer_reads;
	if (!disable_buffer_read_groups && !p_shared_source_reads) {
		// Source preparation has finished. Collect once for this render call;
		// each pass still declares reads using the buffers' current trackers.
		LocalVector<RID> buffers;
		p_scene.append_geometry_buffer_reads(buffers);
		p_scene.get_source_materials().append_buffer_reads(buffers);
		if (rd->buffer_read_group_prepare(source_buffer_reads, buffers) != OK) {
			data->valid = false;
			ERR_FAIL_V(false);
		}
	}
	r_context.scene = &p_scene;
	r_context.buffers = p_buffers;
	r_context.camera = p_camera;
	r_context.exposure = p_exposure;
	r_context.shader_version = version;
	r_context.uniforms = std::move(uniforms);
	r_context.material_uniforms = std::move(material_uniforms);
	r_context.source_buffer_reads = std::move(source_buffer_reads);
	r_context.shared_source_reads = p_shared_source_reads;
	r_context.disable_binding_reuse = disable_binding_reuse;
	r_context.validate_bindings = validate_bindings;
	r_context.disable_buffer_read_groups = disable_buffer_read_groups;
	r_context.size = size;
	r_context.columns = columns;
	r_context.rows = rows;
	r_context.probe_count = probe_count;
	r_context.mask_levels = mask_levels;
	r_context.update_count = update_count;
	r_context.ray_count = ray_count;
	r_context.cache_buckets = cache_buckets;
	r_context.cache_tiles = cache_tiles;
	r_context.cells = cells;
	r_context.cache_all_hits = cache_all_hits;
	r_context.multibounce = multibounce;
	r_context.denoiser = denoiser;
	r_context.probe_cache = probe_cache;
	r_context.light_resampling = light_resampling;
	r_context.distant_cell_scale = distant_cell_scale;
	r_context.cell_size = cell_size;
	r_context.probability = probability;
	r_context.max_distance = max_distance;
	r_context.reflections = reflections;
	r_context.screen_feedback = screen_feedback;
	r_context.reflection_stride = reflection_stride;
	r_context.reflection_roughness = reflection_roughness;
	r_context.reflection_trace_roughness = reflection_trace_roughness;
	r_context.firefly_low = firefly_low;
	r_context.firefly_high = firefly_high;
	r_context.reflection_compaction = reflection_compaction;
	r_context.reflection_fireflies = reflection_fireflies;
	r_context.sky_sampling = sky_sampling;
	r_context.reflection_mode = reflection_mode;
	r_context.reflection_radii = reflection_radii;
	r_context.debug_statistics = debug_statistics;
	r_context.reflection_filter_passes = reflection_filter_passes;
	r_context.reflection_size = reflection_size;
	r_context.configuration = configuration;
	r_context.improvements = improvements;
	r_context.data = data;
	r_context.batch_data = p_batch;
	r_context.proposal_lights = proposal_lights;
	r_context.environment_count = environment_count;
	r_context.reset = reset;
	r_context.frame = frame;
	r_context.view_projection = view_projection;
	r_context.index = index;
	r_context.binding_index = index + (p_batch.is_valid() ? 2 * p_batch->reservoir_index : 0);
	r_context.debug_compute_view = debug_compute_view;
	r_context.debug_bytes = debug_bytes;
	r_context.readback_statistics = readback_statistics;
	r_context.split_size = split_size;
	r_context.feedback = feedback;
	r_context.push = push;
	r_context.reflection_capture = reflection_capture;
	memcpy(r_context.reflection_diagnostic_header, reflection_diagnostic_header, sizeof(reflection_diagnostic_header));
	r_context.proposal_leaves = proposal_leaves;
	r_context.prepared = true;
	return true;
}

bool AMDGI::dispatch_render_passes(RenderContext &r_context, uint32_t p_first_pass, uint32_t p_end_pass, bool p_debug_passes) {
	ERR_FAIL_COND_V(!r_context.prepared || r_context.shader_version != version, false);
	ERR_FAIL_COND_V((!regional_batch && p_first_pass != r_context.next_pass) || p_first_pass > p_end_pass || p_end_pass > uint32_t(regional_batch ? PASS_COUNT : PREPARE_LIGHTS), false);
	ERR_FAIL_COND_V(p_debug_passes && p_end_pass != PREPARE_LIGHTS, false);
	RD *rd = RD::get_singleton();
	const auto &size = r_context.size;
	const auto &columns = r_context.columns;
	const auto &rows = r_context.rows;
	const auto &probe_count = r_context.probe_count;
	const auto &mask_levels = r_context.mask_levels;
	const auto &update_count = r_context.update_count;
	const auto &ray_count = r_context.ray_count;
	const auto &cache_buckets = r_context.cache_buckets;
	const auto &cache_tiles = r_context.cache_tiles;
	const auto &cache_all_hits = r_context.cache_all_hits;
	const auto &multibounce = r_context.multibounce;
	const auto &probe_cache = r_context.probe_cache;
	const auto &light_resampling = r_context.light_resampling;
	const auto &reflections = r_context.reflections;
	const auto &reflection_compaction = r_context.reflection_compaction;
	const auto &reflection_fireflies = r_context.reflection_fireflies;
	const auto &reflection_mode = r_context.reflection_mode;
	const auto &reflection_filter_passes = r_context.reflection_filter_passes;
	const auto &reflection_size = r_context.reflection_size;
	const auto &data = r_context.data;
	const auto &proposal_lights = r_context.proposal_lights;
	const auto &reset = r_context.reset;
	const auto &frame = r_context.frame;
	const auto &debug_compute_view = r_context.debug_compute_view;
	const auto &readback_statistics = r_context.readback_statistics;
	const auto &split_size = r_context.split_size;
	auto &push = r_context.push;
	const auto &proposal_leaves = r_context.proposal_leaves;
	const RID world_work = r_context.batch_data.is_valid() ? r_context.batch_data->work : data->work;
	const uint32_t world_ray_capacity = r_context.batch_data.is_valid() ? r_context.batch_data->capacity : ray_count;
	// Pass boundaries are explicit: no dispatch reads concurrently written radiance.
	RD::ComputeListID list = rd->compute_list_begin();
	for (uint32_t pass = p_first_pass; pass < p_end_pass; pass++) {
		if (pass == LIGHT_GRID_DISPATCH) {
			for (uint32_t preparation : { uint32_t(PREPARE_LIGHTS), uint32_t(PREPARE_LIGHT_MASKS) }) {
				RID preparation_shader = shader.version_get_shader(version, preparation);
				RID set = get_render_uniform_set(r_context, preparation, preparation_shader, 0);
				RID materials = get_render_uniform_set(r_context, preparation, preparation_shader, 1);
				if (set.is_null() || materials.is_null()) {
					rd->compute_list_end();
					data->valid = false;
					ERR_FAIL_V(false);
				}
				rd->compute_list_bind_compute_pipeline(list, pipelines[preparation]);
				rd->compute_list_bind_uniform_set(list, set, 0);
				rd->compute_list_bind_uniform_set(list, materials, 1);
				if (add_render_source_reads(r_context, list) != OK) {
					rd->compute_list_end();
					data->valid = false;
					ERR_FAIL_V(false);
				}
				rd->compute_list_set_push_constant(list, &push, sizeof(push));
				uint32_t groups = preparation == PREPARE_LIGHTS ? (proposal_lights + 63) / 64 : proposal_leaves;
				uint32_t dispatch_columns = MIN(MAX(groups, 1u), 1024u);
				rd->compute_list_dispatch(list, dispatch_columns, (MAX(groups, 1u) + dispatch_columns - 1) / dispatch_columns, 1);
				rd->compute_list_add_barrier(list);
			}
		}
		if (pass == VALIDATE_SOURCE) {
			if (diagnostic_source_enabled()) {
				RID pass_shader = shader.version_get_shader(version, pass);
				RID set = get_render_uniform_set(r_context, pass, pass_shader, 0);
				RID material_set = get_render_uniform_set(r_context, pass, pass_shader, 1);
				if (set.is_null() || material_set.is_null()) {
					rd->compute_list_end();
					data->valid = false;
					ERR_FAIL_V(false);
				}
				rd->compute_list_bind_compute_pipeline(list, pipelines[pass]);
				rd->compute_list_bind_uniform_set(list, set, 0);
				rd->compute_list_bind_uniform_set(list, material_set, 1);
				if (add_render_source_reads(r_context, list) != OK) {
					rd->compute_list_end();
					data->valid = false;
					ERR_FAIL_V(false);
				}
				rd->compute_list_set_push_constant(list, &push, sizeof(push));
				rd->compute_list_dispatch(list, 1, 1, 1);
			}
			continue;
		}
		if (!light_resampling && (pass == RESERVOIR_RESET || (pass >= RESERVOIR_SCAN && pass <= RESERVOIR_COMPACT))) {
			continue;
		}
		if (!reflection_compaction && (pass == REFLECTION_CLASSIFY || pass == REFLECTION_BUILD_DISPATCH)) {
			continue;
		}
		if (!reflection_fireflies && (pass == REFLECTION_MARK_FIREFLIES || pass == REFLECTION_CLEAN_FIREFLIES)) {
			continue;
		}
		if ((!reflections && pass >= REFLECTION_CLASSIFY && pass <= REFLECTION_OUTPUT) || (reflection_mode == 2 && pass >= REFLECTION_FIRST && pass <= REFLECTION_TEMPORAL)) {
			continue;
		}
		if (!multibounce && ((pass >= POPULATE && pass <= REGISTER_SECONDARY) || (pass >= UPDATE_INDIRECT && pass <= SHADE_INDIRECT_HITS))) {
			continue;
		}
		if (!cache_all_hits && pass == SHADE_HITS) {
			continue;
		}
		if (!probe_cache && (pass == BIN_CACHED || pass == ORDER_CACHED || pass == STORE_CACHED)) {
			continue;
		}
		// Cache bindings against the selected variant's reflected resources.
		RID pass_shader = shader.version_get_shader(version, pass);
		RID set = get_render_uniform_set(r_context, pass, pass_shader, 0);
		RID material_set = get_render_uniform_set(r_context, pass, pass_shader, 1);
		if (set.is_null() || material_set.is_null()) {
			rd->compute_list_end();
			data->valid = false;
			ERR_FAIL_V(false);
		}
		rd->compute_list_bind_compute_pipeline(list, pipelines[pass]);
		rd->compute_list_bind_uniform_set(list, set, 0);
		rd->compute_list_bind_uniform_set(list, material_set, 1);
		if (pass == LIGHT_GRID || pass == TRACE || pass == POPULATE || pass == SHADE_HITS || pass == UPDATE || pass == SHADE_INDIRECT_HITS || pass == RESOLVE || pass == REFLECTION_TRACE) {
			if (add_render_source_reads(r_context, list) != OK) {
				rd->compute_list_end();
				data->valid = false;
				ERR_FAIL_V(false);
			}
		}
		if (pass == SHADE_HITS || (pass == RESERVOIR_COMPACT && cache_all_hits)) {
			// GenerateReservoirs precedes GenerateMultibounceReservoirs. Keep
			// the compacted shadow-ray RNG domain ordered across the handoff.
			for (uint32_t bounce = 0; bounce < (multibounce ? 2u : 1u); bounce++) {
				push.samples = bounce;
				if (pass == SHADE_HITS) {
					if (add_render_source_reads(r_context, list) != OK) {
						rd->compute_list_end();
						data->valid = false;
						ERR_FAIL_V(false);
					}
				}
				rd->compute_list_set_push_constant(list, &push, sizeof(push));
				rd->compute_list_dispatch_indirect(list, world_work, 32 + bounce * 16);
				rd->compute_list_add_barrier(list);
			}
			push.samples = 0;
			continue;
		}
		if (pass == REFLECTION_ITER) {
			if (reflection_mode != 1) {
				continue;
			}
			for (uint32_t iteration = 1; iteration + 1 < reflection_filter_passes; iteration++) {
				push.samples = iteration;
				rd->compute_list_set_push_constant(list, &push, sizeof(push));
				rd->compute_list_dispatch_threads(list, reflection_size.x, reflection_size.y, 1);
				rd->compute_list_add_barrier(list);
			}
			push.samples = 0;
			continue;
		}
		if (pass == MASK) {
			uint32_t width = columns, height = rows;
			for (uint32_t mip = 1; mip < mask_levels; mip++) {
				width = MAX(width / 2, 1u);
				height = MAX(height / 2, 1u);
				push.samples = mip;
				rd->compute_list_set_push_constant(list, &push, sizeof(push));
				rd->compute_list_dispatch_threads(list, width, height, 1);
				rd->compute_list_add_barrier(list);
			}
			push.samples = 0;
			continue;
		}
		rd->compute_list_set_push_constant(list, &push, sizeof(push));
		if (pass == BATCH_JOIN) {
			const uint32_t count = push.samples == 0 && r_context.batch_uniform.info[3] ? cache_tiles : 1u;
			rd->compute_list_dispatch(list, (count + 63) / 64, 1, 1);
		} else if (pass == LIGHT_GRID_DISPATCH) {
			rd->compute_list_dispatch(list, 1, 1, 1);
		} else if (pass == LIGHT_GRID) {
			rd->compute_list_dispatch_indirect(list, world_work, 64);

		} else if (pass == RESERVOIR_RESET || pass == RESERVOIR_COMPACT) {
			uint32_t count = world_ray_capacity * (multibounce ? 2 : 1);
			if (pass == RESERVOIR_RESET) {
				count = MAX(count, RESERVOIR_ENTRIES);
			}
			uint32_t groups = (count + 63) / 64;
			uint32_t group_columns = MIN(groups, 1024u);
			rd->compute_list_dispatch(list, group_columns, (groups + group_columns - 1) / group_columns, 1);
		} else if (pass >= RESERVOIR_SCAN && pass <= RESERVOIR_SCAN_TOP) {
			uint32_t groups = pass == RESERVOIR_SCAN ? RESERVOIR_BLOCKS : (pass == RESERVOIR_SCAN_BLOCKS ? RESERVOIR_TOP_BLOCKS : 1);
			rd->compute_list_dispatch(list, groups, 1, 1);
		} else if (pass == REFLECTION_TRACE && reflection_compaction) {
			rd->compute_list_dispatch_indirect(list, data->queues, 16 + frame.emitters[2] * 4);
		} else if (pass == REFLECTION_BUILD_DISPATCH || pass == ORDER_CACHED || pass == COMPACT_PROBES) {
			rd->compute_list_dispatch(list, 1, 1, 1);
		} else if (pass == BIN_CACHED) {
			rd->compute_list_dispatch(list, (probe_count + 63) / 64, 1, 1);
		} else if (pass == STORE_CACHED) {
			rd->compute_list_dispatch(list, MIN(probe_count, 65535u), (probe_count + 65534u) / 65535u, 1);
		} else if (pass == REFLECTION_FIRST && reflection_mode == 0) {
			rd->compute_list_dispatch_threads(list, split_size.x, split_size.y, 1);
		} else if (pass >= REFLECTION_CLASSIFY && pass < REFLECTION_LAST) {
			rd->compute_list_dispatch_threads(list, reflection_size.x, reflection_size.y, 1);
		} else if (pass >= NEAR_FIELD) {
			rd->compute_list_dispatch_threads(list, size.x, size.y, 1);
		} else if ((pass == SHADE_INDIRECT_HITS || pass == POPULATE) && cache_all_hits) {
			rd->compute_list_dispatch_indirect(list, world_work, 32);
		} else if (pass == SHADE_INDIRECT_HITS) {
			if (regional_batch) {
				rd->compute_list_dispatch_indirect(list, world_work, 16);
			} else {
				rd->compute_list_dispatch(list, (ray_count + 63) / 64, 1, 1);
			}
		} else if (pass == UPDATE || pass == POPULATE || pass == UPDATE_INDIRECT) {
			rd->compute_list_dispatch_indirect(list, data->world->keys, 0);
		} else if (pass == PURGE) {
			rd->compute_list_dispatch_indirect(list, data->world->keys, 16);
		} else if (pass == RESET) {
			rd->compute_list_dispatch(list, (MAX(reset && !regional_batch ? cache_tiles : 1u, probe_count) + 63) / 64, 1, 1);
		} else if ((pass >= MIP1 && pass <= MIP3) || (pass >= INDIRECT_MIP1 && pass <= INDIRECT_MIP3)) {
			rd->compute_list_dispatch_indirect(list, data->world->keys, 0);
		} else if (pass == PATCH) {
			rd->compute_list_dispatch(list, probe_count, 1, 1);
		} else if (regional_batch && (pass == ALLOCATE || pass == REGISTER || pass == ALLOCATE_SECONDARY || pass == REGISTER_SECONDARY)) {
			rd->compute_list_dispatch_indirect(list, world_work, 16);
		} else if (pass == PREPARE || pass == ALLOCATE || pass == REGISTER || pass == ALLOCATE_SECONDARY || pass == REGISTER_SECONDARY || pass == RESOLVE || (regional_batch && pass == TRACE)) {
			rd->compute_list_dispatch_indirect(list, data->work, 16);
		} else if (pass == SELECT || pass == GATHER_PROBES || pass == TRACE) {
			rd->compute_list_dispatch(list, update_count, 1, 1);
		} else {
			rd->compute_list_dispatch(list, probe_count, 1, 1);
		}
		if (pass + 1 < PASS_COUNT) {
			rd->compute_list_add_barrier(list);
		}
	}
	for (uint32_t debug_pass : { uint32_t(DEBUG_VIEW), uint32_t(DEBUG_STATS) }) {
		if (!p_debug_passes || (debug_pass == DEBUG_VIEW && !debug_compute_view) || (debug_pass == DEBUG_STATS && !readback_statistics)) {
			continue;
		}
		RID pass_shader = shader.version_get_shader(version, debug_pass);
		RID set = get_render_uniform_set(r_context, debug_pass, pass_shader, 0);
		RID material_set = get_render_uniform_set(r_context, debug_pass, pass_shader, 1);
		if (set.is_null() || material_set.is_null()) {
			rd->compute_list_end();
			data->valid = false;
			ERR_FAIL_V(false);
		}
		rd->compute_list_bind_compute_pipeline(list, pipelines[debug_pass]);
		rd->compute_list_bind_uniform_set(list, set, 0);
		rd->compute_list_bind_uniform_set(list, material_set, 1);
		rd->compute_list_set_push_constant(list, &push, sizeof(push));
		if (debug_pass == DEBUG_VIEW) {
			rd->compute_list_dispatch_threads(list, size.x, size.y, 1);
		} else {
			rd->compute_list_dispatch(list, (MAX(cache_buckets, probe_count) + 63) / 64, 1, 1);
		}
		rd->compute_list_add_barrier(list);
	}
	rd->compute_list_end();
	r_context.next_pass = p_end_pass;
	return true;
}

bool AMDGI::finish_render_context(RenderContext &r_context) {
	ERR_FAIL_COND_V(!r_context.prepared || r_context.next_pass != PREPARE_LIGHTS, false);
	RD *rd = RD::get_singleton();
	const auto &size = r_context.size;
	const auto &probe_count = r_context.probe_count;
	const auto &update_count = r_context.update_count;
	const auto &ray_count = r_context.ray_count;
	const auto &cache_buckets = r_context.cache_buckets;
	const auto &cache_tiles = r_context.cache_tiles;
	const auto &cells = r_context.cells;
	const auto &cache_all_hits = r_context.cache_all_hits;
	const auto &multibounce = r_context.multibounce;
	const auto &denoiser = r_context.denoiser;
	const auto &probe_cache = r_context.probe_cache;
	const auto &light_resampling = r_context.light_resampling;
	const auto &distant_cell_scale = r_context.distant_cell_scale;
	const auto &cell_size = r_context.cell_size;
	const auto &probability = r_context.probability;
	const auto &max_distance = r_context.max_distance;
	const auto &reflections = r_context.reflections;
	const auto &screen_feedback = r_context.screen_feedback;
	const auto &reflection_stride = r_context.reflection_stride;
	const auto &reflection_roughness = r_context.reflection_roughness;
	const auto &reflection_trace_roughness = r_context.reflection_trace_roughness;
	const auto &firefly_low = r_context.firefly_low;
	const auto &firefly_high = r_context.firefly_high;
	const auto &reflection_compaction = r_context.reflection_compaction;
	const auto &reflection_fireflies = r_context.reflection_fireflies;
	const auto &sky_sampling = r_context.sky_sampling;
	const auto &reflection_mode = r_context.reflection_mode;
	const auto &reflection_radii = r_context.reflection_radii;
	const auto &debug_statistics = r_context.debug_statistics;
	const auto &reflection_filter_passes = r_context.reflection_filter_passes;
	const auto &reflection_size = r_context.reflection_size;
	const auto &configuration = r_context.configuration;
	const auto &improvements = r_context.improvements;
	const auto &data = r_context.data;
	const auto &environment_count = r_context.environment_count;
	const auto &reset = r_context.reset;
	const auto &frame = r_context.frame;
	const auto &view_projection = r_context.view_projection;
	const auto &index = r_context.index;
	const auto &debug_bytes = r_context.debug_bytes;
	const auto &readback_statistics = r_context.readback_statistics;
	const auto &feedback = r_context.feedback;
	auto &push = r_context.push;
	const auto &reflection_capture = r_context.reflection_capture;
	const auto &reflection_diagnostic_header = r_context.reflection_diagnostic_header;
	const RaytracingGIScene &p_scene = *r_context.scene;
	const Ref<RenderSceneBuffersRD> &p_buffers = r_context.buffers;
	const Transform3D &p_camera = r_context.camera;
	const float p_exposure = r_context.exposure;
	const ReflectionDiagnosticConfig &reflection_diagnostic = reflection_diagnostic_config();
	static const bool validate_feedback = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_FEEDBACK").is_empty();
	if (debug_statistics || bool(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/exclusion_reports"))) {
		data->diagnostics["frame"] = push.frame;
		data->diagnostics["history_reset"] = reset;
		data->diagnostics["previous_light_reservoirs_reset"] = light_resampling && (reset || frame.options[3] != 0);
		data->diagnostics["scene"] = p_scene.get_scene_diagnostics();
		data->diagnostics["gpu_readback_enabled"] = debug_statistics;
		data->diagnostics["size"] = size;
		data->diagnostics["sky_sampling"] = sky_sampling;
		data->diagnostics["reflection_denoiser"] = reflection_mode;
		if (!debug_statistics) {
			data->diagnostics.erase("gpu");
		}
	} else {
		data->diagnostics.clear();
	}
	if (readback_statistics) {
		// Deliberately opt-in and decimated. Overlay queries read this snapshot,
		// never the GPU. These sampled frames are not performance measurements.
		Vector<uint8_t> bytes = rd->buffer_get_data(data->debug_stats);
		if (bytes.size() == debug_bytes) {
			const uint32_t *values = reinterpret_cast<const uint32_t *>(bytes.ptr());
			Dictionary gpu;
			static const char *names[] = { "overflow_attempts", "occupied_tiles", "occupied_buckets", "sampled_cells", "sample_sum_low", "sample_sum_high", "maximum_samples", "active_tiles", "valid_probes", "updated_probes", "primary_hit_records", "secondary_hit_records", "full_buckets", "frame", "base_cell_capacity", "valid_cached_probes" };
			for (uint32_t i = 0; i < 16; i++) {
				gpu[names[i]] = values[i];
			}
			gpu["sample_sum"] = int64_t(uint64_t(values[4]) | (uint64_t(values[5]) << 32));
			gpu["bucket_capacity"] = cache_buckets;
			gpu["tile_capacity"] = cache_tiles;
			gpu["overflow_is_attempts_not_unique_tiles"] = true;
			PackedInt32Array occupancy, overflow;
			occupancy.resize(17);
			overflow.resize(17);
			for (uint32_t i = 0; i < 17; i++) {
				occupancy.set(i, values[16 + cache_buckets + i]);
				overflow.set(i, values[16 + cache_buckets + 17 + i]);
			}
			gpu["occupancy_histogram"] = occupancy;
			gpu["overflow_histogram"] = overflow;
			data->diagnostics["gpu"] = gpu;
		}
	}
	if (reflection_capture) {
		const uint32_t record_count = reflection_diagnostic_header[2] * reflection_diagnostic_header[3];
		Vector<uint8_t> bytes = rd->buffer_get_data(data->source_validation, 0, (REFLECTION_DIAGNOSTIC_HEADER + record_count * REFLECTION_DIAGNOSTIC_STRIDE) * 16);
		ERR_FAIL_COND_V(bytes.size() != int64_t((REFLECTION_DIAGNOSTIC_HEADER + record_count * REFLECTION_DIAGNOSTIC_STRIDE) * 16), false);
		const String stem = reflection_diagnostic.directory.path_join(vformat("reflection-view-%d-%dx%d-frame-%d", uint64_t(p_buffers->get_instance_id()), size.x, size.y, push.frame));
		Ref<FileAccess> binary = FileAccess::open(stem + ".bin", FileAccess::WRITE);
		ERR_FAIL_COND_V(binary.is_null(), false);
		ERR_FAIL_COND_V(!binary->store_buffer(bytes), false);
		Dictionary metadata;
		metadata["layout_version"] = 2;
		metadata["trace_provenance_version"] = 2;
		metadata["frame"] = push.frame;
		metadata["engine_frames_drawn"] = Engine::get_singleton()->get_frames_drawn();
		metadata["width"] = size.x;
		metadata["height"] = size.y;
		metadata["roi_x"] = reflection_diagnostic_header[0];
		metadata["roi_y"] = reflection_diagnostic_header[1];
		metadata["roi_width"] = reflection_diagnostic_header[2];
		metadata["roi_height"] = reflection_diagnostic_header[3];
		Array requested_roi;
		requested_roi.push_back(reflection_diagnostic.roi.position.x);
		requested_roi.push_back(reflection_diagnostic.roi.position.y);
		requested_roi.push_back(reflection_diagnostic.roi.get_end().x);
		requested_roi.push_back(reflection_diagnostic.roi.get_end().y);
		metadata["requested_roi_normalized"] = requested_roi;
		metadata["firefly_filter"] = reflection_fireflies;
		metadata["header_vec4_count"] = REFLECTION_DIAGNOSTIC_HEADER;
		metadata["record_vec4_count"] = REFLECTION_DIAGNOSTIC_STRIDE;
		metadata["reflection_stride"] = reflection_stride;
		metadata["trace_roughness"] = reflection_trace_roughness;
		metadata["probe_roughness"] = reflection_roughness;
		metadata["reset"] = reset;
		metadata["denoiser"] = denoiser;
		Ref<FileAccess> json = FileAccess::open(stem + ".json", FileAccess::WRITE);
		ERR_FAIL_COND_V(json.is_null(), false);
		json->store_string(JSON::stringify(metadata, "\t"));
		print_line(vformat("AMD GI reflection diagnostic: %s records=%d bytes=%d", stem, record_count, bytes.size()));
	}
	if (OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_LIGHT_GRID") == "1") {
		Vector<uint8_t> result = rd->buffer_get_data(data->world->light_grid, 28, 4);
		ERR_FAIL_COND_V(result.size() != 4, false);
		uint32_t mismatches = reinterpret_cast<const uint32_t *>(result.ptr())[0];
		print_line(vformat("AMD GI light grid validation: frame=%d mismatches=%d", push.frame, mismatches));
		ERR_FAIL_COND_V(mismatches != 0, false);
	}
	if (diagnostic_source_enabled()) {
		Vector<uint8_t> bytes = rd->buffer_get_data(data->source_validation);
		print_line("AMD GI source validation: " + String::hex_encode_buffer(bytes.ptr(), bytes.size()));
	}
	if (validate_feedback && screen_feedback && !reset) {
		Vector<uint8_t> bytes = rd->texture_get_data(feedback, 0);
		ERR_FAIL_COND_V(bytes.size() != int64_t(size.x) * size.y * 8, false);
		const uint16_t *values = reinterpret_cast<const uint16_t *>(bytes.ptr());
		double sum = 0;
		uint32_t covered = 0;
		for (uint32_t i = 0; i < uint32_t(size.x * size.y); i++) {
			if (Math::half_to_float(values[4 * i + 3]) < 0.5f) {
				continue;
			}
			covered++;
			for (uint32_t channel = 0; channel < 3; channel++) {
				float value = Math::half_to_float(values[4 * i + channel]);
				ERR_FAIL_COND_V(!Math::is_finite(value), false);
				sum += value;
			}
		}
		Vector<uint8_t> counts = rd->buffer_get_data(data->queues, 12, 4);
		ERR_FAIL_COND_V(counts.size() != 4, false);
		uint32_t accepted = *reinterpret_cast<const uint32_t *>(counts.ptr());
		print_line(vformat("AMD GI feedback validation: frame=%d covered=%d accepted=%d mean=%.8f", data->frame, covered, accepted, sum / (MAX(covered, 1u) * 3.0 * MAX(data->previous_exposure, 0.000001f))));
	}
	static const bool validate_hits = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_HITS").is_empty();
	static const bool validate_bounces = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_BOUNCES").is_empty();
	uint32_t active_ray_count = UINT32_MAX;
	if (r_context.batch_data.is_valid() && (validate_hits || validate_bounces)) {
		const Vector<uint8_t> work_bytes = rd->buffer_get_data(r_context.batch_data->work, 0, 80);
		const Vector<uint8_t> origin_bytes = rd->buffer_get_data(r_context.batch_data->origins, 0, 32);
		ERR_FAIL_COND_V(work_bytes.size() != 80 || origin_bytes.size() != 32, false);
		const uint32_t *work = reinterpret_cast<const uint32_t *>(work_bytes.ptr());
		const uint32_t *origins = reinterpret_cast<const uint32_t *>(origin_bytes.ptr());
		ERR_FAIL_COND_V(work[0] > r_context.batch_data->capacity / 64u, false);
		active_ray_count = work[0] * 64u;
		ERR_FAIL_COND_V(work[1] > active_ray_count || work[2] > active_ray_count, false);
		uint32_t joined = 0;
		for (uint32_t region = 0; region < r_context.batch_uniform.info[2]; region++) {
			ERR_FAIL_COND_V(origins[region * 4 + 1] != joined, false);
			joined += origins[region * 4];
		}
		ERR_FAIL_COND_V(joined != work[0], false);
	}
	if (validate_hits && cache_all_hits) {
		ERR_FAIL_COND_V(!validate_hit_updates(data->world->keys, push.frame, data->world->owners, r_context.batch_data.is_valid() ? r_context.batch_data->hit_samples : data->hit_samples, data->world->direct_updates, r_context.batch_data.is_valid() ? r_context.batch_data->rays : data->rays, r_context.batch_data.is_valid() ? r_context.batch_data->secondary_rays : data->secondary_rays, cells, r_context.batch_data.is_valid() ? r_context.batch_data->capacity : ray_count, multibounce, active_ray_count), false);
	}
	// Synchronous diagnostic only: distinguish spatial noise from lost history.
	static const bool trace_glossy_history = !OS::get_singleton()->get_environment("GODOT_AMD_GI_TRACE_REFLECTION_HISTORY").is_empty();
	if (trace_glossy_history && reflections) {
		const Vector<uint8_t> bytes = rd->buffer_get_data(data->reflection_history[index]);
		ERR_FAIL_COND_V(bytes.size() != int64_t(size.x) * size.y * 64, false);
		uint32_t glossy = 0, fresh = 0;
		double total = 0.0;
		for (int64_t pixel = 0; pixel < size.x * size.y; pixel++) {
			float sample[20];
			unpack_reflection_sample(bytes.ptr() + pixel * 64, sample);
			if (sample[3] >= 0.0f && sample[3] < 0.5f) {
				glossy++;
				fresh += sample[15] <= 1.01f;
				total += sample[15];
			}
		}
		print_line(vformat("AMD GI glossy history: frame=%d pixels=%d fresh=%d mean=%f", data->frame, glossy, fresh, glossy ? total / glossy : 0.0));
	}
	static const bool validate_glossy = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_REFLECTIONS").is_empty();
	if (validate_glossy && reflections) {
		ERR_FAIL_COND_V(!validate_reflections(data->reflection_samples, reflection_size.x * reflection_size.y, data->queues, frame.emitters[2], reflection_compaction), false);
	}
	if (validate_bounces && multibounce) {
		ERR_FAIL_COND_V(!validate_multibounce(data->world->keys, push.frame, data->world->owners, r_context.batch_data.is_valid() ? r_context.batch_data->rays : data->rays, r_context.batch_data.is_valid() ? r_context.batch_data->secondary_rays : data->secondary_rays, cells, r_context.batch_data.is_valid() ? r_context.batch_data->capacity : ray_count, cache_all_hits, active_ray_count), false);
	}
	static const bool validate_reservoirs = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_RESERVOIRS").is_empty();
	if (validate_reservoirs && light_resampling) {
		ERR_FAIL_COND_V(!validate_light_reservoirs(data->world->light_reservoirs[r_context.batch_data.is_valid() ? r_context.batch_data->reservoir_index : index], (r_context.batch_data.is_valid() ? r_context.batch_data->capacity : ray_count) * (multibounce ? 2 : 1), p_scene.get_light_count() + p_scene.get_emitter_count() + environment_count), false);
	}
	static const bool validate_cache = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_CACHE").is_empty();
	if (validate_cache && probe_cache) {
		if (frame.motion[0]) {
			print_line(vformat("AMD GI local motion: frame=%d bounds=%d", data->frame, frame.motion[0]));
		}
		if (reset) {
			print_line(vformat("AMD GI history reset: frame=%d scene_revision=%d", data->frame, p_scene.get_revision()));
		}
		ERR_FAIL_COND_V(!validate_probe_cache(data->queues, data->spawn, data->cached_state, data->cached_order[index], probe_count, update_count, probe_count, data->frame), false);
	}
	data->valid = true;
	data->index = 1 - index;
	data->previous_view_projection = view_projection;
	data->previous_camera = p_camera;
	data->previous_exposure = p_exposure;
	data->configuration = configuration;
	data->improvements = improvements;
	data->cell_size = cell_size;
	data->distant_cell_scale = distant_cell_scale;
	data->continuation = probability;
	data->max_distance = max_distance;
	data->reflection_roughness = reflection_roughness;
	data->reflection_trace_roughness = reflection_trace_roughness;
	data->firefly_low = firefly_low;
	data->firefly_high = firefly_high;
	data->reflection_filter_passes = reflection_filter_passes;
	data->reflection_radii = reflection_radii;
	r_context.prepared = false;
	return true;
}

bool AMDGI::render(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_buffers, RID p_normals, const Projection &p_projection, const Transform3D &p_camera, float p_exposure, const Environment &p_environment) {
	ERR_FAIL_COND_V(regional_batch, false);
	RenderContext context;
	if (!prepare_render_context(p_scene, p_buffers, p_normals, p_projection, p_camera, p_exposure, p_environment, context)) {
		return false;
	}
	if (!dispatch_render_passes(context, RESERVOIR_RESET, PREPARE_LIGHTS, true)) {
		context.data->valid = false;
		return false;
	}
	return finish_render_context(context);
}

void AMDGI::configure_batch_contexts(RenderContext *p_contexts, const RegionInput *p_regions, uint32_t p_count, const LogicalView &p_parent, const Ref<BatchData> &p_batch, bool p_reset_world, bool p_reset_reservoirs) {
	RD *rd = RD::get_singleton();
	const Projection parent_vp = p_parent.projection * Projection(p_parent.camera.affine_inverse());
	const float fov_y = 2.0f * Math::atan(1.0f / Math::abs(p_parent.projection.columns[1][1]));
	const float angular = fov_y * MAX(1.0f / p_parent.output_size.y, float(p_parent.output_size.y) / (float(p_parent.output_size.x) * p_parent.output_size.x));
	for (uint32_t region = 0; region < p_count; region++) {
		RenderContext &context = p_contexts[region];
		BatchUniform &batch = context.batch_uniform;
		batch.info[0] = p_batch->capacity;
		batch.info[1] = region;
		batch.info[2] = p_count;
		batch.info[3] = p_reset_world;
		batch.parent_rect[0] = p_regions[region].parent_uv_rect.position.x;
		batch.parent_rect[1] = p_regions[region].parent_uv_rect.position.y;
		batch.parent_rect[2] = p_regions[region].parent_uv_rect.size.x;
		batch.parent_rect[3] = p_regions[region].parent_uv_rect.size.y;
		batch.angular[0] = angular;
		batch.angular[1] = p_parent.output_size.x;
		batch.angular[2] = p_parent.output_size.y;
		MaterialStorage::store_camera(parent_vp, batch.parent_view_projection);
		MaterialStorage::store_camera(parent_vp.inverse(), batch.parent_inverse_view_projection);
		MaterialStorage::store_camera(p_batch->previous_view_projection, batch.previous_parent_view_projection);
		for (uint32_t axis = 0; axis < 3; axis++) {
			batch.previous_parent_eye[axis] = p_batch->previous_camera.origin[axis];
			batch.previous_parent_forward[axis] = -p_batch->previous_camera.basis.get_column(2)[axis];
		}
		// Cache/reservoir cells use logical native pixel footprint. Regional
		// probes keep their actual angular density, including half-axis regions.
		const float density_scale = MAX(float(p_parent.output_size.x) * p_regions[region].parent_uv_rect.size.x / context.size.x, float(p_parent.output_size.y) * p_regions[region].parent_uv_rect.size.y / context.size.y);
		context.frame.settings[1] = angular * density_scale;
		context.frame.near_field[0] = 0.1f * MAX(Math::abs(p_parent.projection.columns[0][0]), Math::abs(p_parent.projection.columns[1][1]));
		context.frame.near_field[1] = SIGN(p_parent.projection.columns[0][0]);
		context.frame.near_field[2] = SIGN(p_parent.projection.columns[1][1]);
		context.frame.options[3] = p_reset_reservoirs;
		for (uint32_t slot = 0; slot < 2; slot++) {
			const uint32_t source = slot == 0 ? region : (p_count == 2 ? 1 - region : region);
			const RenderContext &feedback = p_contexts[source];
			const Rect2 &rect = p_regions[source].parent_uv_rect;
			const Rect2 &previous = feedback.data->previous_parent_rect;
			batch.feedback_rect[slot][0] = rect.position.x;
			batch.feedback_rect[slot][1] = rect.position.y;
			batch.feedback_rect[slot][2] = rect.size.x;
			batch.feedback_rect[slot][3] = rect.size.y;
			batch.feedback_previous_rect[slot][0] = previous.position.x;
			batch.feedback_previous_rect[slot][1] = previous.position.y;
			batch.feedback_previous_rect[slot][2] = previous.size.x;
			batch.feedback_previous_rect[slot][3] = previous.size.y;
			batch.feedback_size[slot][0] = feedback.size.x;
			batch.feedback_size[slot][1] = feedback.size.y;
			batch.feedback_size[slot][2] = feedback.frame.grid[3] == 0 && feedback.data->last_batch_frame == p_batch->frame - 1;
			batch.feedback_exposure[slot] = feedback.data->previous_exposure;
		}
		rd->buffer_update(context.data->frame_uniform, 0, sizeof(FrameUniform), &context.frame);
		rd->buffer_update(context.data->frame_uniform, sizeof(FrameUniform), sizeof(BatchUniform), &batch);
		context.uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 68, p_batch->origins));
		context.uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 69, p_batch->work));
		const RenderContext &other = p_contexts[p_count == 2 ? 1 - region : region];
		const uint32_t source_bindings[] = { 21, 1, 52, 48, 60, 55, 45 };
		for (uint32_t slot = 0; slot < 7; slot++) {
			for (const RD::Uniform &uniform : other.uniforms) {
				if (uniform.binding == source_bindings[slot]) {
					RD::Uniform binding = uniform;
					binding.binding = 70 + slot;
					context.uniforms.push_back(binding);
					break;
				}
			}
		}
		if (!context.disable_binding_reuse) {
			context.data->bindings[context.binding_index].update(context.uniforms);
		}
	}
}

bool AMDGI::prepare_regions(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_owner, const RegionInput &p_uniform, const RegionInput *p_scoped, uint32_t p_scoped_count, const LogicalView &p_parent, const Environment &p_environment) {
	ERR_FAIL_COND_V(!regional_batch || p_owner.is_null() || p_uniform.buffers.is_null() || (p_scoped_count != 0 && p_scoped_count != 2) || (p_scoped_count && !p_scoped), false);
	ERR_FAIL_COND_V(p_uniform.parent_uv_rect != Rect2(0, 0, 1, 1) || (p_scoped_count && p_scoped[0].parent_uv_rect != Rect2(0, 0, 1, 1)), false);
	if (p_parent.output_size.x <= 0 || p_parent.output_size.y <= 0 || p_parent.projection.is_orthogonal() || !p_scene.is_ready() || !has_material_pipelines(p_scene)) {
		return false;
	}
	const int requested_stride = GLOBAL_GET("rendering/global_illumination/amd_gi/probe_spacing");
	const uint32_t stride = requested_stride <= 8 ? 8 : (requested_stride <= 16 ? 16 : 32);
	const auto ray_capacity = [stride](const RegionInput &p_region) -> uint32_t {
		if (p_region.buffers.is_null() || p_region.normals.is_null() || p_region.parent_uv_rect.size.x <= 0 || p_region.parent_uv_rect.size.y <= 0) {
			return 0;
		}
		Size2i size = p_region.buffers->get_internal_size();
		return size.x > 0 && size.y > 0 ? ((size.x + stride - 1) / stride) * ((size.y + stride - 1) / stride) * 64u : 0;
	};
	uint32_t capacity = ray_capacity(p_uniform);
	if (!capacity) {
		return false;
	}
	uint32_t scoped_capacity = 0;
	for (uint32_t i = 0; i < p_scoped_count; i++) {
		const uint32_t count = ray_capacity(p_scoped[i]);
		if (!count) {
			return false;
		}
		scoped_capacity += count;
	}
	capacity = MAX(capacity, scoped_capacity);
	const uint32_t buckets = 1u << CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/cache_bucket_exponent")), 8, 14);
	const bool multibounce = GLOBAL_GET("rendering/global_illumination/amd_gi/multibounce");
	const bool all_hits = GLOBAL_GET("rendering/global_illumination/amd_gi/cache_all_hits");
	const bool resampling = GLOBAL_GET("rendering/global_illumination/amd_gi/light_resampling");
	const uint32_t response = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/improvements/responsive_history")) ? 1u : 0u;
	Ref<BatchData> batch;
	if (p_owner->has_custom_data(RB_SCOPE_AMD_GI_BATCH)) {
		batch = p_owner->get_custom_data(RB_SCOPE_AMD_GI_BATCH);
	}
	if (batch.is_null()) {
		batch.instantiate();
		p_owner->set_custom_data(RB_SCOPE_AMD_GI_BATCH, batch);
	}
	// Preparation can fail after converting a native screen state. Roll back
	// only GI resources, retaining depth/geometry attachments already selected
	// by Forward+. A same-frame native fallback will allocate its original ABI.
	struct PreparationRollback {
		Ref<RenderSceneBuffersRD> owner;
		const RegionInput *uniform = nullptr;
		const RegionInput *scoped = nullptr;
		uint32_t count = 0;
		bool active = true;
		void clear_screen(const Ref<RenderSceneBuffersRD> &p_buffers) {
			if (p_buffers->has_custom_data(RB_SCOPE_AMD_GI)) {
				p_buffers->set_custom_data(RB_SCOPE_AMD_GI, Ref<RenderBufferCustomDataRD>());
			}
			p_buffers->clear_context(RB_SCOPE_AMD_GI);
			p_buffers->clear_context(SNAME("amd_gi_debug"));
		}
		~PreparationRollback() {
			if (!active) {
				return;
			}
			owner->set_custom_data(RB_SCOPE_AMD_GI_BATCH, Ref<RenderBufferCustomDataRD>());
			clear_screen(owner);
			clear_screen(uniform->buffers);
			for (uint32_t i = 0; i < count; i++) {
				clear_screen(scoped[i].buffers);
			}
		}
	} rollback;
	rollback.owner = p_owner;
	rollback.uniform = &p_uniform;
	rollback.scoped = p_scoped;
	rollback.count = p_scoped_count;
	RD *rd = RD::get_singleton();
	if (batch->capacity != capacity || batch->cache_buckets != buckets || batch->multibounce != multibounce || batch->cache_all_hits != all_hits || batch->light_resampling != resampling || batch->allocation_improvements != response) {
		batch->free_data();
		// Transfer the existing camera cache when compatible. The native screen
		// state releases its reference below; no duplicate world cache is kept.
		Ref<ViewData> native;
		if (p_owner->has_custom_data(RB_SCOPE_AMD_GI)) {
			native = p_owner->get_custom_data(RB_SCOPE_AMD_GI);
		}
		if (native.is_valid() && !native->batch_screen && native->world.is_valid() && native->cache_buckets == buckets && native->multibounce == multibounce && native->cache_all_hits == all_hits && native->light_resampling == resampling && (native->improvements & 1u) == response) {
			batch->world = native->world;
			batch->frame = native->frame;
			batch->last_completed_frame = native->valid && native->frame > 0 ? int64_t(native->frame) - 1 : -1;
			batch->reservoir_index = native->index;
			batch->valid = native->valid;
			batch->world_configuration = native->configuration;
			batch->world_improvements = native->improvements;
			batch->cell_size = native->cell_size;
			batch->distant_cell_scale = native->distant_cell_scale;
			batch->continuation = native->continuation;
			batch->max_distance = native->max_distance;
			batch->previous_view_projection = native->previous_view_projection;
			batch->previous_camera = native->previous_camera;
		} else {
			batch->world.instantiate();
			const uint32_t tiles = buckets * 16u;
			const uint32_t cells = tiles * CACHE_CELLS_PER_TILE;
			const uint32_t cache_bytes = cells * 8 + (response ? tiles * 88 : 0);
			batch->world->cache[0] = rd->storage_buffer_create(cache_bytes);
			batch->world->indirect_cache[0] = rd->storage_buffer_create(multibounce ? cache_bytes : 16);
			batch->world->indirect_cache[1] = rd->storage_buffer_create(multibounce ? tiles * 64 * 16 : 16);
			batch->world->keys = rd->storage_buffer_create(48 + tiles * 2 * 32, {}, RD::STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT);
			batch->world->owners = rd->storage_buffer_create(cells * 4 * (all_hits && diagnostic_hits_enabled() ? 2 : 1));
			batch->world->direct_updates = rd->storage_buffer_create(all_hits ? tiles * 64 * 16 : 16);
		}
		for (uint32_t i = 0; i < 2; i++) {
			if (batch->world->light_reservoirs[i].is_valid()) {
				rd->free_rid(batch->world->light_reservoirs[i]);
			}
			batch->world->light_reservoirs[i] = rd->storage_buffer_create(resampling ? reservoir_buffer_bytes(capacity * (multibounce ? 2 : 1)) : 16);
		}
		batch->capacity = capacity;
		batch->cache_buckets = buckets;
		batch->multibounce = multibounce;
		batch->cache_all_hits = all_hits;
		batch->light_resampling = resampling;
		batch->allocation_improvements = response;
		batch->rays = rd->storage_buffer_create(capacity * AMD_GI_RAY_BYTES);
		batch->secondary_rays = rd->storage_buffer_create(multibounce ? capacity * AMD_GI_RAY_BYTES : 16);
		batch->hit_samples = rd->storage_buffer_create(all_hits ? capacity * (multibounce ? 2 : 1) * 48 : 16);
		batch->work = rd->storage_buffer_create(80 + (all_hits ? capacity * (multibounce ? 2 : 1) * 4 : 0), {}, RD::STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT);
		batch->origins = rd->storage_buffer_create(32 + (capacity / 64u) * 16u);
	}
	uint64_t layout = 1469598103934665603ull;
	const auto mix_layout = [&layout](uint64_t p_value) { layout = (layout ^ p_value) * 1099511628211ull; };
	for (uint32_t i = 0; i <= p_scoped_count; i++) {
		const RegionInput &input = i == 0 ? p_uniform : p_scoped[i - 1];
		mix_layout(uint64_t(input.buffers->get_instance_id()));
		mix_layout(input.normals.get_id());
		mix_layout(input.buffers->get_depth_texture().get_id());
		mix_layout(input.buffers->get_internal_size().x);
		mix_layout(input.buffers->get_internal_size().y);
		for (StringName name : { SNAME("previous_position"), SNAME("geometry_normal"), SNAME("primary_material"), SNAME("shading_normal"), SNAME("roughness") }) {
			mix_layout(input.buffers->get_texture(RB_SCOPE_AMD_GI_GEOMETRY, name).get_id());
		}
	}
	mix_layout(stride);
	mix_layout(bool(GLOBAL_GET("rendering/global_illumination/amd_gi/probe_cache")));
	mix_layout(bool(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/enabled")));
	mix_layout(bool(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/half_resolution")));
	mix_layout(int(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/denoiser")));
	mix_layout(int(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/view")));
	mix_layout(bool(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/statistics")));
	mix_layout(p_environment.auto_exposure.get_id());
	mix_layout(p_environment.radiance.get_id());
	bool screens_prepared = true;
	for (uint32_t i = 0; i <= p_scoped_count; i++) {
		const RegionInput &input = i == 0 ? p_uniform : p_scoped[i - 1];
		Ref<ViewData> data;
		if (input.buffers->has_custom_data(RB_SCOPE_AMD_GI)) {
			data = input.buffers->get_custom_data(RB_SCOPE_AMD_GI);
		}
		screens_prepared = screens_prepared && data.is_valid() && data->batch_screen && data->world == batch->world && data->frame_uniform.is_valid();
	}
	if (screens_prepared && batch->prepared_version == version && batch->prepared_layout == layout) {
		rollback.active = false;
		return true;
	}
	// Warm both screen ping-pong binding layouts for both modes during explicit
	// preparation, without dispatching any shader that reads scene surfaces.
	for (uint32_t mode = 0; mode < (p_scoped_count ? 2u : 1u); mode++) {
		const RegionInput *regions = mode == 0 ? &p_uniform : p_scoped;
		const uint32_t count = mode == 0 ? 1u : p_scoped_count;
		for (uint32_t combination = 0; combination < 4; combination++) {
			const uint32_t ping = combination & 1u;
			const uint32_t saved_reservoir_index = batch->reservoir_index;
			batch->reservoir_index = combination >> 1;
			RenderContext contexts[2];
			uint32_t previous_index[2] = {};
			for (uint32_t i = 0; i < count; i++) {
				if (regions[i].buffers->has_custom_data(RB_SCOPE_AMD_GI)) {
					Ref<ViewData> data = regions[i].buffers->get_custom_data(RB_SCOPE_AMD_GI);
					previous_index[i] = data->index;
					data->index = ping;
				}
				if (!prepare_render_context(p_scene, regions[i].buffers, regions[i].normals, regions[i].projection, p_parent.camera, p_parent.exposure, p_environment, contexts[i], batch, i > 0 ? &contexts[0].source_buffer_reads : nullptr)) {
					for (uint32_t previous = 0; previous <= i; previous++) {
						Ref<ViewData> data = regions[previous].buffers->get_custom_data(RB_SCOPE_AMD_GI);
						if (data.is_valid()) {
							data->index = previous_index[previous];
						}
					}
					batch->reservoir_index = saved_reservoir_index;
					return false;
				}
				// A newly created ViewData starts at index0; perform the other
				// ping on the second iteration after that allocation exists.
			}
			configure_batch_contexts(contexts, regions, count, p_parent, batch, !batch->valid, !batch->reservoirs_valid);
			for (uint32_t i = 0; i < count; i++) {
				for (uint32_t pass = 0; pass < PASS_COUNT; pass++) {
					if (!shader.is_variant_enabled(pass)) {
						continue;
					}
					RID pass_shader = shader.version_get_shader(version, pass);
					if (get_render_uniform_set(contexts[i], pass, pass_shader, 0).is_null() || get_render_uniform_set(contexts[i], pass, pass_shader, 1).is_null()) {
						for (uint32_t previous = 0; previous < count; previous++) {
							contexts[previous].data->index = previous_index[previous];
						}
						batch->reservoir_index = saved_reservoir_index;
						return false;
					}
				}
				contexts[i].data->index = previous_index[i];
			}
			batch->reservoir_index = saved_reservoir_index;
		}
	}
	batch->prepared_version = version;
	batch->prepared_layout = layout;
	rollback.active = false;
	return true;
}

bool AMDGI::render_regions(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_owner, const RegionInput *p_regions, uint32_t p_count, const LogicalView &p_parent, const Environment &p_environment) {
	ERR_FAIL_COND_V(!regional_batch || p_count == 0 || p_count > 2 || !p_regions || p_owner.is_null(), false);
	if (!p_owner->has_custom_data(RB_SCOPE_AMD_GI_BATCH) || !has_material_pipelines(p_scene)) {
		return false;
	}
	Ref<BatchData> batch = p_owner->get_custom_data(RB_SCOPE_AMD_GI_BATCH);
	if (batch.is_null() || batch->world.is_null() || !batch->capacity) {
		return false;
	}
	if (batch->frame == UINT32_MAX) {
		batch->frame = 1;
	}
	RenderContext contexts[2];
	uint32_t capacity = 0;
	for (uint32_t i = 0; i < p_count; i++) {
		if (p_regions[i].buffers.is_null() || !p_regions[i].buffers->has_custom_data(RB_SCOPE_AMD_GI)) {
			return false;
		}
		Ref<ViewData> data = p_regions[i].buffers->get_custom_data(RB_SCOPE_AMD_GI);
		if (!data->batch_screen || data->world != batch->world) {
			return false;
		}
		if (p_regions[i].reset_history || data->history_generation != p_regions[i].history_generation || data->last_batch_frame != batch->frame - 1 || data->index != batch->reservoir_index) {
			data->valid = false;
		}
		// Histories are accepted only from the preceding completed camera frame.
		// Synchronize newly activated/partially failed screens before binding;
		// this also bounds the prewarmed cross-region descriptor combinations.
		data->index = batch->reservoir_index;
		if (!prepare_render_context(p_scene, p_regions[i].buffers, p_regions[i].normals, p_regions[i].projection, p_parent.camera, p_parent.exposure, p_environment, contexts[i], batch, i > 0 ? &contexts[0].source_buffer_reads : nullptr)) {
			return false;
		}
		capacity += contexts[i].ray_count;
	}
	ERR_FAIL_COND_V(capacity > batch->capacity, false);
	RenderContext &world = contexts[0];
	const WorldData::LightHistoryAction lights = batch->world->update_light_order(p_scene, world.environment_count, (world.improvements & 8u) != 0u, world.light_resampling);
	const bool reset_world = !batch->valid || lights == WorldData::LightHistoryAction::RESET_VIEW || batch->world_configuration != world.configuration || batch->world_improvements != world.improvements || batch->cell_size != world.cell_size || batch->distant_cell_scale != world.distant_cell_scale || batch->continuation != world.probability || batch->max_distance != world.max_distance;
	if (reset_world) {
		for (uint32_t i = 0; i < p_count; i++) {
			contexts[i].frame.grid[3] = 1;
			contexts[i].reset = true;
		}
	}
	configure_batch_contexts(contexts, p_regions, p_count, p_parent, batch, reset_world, !batch->reservoirs_valid || lights == WorldData::LightHistoryAction::RESET_RESERVOIRS);
	RD *rd = RD::get_singleton();
	const uint32_t proposal_tops = (world.proposal_leaves + 63) / 64;
	rd->buffer_clear(batch->world->light_grid, 32 + (16 * 16 * 16 * 64 + p_scene.get_emitter_count()) * 16, (world.proposal_leaves + proposal_tops) * 64 * 16);
	// Mark invalid before the first dispatch: a partial GPU schedule cannot be
	// reused as a completed frame, nor retried with native GI in the same frame.
	batch->valid = false;
	for (uint32_t i = 0; i < p_count; i++) {
		contexts[i].data->valid = false;
	}
	const auto dispatch = [this](RenderContext &p_context, uint32_t p_first, uint32_t p_end, bool p_debug = false) {
		return dispatch_render_passes(p_context, p_first, p_end, p_debug);
	};
	world.push.samples = 0;
	if (!dispatch(world, BATCH_JOIN, BATCH_JOIN + 1) || !dispatch(world, RESERVOIR_RESET, RESERVOIR_RESET + 1) || !dispatch(world, PURGE, PURGE + 1)) {
		return false;
	}
	for (uint32_t i = 0; i < p_count; i++) {
		if (!dispatch(contexts[i], RESET, RESET + 1) || !dispatch(contexts[i], REPROJECT, COMPACT_PROBES + 1)) {
			return false;
		}
	}
	world.push.samples = 1;
	if (!dispatch(world, BATCH_JOIN, BATCH_JOIN + 1)) {
		return false;
	}
	world.push.samples = 0;
	for (uint32_t i = 0; i < p_count; i++) {
		if (!dispatch(contexts[i], GATHER_PROBES, TRACE + 1)) {
			return false;
		}
	}
	if (!dispatch(world, ALLOCATE, RESOLVE)) {
		return false;
	}
	for (uint32_t i = 0; i < p_count; i++) {
		if (!dispatch(contexts[i], RESOLVE, PREPARE_LIGHTS, true)) {
			return false;
		}
	}
	for (uint32_t i = 0; i < p_count; i++) {
		if (!finish_render_context(contexts[i])) {
			return false;
		}
		contexts[i].data->previous_parent_rect = p_regions[i].parent_uv_rect;
		contexts[i].data->history_generation = p_regions[i].history_generation;
		contexts[i].data->last_batch_frame = batch->frame;
		contexts[i].data->frame = batch->frame + 1;
	}
	batch->valid = true;
	batch->reservoirs_valid = true;
	batch->previous_view_projection = p_parent.projection * Projection(p_parent.camera.affine_inverse());
	batch->previous_camera = p_parent.camera;
	batch->world_configuration = world.configuration;
	batch->world_improvements = world.improvements;
	batch->cell_size = world.cell_size;
	batch->distant_cell_scale = world.distant_cell_scale;
	batch->continuation = world.probability;
	batch->max_distance = world.max_distance;
	batch->reservoir_index = 1 - batch->reservoir_index;
	batch->last_completed_frame = batch->frame;
	batch->frame++;
	return true;
}
