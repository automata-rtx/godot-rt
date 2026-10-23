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

#include "core/config/project_settings.h"
#include "core/os/os.h"
#include "core/templates/hash_set.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/texture_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

#include <thirdparty/amd_gi/blue_noise.h>

using namespace RendererRD;

static_assert(RendererSceneRender::MAX_RT_GI_LIGHTS == 1024);
static constexpr uint32_t LIGHT_REMAP_BYTES = 1024 * sizeof(uint32_t);

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
			ERR_FAIL_COND_V(state[4 * i + 1] != 0, false);
		} else if (owner & 0x80000000u) {
			uint32_t index = owner & 0x7fffffffu;
			ERR_FAIL_COND_V(index >= queues[2] || allocated.has(index) || state[4 * i + 1] != 0, false);
			allocated.insert(index);
		} else {
			ERR_FAIL_COND_V(owner >= p_update_count || spawn[4 * owner] == UINT32_MAX || state[4 * i + 1] == 0, false);
		}
	}
	ERR_FAIL_COND_V(allocated.size() != MIN(queues[2], p_cached_count - reused), false);
	print_line(vformat("AMD GI cache validation: frame=%d scheduled=%d budget=%d evicted=%d reused=%d", p_frame, scheduled.size(), p_update_count, allocated.size(), reused));
	return true;
}

bool AMDGI::is_enabled() {
	return GLOBAL_GET("rendering/global_illumination/amd_gi/enabled");
}

bool AMDGI::is_supported() {
	RD *rd = RD::get_singleton();
	return rd->limit_get(RD::LIMIT_MAX_STORAGE_BUFFERS_PER_SHADER_STAGE) >= 32 && rd->limit_get(RD::LIMIT_MAX_STORAGE_BUFFERS_PER_UNIFORM_SET) >= 32 && rd->limit_get(RD::LIMIT_MAX_COMPUTE_SHARED_MEMORY_SIZE) >= 32768;
}

bool AMDGI::Environment::history_compatible(const Environment &p_previous) const {
	if (radiance != p_previous.radiance || border != p_previous.border || revision != p_previous.revision || ambient.a != p_previous.ambient.a) {
		return false;
	}
	// Smooth time-of-day changes must not prevent temporal accumulation.
	// Large edits/cuts still reject old lighting immediately.
	if (world_to_sky.get_rotation_quaternion().angle_to(p_previous.world_to_sky.get_rotation_quaternion()) > Math::deg_to_rad(10.0)) {
		return false;
	}
	const float current[] = { diffuse_energy, reflection_energy, ambient.r, ambient.g, ambient.b };
	const float previous[] = { p_previous.diffuse_energy, p_previous.reflection_energy, p_previous.ambient.r, p_previous.ambient.g, p_previous.ambient.b };
	for (uint32_t i = 0; i < 5; i++) {
		if (Math::abs(current[i] - previous[i]) > 0.25f * MAX(0.01f, MAX(Math::abs(current[i]), Math::abs(previous[i])))) {
			return false;
		}
	}
	return true;
}

static bool validate_light_reservoirs(RID p_buffer, uint32_t p_count, uint32_t p_lights) {
	Vector<uint8_t> bytes = RD::get_singleton()->buffer_get_data(p_buffer);
	ERR_FAIL_COND_V(bytes.size() != int64_t(p_count * 16), false);
	const uint32_t *data = reinterpret_cast<const uint32_t *>(bytes.ptr());
	uint32_t valid = 0, reused = 0;
	for (uint32_t i = 0; i < p_count; i++) {
		const uint32_t *entry = data + 4 * i;
		if (entry[0] == UINT32_MAX) {
			ERR_FAIL_COND_V(entry[2] != 0 || entry[3] != 0, false);
			continue;
		}
		float weight, confidence;
		memcpy(&weight, entry + 2, sizeof(float));
		memcpy(&confidence, entry + 3, sizeof(float));
		ERR_FAIL_COND_V(entry[0] >= p_lights || !Math::is_finite(weight) || weight < 0.0f || !Math::is_finite(confidence) || confidence < 1.0f || confidence > 81.0f, false);
		valid++;
		reused += confidence > 1.0f;
	}
	print_line(vformat("AMD GI reservoir validation: valid=%d reused=%d", valid, reused));
	return true;
}

static bool validate_multibounce(RID p_owners, RID p_primary, RID p_secondary, uint32_t p_cells, uint32_t p_rays, bool p_all_hits) {
	RD *rd = RD::get_singleton();
	Vector<uint8_t> owner_bytes = rd->buffer_get_data(p_owners, 0, p_cells * 4);
	Vector<uint8_t> primary_bytes = rd->buffer_get_data(p_primary);
	Vector<uint8_t> secondary_bytes = rd->buffer_get_data(p_secondary);
	ERR_FAIL_COND_V(owner_bytes.size() != int64_t(p_cells * 4) || primary_bytes.size() != int64_t(p_rays * 80) || secondary_bytes.size() != int64_t(p_rays * 80), false);
	const uint32_t *owners = reinterpret_cast<const uint32_t *>(owner_bytes.ptr());
	const uint32_t *primary = reinterpret_cast<const uint32_t *>(primary_bytes.ptr());
	const uint32_t *secondary = reinterpret_cast<const uint32_t *>(secondary_bytes.ptr());
	uint32_t primary_count = 0, secondary_cells = 0, secondary_hits = 0;
	for (uint32_t cell = 0; cell < p_cells; cell++) {
		uint32_t owner = owners[cell];
		if (owner == UINT32_MAX) {
			continue;
		}
		ERR_FAIL_COND_V(cell % 85 >= 64 || owner >= 2 * p_rays, false);
		const uint32_t *ray = owner < p_rays ? primary + owner * 20 : secondary + (owner - p_rays) * 20;
		float distance;
		memcpy(&distance, ray + 3, sizeof(float));
		ERR_FAIL_COND_V(!Math::is_finite(distance) || distance <= 0.0f || ray[7] != cell, false);
		primary_count += owner < p_rays;
		secondary_cells += owner >= p_rays;
	}
	if (p_all_hits) {
		primary_count = 0;
		for (uint32_t ray = 0; ray < p_rays; ray++) {
			primary_count += primary[ray * 20 + 7] != UINT32_MAX;
		}
	}
	for (uint32_t ray = 0; ray < p_rays; ray++) {
		float distance;
		memcpy(&distance, secondary + ray * 20 + 3, sizeof(float));
		ERR_FAIL_COND_V(!Math::is_finite(distance), false);
		if (distance <= 0.0f) {
			continue;
		}
		uint32_t parent = primary[ray * 20 + 7];
		ERR_FAIL_COND_V(parent >= p_cells || (!p_all_hits && owners[parent] != ray), false);
		secondary_hits++;
	}
	ERR_FAIL_COND_V(secondary_hits > primary_count, false);
	print_line(vformat("AMD GI multibounce validation: primary=%d secondary_hits=%d secondary_cells=%d", primary_count, secondary_hits, secondary_cells));
	return true;
}

static bool validate_hit_updates(RID p_owners, RID p_samples, RID p_primary, RID p_secondary, uint32_t p_cells, uint32_t p_rays, bool p_multibounce) {
	RD *rd = RD::get_singleton();
	Vector<uint8_t> owner_bytes = rd->buffer_get_data(p_owners);
	Vector<uint8_t> sample_bytes = rd->buffer_get_data(p_samples);
	Vector<uint8_t> primary_bytes = rd->buffer_get_data(p_primary);
	Vector<uint8_t> secondary_bytes = p_multibounce ? rd->buffer_get_data(p_secondary) : Vector<uint8_t>();
	const uint32_t count = p_rays * (p_multibounce ? 2 : 1);
	ERR_FAIL_COND_V(owner_bytes.size() != int64_t(p_cells * 8) || sample_bytes.size() != int64_t(count * 48) || primary_bytes.size() != int64_t(p_rays * 80), false);
	ERR_FAIL_COND_V(p_multibounce && secondary_bytes.size() != int64_t(p_rays * 80), false);
	const uint32_t *owners = reinterpret_cast<const uint32_t *>(owner_bytes.ptr());
	const uint32_t *samples = reinterpret_cast<const uint32_t *>(sample_bytes.ptr());
	const uint32_t *primary = reinterpret_cast<const uint32_t *>(primary_bytes.ptr());
	const uint32_t *secondary = reinterpret_cast<const uint32_t *>(secondary_bytes.ptr());
	Vector<uint8_t> visited;
	visited.resize_initialized(count);
	uint8_t *seen = visited.ptrw();
	uint32_t primary_count = 0, secondary_count = 0, shared_cells = 0;
	for (uint32_t cell = 0; cell < p_cells; cell++) {
		uint32_t length = 0;
		for (uint32_t id = owners[p_cells + cell]; id != UINT32_MAX; id = samples[id * 12 + 8]) {
			ERR_FAIL_COND_V_MSG(id >= count || seen[id] || cell % 85 >= 64, false, "AMD GI hit list contains a cycle, duplicate or invalid index.");
			seen[id] = 1;
			const uint32_t *ray = id < p_rays ? primary + id * 20 : secondary + (id - p_rays) * 20;
			ERR_FAIL_COND_V(ray[7] != cell, false);
			for (uint32_t channel = 0; channel < (p_multibounce && id < p_rays ? 8u : 4u); channel++) {
				float value;
				memcpy(&value, samples + id * 12 + channel, sizeof(float));
				ERR_FAIL_COND_V(!Math::is_finite(value) || value < 0, false);
			}
			float direct_count, indirect_count;
			memcpy(&direct_count, samples + id * 12 + 3, sizeof(float));
			ERR_FAIL_COND_V(direct_count != 1.0f, false);
			if (p_multibounce && id < p_rays) {
				memcpy(&indirect_count, samples + id * 12 + 7, sizeof(float));
				ERR_FAIL_COND_V(indirect_count != 1.0f, false);
			}
			primary_count += id < p_rays;
			secondary_count += id >= p_rays;
			length++;
		}
		shared_cells += length > 1;
	}
	for (uint32_t id = 0; id < count; id++) {
		const uint32_t *ray = id < p_rays ? primary + id * 20 : secondary + (id - p_rays) * 20;
		ERR_FAIL_COND_V_MSG(bool(seen[id]) != (ray[7] != UINT32_MAX), false, "AMD GI dropped a registered hit from cache shading.");
	}
	print_line(vformat("AMD GI hit update validation: primary=%d secondary=%d shared_cells=%d", primary_count, secondary_count, shared_cells));
	return true;
}

static bool validate_reflections(RID p_buffer, uint32_t p_count, RID p_queue, uint32_t p_offset, bool p_compacted) {
	Vector<uint8_t> bytes = RD::get_singleton()->buffer_get_data(p_buffer);
	ERR_FAIL_COND_V(bytes.size() != int64_t(p_count * 80), false);
	const float *samples = reinterpret_cast<const float *>(bytes.ptr());
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
		const float *sample = samples + i * 20;
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

AMDGI::AMDGI() {
	ERR_FAIL_COND(!is_supported());
	Vector<String> modes;
	modes.push_back("");
	shader.initialize(modes);
	version = shader.version_create();
	RID compiled = shader.version_get_shader(version, 0);
	if (compiled.is_null()) {
		return;
	}
	Vector<uint8_t> noise_data;
	noise_data.resize(sizeof(AMD_GI_BLUE_NOISE));
	memcpy(noise_data.ptrw(), AMD_GI_BLUE_NOISE, sizeof(AMD_GI_BLUE_NOISE));
	blue_noise = RD::get_singleton()->storage_buffer_create(noise_data.size(), noise_data);
	for (uint32_t i = 0; i < PASS_COUNT; i++) {
		RD::PipelineSpecializationConstant constant;
		constant.constant_id = 0;
		constant.type = RD::PIPELINE_SPECIALIZATION_CONSTANT_TYPE_INT;
		constant.int_value = i;
		pipelines[i] = RD::get_singleton()->compute_pipeline_create(compiled, Vector<RD::PipelineSpecializationConstant>{ constant });
	}
}

AMDGI::~AMDGI() {
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
}

// Spatially ordered, balanced light proposals. Leaves retain the scene's stable
// light indices, so rebuilding this tree does not invalidate reservoir identity.
// The node estimate is only a proposal: RIS divides by the actual walk probability.
void AMDGI::ViewData::update_light_remap(const RaytracingGIScene &p_scene) {
	// Each viewport remaps from its own last rendered light list, not the last
	// scene update (which can belong to another viewport). Removed lights lose
	// their reservoirs without discarding unrelated radiance or pixel histories.
	const auto &lights = p_scene.get_lights();
	HashMap<uint64_t, uint32_t> current;
	for (uint32_t i = 0; i < lights.size(); i++) {
		current.insert(uint64_t(lights[i].identity[0]) | (uint64_t(lights[i].identity[1]) << 32), i);
	}
	previous_light_count = light_identities.size();
	LocalVector<uint32_t> remap;
	remap.resize(MAX(previous_light_count, 1u));
	remap[0] = UINT32_MAX;
	for (uint32_t i = 0; i < previous_light_count; i++) {
		const uint32_t *mapped_index = current.getptr(light_identities[i]);
		remap[i] = mapped_index ? *mapped_index : UINT32_MAX;
	}
	RD *rd = RD::get_singleton();
	rd->buffer_update(light_tree, 0, remap.size() * sizeof(uint32_t), remap.ptr());
	light_identities.resize(lights.size());
	for (uint32_t i = 0; i < lights.size(); i++) {
		light_identities[i] = uint64_t(lights[i].identity[0]) | (uint64_t(lights[i].identity[1]) << 32);
	}
}

bool AMDGI::ViewData::update_light_tree(const RaytracingGIScene &p_scene) {
	RD *rd = RD::get_singleton();
	if (!light_resampling) {
		if (light_tree.is_null()) {
			light_tree = rd->storage_buffer_create(LIGHT_REMAP_BYTES + 16);
		}
		return light_tree.is_valid();
	}
	const LocalVector<RaytracingGIScene::LightData> &lights = p_scene.get_lights();
	if (light_tree.is_valid() && lights.size() == sampling_lights.size() && memcmp(lights.ptr(), sampling_lights.ptr(), lights.size() * sizeof(RaytracingGIScene::LightData)) == 0) {
		return light_tree.is_valid();
	}
	struct Entry {
		uint32_t morton;
		uint32_t light;
		bool operator<(const Entry &p_other) const {
			return morton != p_other.morton ? morton < p_other.morton : light < p_other.light;
		}
	};
	struct ProposalNode {
		float minimum[3] = {};
		uint32_t light = UINT32_MAX;
		float maximum[3] = {};
		uint32_t count = 0;
		float power[4] = {}; // positional, directional, reserved
	};
	static_assert(sizeof(ProposalNode) == 48);
	const uint32_t capacity = Math::next_power_of_2(MAX(lights.size(), 1u));
	LocalVector<ProposalNode> nodes;
	nodes.resize(capacity * 2);
	LocalVector<Entry> entries;
	Vector3 minimum, maximum;
	for (uint32_t i = 0; i < lights.size(); i++) {
		Vector3 position(lights[i].position[0], lights[i].position[1], lights[i].position[2]);
		minimum = i == 0 ? position : minimum.min(position);
		maximum = i == 0 ? position : maximum.max(position);
	}
	const Vector3 extent = (maximum - minimum).max(Vector3(0.0001, 0.0001, 0.0001));
	for (uint32_t i = 0; i < lights.size(); i++) {
		Entry entry = { 0, i };
		for (uint32_t axis = 0; axis < 3; axis++) {
			uint32_t coordinate = CLAMP(int((lights[i].position[axis] - minimum[axis]) / extent[axis] * 1023.0f), 0, 1023);
			for (uint32_t bit = 0; bit < 10; bit++) {
				entry.morton |= ((coordinate >> bit) & 1u) << (bit * 3 + axis);
			}
		}
		entries.push_back(entry);
	}
	entries.sort();
	for (uint32_t i = 0; i < entries.size(); i++) {
		const uint32_t light = entries[i].light;
		ProposalNode &node = nodes[capacity + i];
		node.light = light;
		node.count = 1;
		for (uint32_t axis = 0; axis < 3; axis++) {
			node.minimum[axis] = lights[light].position[axis];
			node.maximum[axis] = lights[light].position[axis];
		}
		node.power[lights[light].type == 0 ? 1 : 0] = Math::abs(lights[light].color[0]) * 0.2126f + Math::abs(lights[light].color[1]) * 0.7152f + Math::abs(lights[light].color[2]) * 0.0722f;
	}
	for (uint32_t i = capacity - 1; i > 0; i--) {
		ProposalNode &node = nodes[i];
		const ProposalNode &left = nodes[i * 2], &right = nodes[i * 2 + 1];
		node.count = left.count + right.count;
		for (uint32_t axis = 0; axis < 3; axis++) {
			node.minimum[axis] = left.count == 0 ? right.minimum[axis] : (right.count == 0 ? left.minimum[axis] : MIN(left.minimum[axis], right.minimum[axis]));
			node.maximum[axis] = left.count == 0 ? right.maximum[axis] : (right.count == 0 ? left.maximum[axis] : MAX(left.maximum[axis], right.maximum[axis]));
		}
		node.power[0] = left.power[0] + right.power[0];
		node.power[1] = left.power[1] + right.power[1];
	}
	const uint32_t bytes = nodes.size() * sizeof(ProposalNode);
	if (light_tree_capacity != capacity) {
		RID replacement = rd->storage_buffer_create(LIGHT_REMAP_BYTES + bytes);
		ERR_FAIL_COND_V(replacement.is_null(), false);
		if (light_tree.is_valid()) {
			rd->free_rid(light_tree);
		}
		light_tree = replacement;
		light_tree_capacity = capacity;
	}
	rd->buffer_update(light_tree, LIGHT_REMAP_BYTES, bytes, nodes.ptr());
	sampling_lights = lights;
	static const bool validate = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_RESERVOIRS").is_empty();
	if (validate) {
		print_line(vformat("AMD GI light hierarchy: lights=%d capacity=%d bytes=%d", lights.size(), capacity, bytes));
	}
	return true;
}

void AMDGI::ViewData::free_data() {
	for (RID *handle : { &frame_uniform, &probes[0], &probes[1], &radiance[0], &radiance[1], &pixels[0], &pixels[1], &rays, &keys, &cache[0], &cache[1], &owners, &scratch, &spawn, &queues, &probe_mask, &cached_probes, &cached_state, &cached_order[0], &cached_order[1], &light_reservoirs[0], &light_reservoirs[1], &indirect_cache[0], &indirect_cache[1], &secondary_rays, &reflection_samples, &reflection_history[0], &reflection_history[1], &light_tree, &hit_samples }) {
		if (handle->is_valid()) {
			RD::get_singleton()->free_rid(*handle);
			*handle = RID();
		}
	}
	valid = false;
	light_tree_capacity = 0;
	sampling_lights.clear();
	light_identities.clear();
	previous_light_count = 0;
	size = Size2i();
}

void AMDGI::clear(const Ref<RenderSceneBuffersRD> &p_buffers) {
	if (p_buffers->has_custom_data(RB_SCOPE_AMD_GI)) {
		p_buffers->set_custom_data(RB_SCOPE_AMD_GI, Ref<RenderBufferCustomDataRD>());
	}
	p_buffers->clear_context(RB_SCOPE_AMD_GI);
	p_buffers->clear_context(RB_SCOPE_AMD_GI_GEOMETRY);
}

bool AMDGI::render(const RaytracingGIScene &p_scene, const Ref<RenderSceneBuffersRD> &p_buffers, RID p_normals, const Projection &p_projection, const Transform3D &p_camera, float p_exposure, const Environment &p_environment) {
	if (!p_scene.is_ready() || p_normals.is_null() || pipelines[REFLECTION_UPSAMPLE].is_null()) {
		return false;
	}
	RD *rd = RD::get_singleton();
	const Size2i size = p_buffers->get_internal_size();
	const int requested_stride = GLOBAL_GET("rendering/global_illumination/amd_gi/probe_spacing");
	const uint32_t stride = requested_stride <= 8 ? 8 : (requested_stride <= 16 ? 16 : 32);
	const uint32_t columns = (size.x + 7) / 8;
	const uint32_t rows = (size.y + 7) / 8;
	const uint32_t probe_count = columns * rows;
	uint32_t mask_cells = probe_count;
	uint32_t mask_levels = 1;
	for (uint32_t width = columns, height = rows; width > 1 || height > 1;) {
		width = (width + 1) / 2;
		height = (height + 1) / 2;
		mask_cells += width * height;
		mask_levels++;
	}
	const uint32_t update_columns = (size.x + stride - 1) / stride;
	const uint32_t update_rows = (size.y + stride - 1) / stride;
	const uint32_t update_count = update_columns * update_rows;
	const uint32_t ray_count = update_count * 64;
	const uint32_t cells = CACHE_TILES * CACHE_CELLS_PER_TILE;
	const bool cache_all_hits = GLOBAL_GET("rendering/global_illumination/amd_gi/cache_all_hits");
	const bool multibounce = GLOBAL_GET("rendering/global_illumination/amd_gi/multibounce");
	const bool denoiser = GLOBAL_GET("rendering/global_illumination/amd_gi/denoiser");
	const bool brdf_sampling = GLOBAL_GET("rendering/global_illumination/amd_gi/brdf_sampling");
	const bool importance_sampling = GLOBAL_GET("rendering/global_illumination/amd_gi/importance_sampling");
	const bool adaptive_sampling = GLOBAL_GET("rendering/global_illumination/amd_gi/adaptive_sampling");
	const bool probe_cache = GLOBAL_GET("rendering/global_illumination/amd_gi/probe_cache");
	const bool light_resampling = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/light_resampling"));
	const float cell_size = MAX(float(GLOBAL_GET("rendering/global_illumination/amd_gi/minimum_cell_size")), 0.01f);
	const float probability = CLAMP(float(GLOBAL_GET("rendering/global_illumination/amd_gi/continuation_probability")), 0.05f, 1.0f);
	const float max_distance = MAX(float(GLOBAL_GET("rendering/global_illumination/amd_gi/max_distance")), 1.0f);
	const bool reflections = GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/enabled");
	const bool screen_feedback = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/screen_feedback")) && (multibounce || reflections) && p_scene.is_feedback_compatible();
	const uint32_t reflection_stride = reflections ? (bool(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/half_resolution")) ? 2 : 1) : 0;
	const float reflection_roughness = CLAMP(float(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/probe_roughness_threshold")), 0.2f, 1.0f);
	const bool reflection_compaction = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/ray_compaction"));
	const bool reflection_fireflies = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/firefly_filter")) && denoiser;
	const uint32_t reflection_filter_passes = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/reflections/filter_passes")), 1, 3);
	const Size2i reflection_size = reflections ? Size2i((size.x + reflection_stride - 1) / reflection_stride, (size.y + reflection_stride - 1) / reflection_stride) : Size2i(1, 1);
	const uint32_t configuration = uint32_t(multibounce) | (uint32_t(denoiser) << 1) | (uint32_t(importance_sampling) << 2) | (uint32_t(adaptive_sampling) << 3) | (uint32_t(bool(GLOBAL_GET("rendering/global_illumination/amd_gi/emissive_sampling"))) << 4) | (uint32_t(reflection_fireflies) << 5) | (uint32_t(brdf_sampling) << 6);
	Ref<ViewData> data;
	if (p_buffers->has_custom_data(RB_SCOPE_AMD_GI)) {
		data = p_buffers->get_custom_data(RB_SCOPE_AMD_GI);
	}
	if (data.is_null()) {
		data.instantiate();
		p_buffers->set_custom_data(RB_SCOPE_AMD_GI, data);
	}
	if (data->size != size || data->stride != stride || data->probe_cache != probe_cache || data->light_resampling != light_resampling || data->multibounce != multibounce || data->reflection_stride != reflection_stride || data->screen_feedback != screen_feedback || data->cache_all_hits != cache_all_hits) {
		data->free_data();
		p_buffers->clear_context(RB_SCOPE_AMD_GI);
		data->size = size;
		data->stride = stride;
		data->probe_cache = probe_cache;
		data->light_resampling = light_resampling;
		data->multibounce = multibounce;
		data->screen_feedback = screen_feedback;
		data->cache_all_hits = cache_all_hits;
		data->reflection_stride = reflection_stride;
		const uint32_t reflection_bytes = reflections ? reflection_size.x * reflection_size.y * 80 : 16;
		data->reflection_samples = rd->storage_buffer_create(reflection_bytes);
		for (int i = 0; i < 2; i++) {
			data->reflection_history[i] = rd->storage_buffer_create(reflection_bytes);
		}
		data->frame_uniform = rd->uniform_buffer_create(sizeof(FrameUniform));
		for (int i = 0; i < 2; i++) {
			data->probes[i] = rd->storage_buffer_create(probe_count * 192); // position, normal, SH9, seed/age/update slot
			data->radiance[i] = rd->storage_buffer_create(probe_count * 64 * 16);
			data->pixels[i] = rd->storage_buffer_create(size.x * size.y * 48); // position, normal/delta, color/count
			data->cache[i] = rd->storage_buffer_create(cells * 16);
			data->indirect_cache[i] = rd->storage_buffer_create(multibounce ? cells * 16 : 16);
		}
		data->rays = rd->storage_buffer_create(ray_count * 80);
		data->secondary_rays = rd->storage_buffer_create(multibounce ? ray_count * 80 : 16);
		data->keys = rd->storage_buffer_create(CACHE_TILES * 32);
		data->owners = rd->storage_buffer_create(cells * 4 * (cache_all_hits ? 2 : 1));
		data->hit_samples = rd->storage_buffer_create(cache_all_hits ? ray_count * (multibounce ? 2 : 1) * 48 : 16);
		data->scratch = rd->storage_buffer_create(probe_count * 64 * 16);
		data->spawn = rd->storage_buffer_create(update_count * 16);
		// Reuse one storage binding; the appended reflection queue does not
		// overwrite diffuse/LRU queues used by validation after the dispatches.
		data->queues = rd->storage_buffer_create(16 + (probe_count * 3 + update_count * 2 + (reflections ? 4 + reflection_size.x * reflection_size.y : 0)) * 4, Vector<uint8_t>(), RD::STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT);
		data->probe_mask = rd->storage_buffer_create(mask_cells * 4);
		// Disabled cache variants bind tiny valid placeholders; no cache pass
		// or conditional access runs against them.
		data->cached_probes = rd->storage_buffer_create(probe_cache ? CACHED_PROBES * (192 + 64 * 16) : 16);
		data->cached_state = rd->storage_buffer_create(probe_cache ? CACHED_PROBES * 16 : 16);
		for (int i = 0; i < 2; i++) {
			data->cached_order[i] = rd->storage_buffer_create(probe_cache ? CACHED_PROBES * 4 : 4);
			data->light_reservoirs[i] = rd->storage_buffer_create(light_resampling ? CACHE_TILES * 64 * 16 : 16);
		}
	}
	if (!data->update_light_tree(p_scene)) {
		data->valid = false;
		return false;
	}
	data->update_light_remap(p_scene);
	const bool camera_cut = data->valid && (p_camera.origin.distance_to(data->previous_camera.origin) > 1.0 || p_camera.basis.get_column(2).dot(data->previous_camera.basis.get_column(2)) < 0.5);
	const bool configuration_changed = data->configuration != configuration || data->cell_size != cell_size || data->continuation != probability || data->max_distance != max_distance || data->reflection_roughness != reflection_roughness || data->reflection_filter_passes != reflection_filter_passes;
	const bool reset = !data->valid || !p_environment.history_compatible(data->environment) || camera_cut || data->scene_revision != p_scene.get_revision() || configuration_changed;
	static const bool trace_history = !OS::get_singleton()->get_environment("GODOT_AMD_GI_TRACE_HISTORY").is_empty();
	if (trace_history && reset) {
		print_line(vformat("AMD GI reset reasons: frame=%d invalid=%s environment=%s camera=%s scene=%s configuration=%s distance=%f", data->frame, !data->valid, !p_environment.history_compatible(data->environment), camera_cut, data->scene_revision != p_scene.get_revision(), configuration_changed, p_camera.origin.distance_to(data->previous_camera.origin)));
	}
	FrameUniform frame = {};
	frame.emitters[0] = p_scene.get_emitter_count();
	frame.emitters[1] = p_scene.get_emitter_capacity();
	frame.emitters[2] = probe_count * 3 + update_count * 2;
	frame.emitters[3] = reflection_compaction && reflections;
	frame.motion[0] = p_scene.get_motion_bounds().size();
	frame.motion[1] = cache_all_hits;
	if (data->lighting_revision != p_scene.get_lighting_revision()) {
		// A light event can occur between a sparse probe's updates. Keep the
		// reactive window for one dense-grid refresh cycle, without adding rays
		// or discarding geometry history. Otherwise dark history suppresses the
		// returning light in probes not selected on the event frame itself.
		data->lighting_reactive_frames = MAX(1u, stride * stride / 64u);
	}
	frame.motion[2] = data->lighting_reactive_frames > 0;
	if (data->lighting_reactive_frames > 0) {
		data->lighting_reactive_frames--;
	}
	frame.motion[3] = data->previous_light_count;
	data->lighting_revision = p_scene.get_lighting_revision();
	if (trace_history && frame.motion[0]) {
		print_line(vformat("AMD GI dirty regions: frame=%d count=%d", data->frame, frame.motion[0]));
	}
	for (uint32_t i = 0; i < frame.motion[0]; i++) {
		const AABB &bounds = p_scene.get_motion_bounds()[i];
		const Vector3 end = bounds.get_end();
		for (int axis = 0; axis < 3; axis++) {
			frame.motion_bounds[i][axis] = bounds.position[axis];
			frame.motion_bounds[i][axis + 4] = end[axis];
		}
	}
	MaterialStorage::store_camera(data->previous_view_projection, frame.previous_view_projection);
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
	frame.sky[3] = uint32_t(reflection_fireflies) | (uint32_t(brdf_sampling) << 1);
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
	RID intermediate = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("filter"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage);
	RID reflection_output = p_buffers->create_texture(RB_SCOPE_AMD_GI, reflections ? SNAME("reflection") : SNAME("reflection_placeholder"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage, RD::TEXTURE_SAMPLES_1, reflections ? size : Size2i(1, 1));
	RID reflection_filter_a = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("reflection_filter_a"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage, RD::TEXTURE_SAMPLES_1, reflection_size);
	RID reflection_filter_b = p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("reflection_filter_b"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, usage, RD::TEXTURE_SAMPLES_1, reflection_size);
	RID feedback = screen_feedback ? p_buffers->create_texture(RB_SCOPE_AMD_GI, SNAME("feedback"), RD::DATA_FORMAT_R16G16B16A16_SFLOAT, RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT) : TextureStorage::get_singleton()->texture_rd_get_default(TextureStorage::DEFAULT_RD_TEXTURE_BLACK);
	RID sampler = MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	LocalVector<RD::Uniform> uniforms;
	p_scene.append_uniforms(uniforms, sampler);
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, Vector<RID>{ sampler, p_buffers->get_depth_texture() }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, Vector<RID>{ sampler, p_normals }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 3, output));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 10, data->frame_uniform));
	const RID storage[] = { data->probes[index], data->probes[1 - index], data->rays, data->radiance[index], data->radiance[1 - index], data->keys, data->cache[1 - index], data->cache[index], data->owners, data->scratch, data->pixels[1 - index], data->pixels[index] };
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
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 32, data->light_reservoirs[1 - index]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 33, data->light_reservoirs[index]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 34, data->indirect_cache[1 - index]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 35, data->indirect_cache[index]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 36, data->secondary_rays));
	RID sky_texture = p_environment.radiance.is_valid() ? p_environment.radiance : TextureStorage::get_singleton()->texture_rd_get_default(TextureStorage::DEFAULT_RD_TEXTURE_BLACK);
	RID sky_sampler = MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_LINEAR, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 37, Vector<RID>{ sky_sampler, sky_texture }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 38, data->reflection_samples));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 39, data->reflection_history[1 - index]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 40, data->reflection_history[index]));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 41, reflection_filter_a));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 42, reflection_filter_b));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_IMAGE, 43, reflection_output));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 44, data->light_tree));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 45, Vector<RID>{ sampler, feedback }));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 46, data->hit_samples));
	uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 48, Vector<RID>{ sampler, p_buffers->get_texture(RB_SCOPE_AMD_GI_GEOMETRY, SNAME("previous_position")) }));
	RID set = UniformSetCacheRD::get_singleton()->get_cache_vec(shader.version_get_shader(version, 0), 0, uniforms);
	if (set.is_null()) {
		data->valid = false;
		return false;
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
	push.frame = ++data->frame;
	// Pass boundaries are explicit: no dispatch reads concurrently written radiance.
	RD::ComputeListID list = rd->compute_list_begin();
	for (uint32_t pass = 0; pass < PASS_COUNT; pass++) {
		if (!reflection_compaction && (pass == REFLECTION_CLASSIFY || pass == REFLECTION_BUILD_DISPATCH)) {
			continue;
		}
		if (!reflection_fireflies && (pass == REFLECTION_MARK_FIREFLIES || pass == REFLECTION_CLEAN_FIREFLIES)) {
			continue;
		}
		if ((!reflections && pass >= REFLECTION_CLASSIFY) || (!denoiser && pass == REFLECTION_FILTER)) {
			continue;
		}
		if (!multibounce && ((pass >= POPULATE && pass <= REGISTER_SECONDARY) || (pass >= SHADE_INDIRECT_HITS && pass <= INDIRECT_MIP3))) {
			continue;
		}
		if (!cache_all_hits && (pass == SHADE_HITS || pass == SHADE_INDIRECT_HITS)) {
			continue;
		}
		if (!probe_cache && (pass == BIN_CACHED || pass == ORDER_CACHED || pass == STORE_CACHED)) {
			continue;
		}
		rd->compute_list_bind_compute_pipeline(list, pipelines[pass]);
		rd->compute_list_bind_uniform_set(list, set, 0);
		if (pass == REFLECTION_FILTER) {
			for (uint32_t iteration = 0; iteration < reflection_filter_passes; iteration++) {
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
				width = (width + 1) / 2;
				height = (height + 1) / 2;
				push.samples = mip;
				rd->compute_list_set_push_constant(list, &push, sizeof(push));
				rd->compute_list_dispatch_threads(list, width, height, 1);
				rd->compute_list_add_barrier(list);
			}
			push.samples = 0;
			continue;
		}
		rd->compute_list_set_push_constant(list, &push, sizeof(push));
		if (pass == REFLECTION_TRACE && reflection_compaction) {
			rd->compute_list_dispatch_indirect(list, data->queues, 16 + frame.emitters[2] * 4);
		} else if (pass == REFLECTION_BUILD_DISPATCH || pass == ORDER_CACHED) {
			rd->compute_list_dispatch(list, 1, 1, 1);
		} else if (pass == BIN_CACHED) {
			rd->compute_list_dispatch(list, (CACHED_PROBES + 63) / 64, 1, 1);
		} else if (pass == STORE_CACHED) {
			rd->compute_list_dispatch(list, CACHED_PROBES, 1, 1);
		} else if (pass >= REFLECTION_CLASSIFY && pass < REFLECTION_UPSAMPLE) {
			rd->compute_list_dispatch_threads(list, reflection_size.x, reflection_size.y, 1);
		} else if (pass >= INTERPOLATE) {
			rd->compute_list_dispatch_threads(list, size.x, size.y, 1);
		} else if (pass == SHADE_HITS) {
			rd->compute_list_dispatch(list, (ray_count * (multibounce ? 2 : 1) + 63) / 64, 1, 1);
		} else if (pass == SHADE_INDIRECT_HITS || (pass == POPULATE && cache_all_hits)) {
			rd->compute_list_dispatch(list, (ray_count + 63) / 64, 1, 1);
		} else if (pass == UPDATE || pass == POPULATE || pass == UPDATE_INDIRECT) {
			rd->compute_list_dispatch(list, (cells + 63) / 64, 1, 1);
		} else if (pass == RESET || (pass >= MIP1 && pass <= MIP3) || (pass >= INDIRECT_MIP1 && pass <= INDIRECT_MIP3)) {
			rd->compute_list_dispatch(list, CACHE_TILES, 1, 1);
		} else if (pass == SELECT || pass == PATCH || pass == PREPARE || pass == TRACE || pass == ALLOCATE || pass == REGISTER || pass == ALLOCATE_SECONDARY || pass == REGISTER_SECONDARY || pass == RESOLVE) {
			rd->compute_list_dispatch(list, update_count, 1, 1);
		} else {
			rd->compute_list_dispatch(list, probe_count, 1, 1);
		}
		if (pass + 1 < PASS_COUNT) {
			rd->compute_list_add_barrier(list);
		}
	}
	rd->compute_list_end();
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
	if (validate_hits && cache_all_hits) {
		ERR_FAIL_COND_V(!validate_hit_updates(data->owners, data->hit_samples, data->rays, data->secondary_rays, cells, ray_count, multibounce), false);
	}
	// Synchronous diagnostic only: distinguish spatial noise from lost history.
	static const bool trace_glossy_history = !OS::get_singleton()->get_environment("GODOT_AMD_GI_TRACE_REFLECTION_HISTORY").is_empty();
	if (trace_glossy_history && reflections) {
		const Vector<uint8_t> bytes = rd->buffer_get_data(data->reflection_history[index]);
		ERR_FAIL_COND_V(bytes.size() != int64_t(reflection_size.x) * reflection_size.y * 80, false);
		const float *samples = reinterpret_cast<const float *>(bytes.ptr());
		uint32_t glossy = 0, fresh = 0;
		double total = 0.0;
		for (int64_t pixel = 0; pixel < reflection_size.x * reflection_size.y; pixel++) {
			const float *sample = samples + pixel * 20;
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
	static const bool validate_bounces = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_BOUNCES").is_empty();
	if (validate_bounces && multibounce) {
		ERR_FAIL_COND_V(!validate_multibounce(data->owners, data->rays, data->secondary_rays, cells, ray_count, cache_all_hits), false);
	}
	static const bool validate_reservoirs = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_RESERVOIRS").is_empty();
	if (validate_reservoirs && light_resampling) {
		ERR_FAIL_COND_V(!validate_light_reservoirs(data->light_reservoirs[index], CACHE_TILES * 64, p_scene.get_light_count()), false);
	}
	static const bool validate_cache = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_CACHE").is_empty();
	if (validate_cache && probe_cache) {
		if (frame.motion[0]) {
			print_line(vformat("AMD GI local motion: frame=%d bounds=%d", data->frame, frame.motion[0]));
		}
		if (reset) {
			print_line(vformat("AMD GI history reset: frame=%d scene_revision=%d", data->frame, p_scene.get_revision()));
		}
		ERR_FAIL_COND_V(!validate_probe_cache(data->queues, data->spawn, data->cached_state, data->cached_order[index], probe_count, update_count, CACHED_PROBES, data->frame), false);
	}
	data->valid = true;
	data->index = 1 - index;
	data->previous_view_projection = view_projection;
	data->previous_camera = p_camera;
	data->previous_exposure = p_exposure;
	data->scene_revision = p_scene.get_revision();
	data->configuration = configuration;
	data->cell_size = cell_size;
	data->continuation = probability;
	data->max_distance = max_distance;
	data->environment = p_environment;
	data->reflection_roughness = reflection_roughness;
	data->reflection_filter_passes = reflection_filter_passes;
	return true;
}
