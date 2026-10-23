/**************************************************************************/
/*  rt_gi_scene.cpp                                                       */
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

#include "rt_gi_scene.h"

#include "core/config/project_settings.h"
#include "core/os/os.h"
#include "servers/rendering/renderer_rd/environment/rt_material_capture.h"
#include "servers/rendering/renderer_rd/forward_clustered/scene_shader_forward_clustered.h"
#include "servers/rendering/renderer_rd/renderer_scene_render_rd.h"
#include "servers/rendering/renderer_rd/storage_rd/light_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/material_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/mesh_storage.h"
#include "servers/rendering/renderer_rd/storage_rd/texture_storage.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

RaytracingGIScene::RaytracingGIScene() {
}

bool RaytracingGIScene::resize_atlas(uint32_t p_layers) {
	if (p_layers == atlas_layers) {
		return true;
	}
	RD *rd = RD::get_singleton();
	RID replacement[4];
	RD::TextureFormat tf;
	tf.texture_type = RD::TEXTURE_TYPE_2D_ARRAY;
	tf.width = page_size;
	tf.height = page_size;
	tf.array_layers = p_layers;
	tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
	bool success = true;
	for (int i = 0; i < 4 && success; i++) {
		tf.format = i == 3 ? RD::DATA_FORMAT_R16G16B16A16_SFLOAT : RD::DATA_FORMAT_R8G8B8A8_UNORM;
		replacement[i] = rd->texture_create(tf, RD::TextureView());
		success = replacement[i].is_valid();
		for (uint32_t layer = 0; layer < MIN(atlas_layers, p_layers) && success; layer++) {
			success = rd->texture_copy(atlas[i], replacement[i], Vector3(), Vector3(), Vector3(page_size, page_size, 1), 0, 0, layer, layer) == OK;
		}
	}
	if (!success) {
		for (RID handle : replacement) {
			if (handle.is_valid()) {
				rd->free_rid(handle);
			}
		}
		return false;
	}
	for (int i = 0; i < 4; i++) {
		if (atlas[i].is_valid()) {
			rd->free_rid(atlas[i]);
		}
		atlas[i] = replacement[i];
	}
	if (p_layers < atlas_layers) {
		for (KeyValue<MaterialKey, SurfaceMaterial *> &entry : material_cache) {
			for (MaterialPage &page : entry.value->pages) {
				if (page.atlas_tile >= p_layers * PAGE_TRIANGLES) {
					page.atlas_tile = UINT32_MAX;
				}
			}
		}
	}
	atlas_layers = p_layers;
	return true;
}

bool RaytracingGIScene::ensure_scene_buffers(uint32_t p_instances, uint32_t p_lights) {
	RD *rd = RD::get_singleton();
	if (p_instances > instance_capacity) {
		const uint32_t capacity = Math::next_power_of_2(MAX(64u, p_instances));
		RID replacement_tlas = rd->tlas_create(capacity, RD::ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT);
		RID replacement_hits = rd->storage_buffer_create(capacity * sizeof(HitData));
		if (replacement_tlas.is_null() || replacement_hits.is_null()) {
			if (replacement_tlas.is_valid()) {
				rd->free_rid(replacement_tlas);
			}
			if (replacement_hits.is_valid()) {
				rd->free_rid(replacement_hits);
			}
			return false;
		}
		if (tlas.is_valid()) {
			rd->free_rid(tlas);
			rd->free_rid(hit_buffer);
		}
		tlas = replacement_tlas;
		hit_buffer = replacement_hits;
		instance_capacity = capacity;
	}
	const uint32_t required_emitters = Math::next_power_of_2(MAX(emitter_count, 1u));
	const bool retain_emitters = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/enabled")) && bool(GLOBAL_GET("rendering/global_illumination/amd_gi/emissive_sampling"));
	if (light_buffer.is_null() || required_emitters > emitter_storage_capacity || (!retain_emitters && emitter_storage_capacity > 1)) {
		// Retain physical capacity across flickering emitters. Logical tree size
		// still follows the current set, so a formerly large scene does not make
		// a small emitter rebuild process all previously allocated leaves.
		const uint32_t storage_capacity = retain_emitters ? MAX(required_emitters, emitter_storage_capacity) : 1;
		RID replacement = rd->storage_buffer_create(MAX_LIGHTS * sizeof(LightData) + storage_capacity * 2u * 64u);
		if (replacement.is_null()) {
			return false;
		}
		if (light_buffer.is_valid()) {
			rd->free_rid(light_buffer);
		}
		light_buffer = replacement;
		light_capacity = MAX_LIGHTS;
		emitter_storage_capacity = storage_capacity;
		emitter_buffer_valid = false;
	}
	if (emitter_capacity != required_emitters) {
		emitter_capacity = required_emitters;
		emitter_buffer_valid = false;
	}
	return true;
}

RaytracingGIScene::~RaytracingGIScene() {
	if (emitter_pipeline.is_valid()) {
		RD::get_singleton()->free_rid(emitter_pipeline);
	}
	if (emitter_version.is_valid()) {
		emitter_shader.version_free(emitter_version);
	}
	prune_materials(UINT64_MAX);
	for (RID handle : { tlas, hit_buffer, light_buffer, atlas[0], atlas[1], atlas[2], atlas[3] }) {
		if (handle.is_valid()) {
			RD::get_singleton()->free_rid(handle);
		}
	}
}
void RaytracingGIScene::append_uniforms(LocalVector<RD::Uniform> &r_uniforms, RID p_sampler) const {
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_ACCELERATION_STRUCTURE, 0, tlas));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 4, hit_buffer));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 5, light_buffer));
	for (int i = 0; i < 4; i++) {
		r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 6 + i, Vector<RID>{ p_sampler, atlas[i] }));
	}
}
bool RaytracingGIScene::light_history_compatible(const LightData &p_current, const LightData &p_previous) {
	if (p_current.type != p_previous.type || p_current.mask != p_previous.mask || p_current.shadows != p_previous.shadows || p_current.shadow_mask != p_previous.shadow_mask) {
		return false;
	}
	const float current[] = { p_current.color[0], p_current.color[1], p_current.color[2], p_current.range, p_current.decay, p_current.spot_attenuation, p_current.shadow_opacity };
	const float previous[] = { p_previous.color[0], p_previous.color[1], p_previous.color[2], p_previous.range, p_previous.decay, p_previous.spot_attenuation, p_previous.shadow_opacity };
	for (uint32_t i = 0; i < 7; i++) {
		if (Math::abs(current[i] - previous[i]) > 0.25f * MAX(0.01f, MAX(Math::abs(current[i]), Math::abs(previous[i])))) {
			return false;
		}
	}
	if (Math::abs(p_current.cos_angle - p_previous.cos_angle) > 0.05f) {
		return false;
	}
	const Vector3 direction(p_current.direction[0], p_current.direction[1], p_current.direction[2]);
	const Vector3 previous_direction(p_previous.direction[0], p_previous.direction[1], p_previous.direction[2]);
	if (direction.dot(previous_direction) < Math::cos(Math::deg_to_rad(10.0))) {
		return false;
	}
	if (p_current.type != 0) {
		const Vector3 position(p_current.position[0], p_current.position[1], p_current.position[2]);
		const Vector3 previous_position(p_previous.position[0], p_previous.position[1], p_previous.position[2]);
		if (position.distance_to(previous_position) > MAX(0.5f, p_current.range * 0.1f)) {
			return false;
		}
	}
	return true;
}

void RaytracingGIScene::prune_materials(uint64_t p_minimum_frame, uint64_t p_unused_budget) {
	struct Candidate {
		MaterialKey key;
		uint64_t age;
		uint64_t bytes;
		bool operator<(const Candidate &p_other) const { return age < p_other.age; }
	};
	LocalVector<Candidate> unused;
	uint64_t unused_bytes = 0;
	for (const KeyValue<MaterialKey, SurfaceMaterial *> &entry : material_cache) {
		if (p_minimum_frame == UINT64_MAX || entry.value->last_used != material_frame) {
			uint64_t bytes = 0;
			for (MaterialPage &page : entry.value->pages) {
				bytes += page.capture->get_memory_usage();
				// Packed atlas locations can be overwritten while a capture is not
				// visible. Retain its native pixels, not ownership of the old slot.
				page.atlas_tile = UINT32_MAX;
			}
			unused.push_back({ entry.key, entry.value->last_used, bytes });
			unused_bytes += bytes;
		}
	}
	unused.sort();
	for (const Candidate &candidate : unused) {
		if (candidate.age >= p_minimum_frame && unused_bytes <= p_unused_budget) {
			break;
		}
		SurfaceMaterial *material = material_cache[candidate.key];
		for (MaterialPage &page : material->pages) {
			memdelete(page.capture);
		}
		memdelete(material);
		material_cache.erase(candidate.key);
		unused_bytes -= candidate.bytes;
	}
}

void RaytracingGIScene::add_motion_bounds(const AABB &p_bounds) {
	const AABB bounds = p_bounds.grow(0.01);
	for (AABB &existing : motion_bounds) {
		if (existing.encloses(bounds)) {
			return;
		}
	}
	if (motion_bounds.size() < MAX_MOTION_BOUNDS) {
		motion_bounds.push_back(bounds);
		return;
	}
	// Keep overflow close to an existing dirty region instead of always
	// bridging the last mover to every subsequent object in the scene.
	uint32_t closest = 0;
	real_t growth = Math::INF;
	for (uint32_t i = 0; i < motion_bounds.size(); i++) {
		const real_t candidate = motion_bounds[i].merge(bounds).get_volume() - motion_bounds[i].get_volume();
		if (candidate < growth) {
			growth = candidate;
			closest = i;
		}
	}
	motion_bounds[closest].merge_with(bounds);
}

void RaytracingGIScene::update_instance_history(const LocalVector<InstanceState> &p_instances) {
	// Both lists are sorted by instance RID and MultiMesh element. Hit IDs and
	// atlas offsets are frame-local; no persistent probe stores these indices.
	// Match identities across collection changes rather than comparing slots.
	if (!previous_instances.is_empty()) {
		uint32_t old_index = 0;
		uint32_t new_index = 0;
		while (old_index < previous_instances.size() || new_index < p_instances.size()) {
			if (old_index == previous_instances.size()) {
				add_motion_bounds(p_instances[new_index++].bounds);
				continue;
			}
			if (new_index == p_instances.size()) {
				add_motion_bounds(previous_instances[old_index++].bounds);
				continue;
			}
			const InstanceState &old = previous_instances[old_index];
			const InstanceState &current = p_instances[new_index];
			if (old.instance == current.instance && old.element == current.element) {
				if (old.transform != current.transform || old.pose_signature != current.pose_signature || old.content_signature != current.content_signature) {
					add_motion_bounds(old.bounds.merge(current.bounds));
				}
				old_index++;
				new_index++;
			} else if (old.instance < current.instance || (old.instance == current.instance && old.element < current.element)) {
				add_motion_bounds(old.bounds);
				old_index++;
			} else {
				add_motion_bounds(current.bounds);
				new_index++;
			}
		}
	}
	previous_instances = p_instances;
}

RID RaytracingGIScene::surface_material(const RendererSceneRender::RaytracingGIInstance &p_instance, int p_surface) {
	if (p_instance.material_override.is_valid()) {
		return p_instance.material_override;
	}
	if (p_surface < p_instance.materials.size() && p_instance.materials[p_surface].is_valid()) {
		return p_instance.materials[p_surface];
	}
	return MeshStorage::get_singleton()->mesh_surface_get_material(p_instance.mesh, p_surface);
}

bool RaytracingGIScene::can_share_capture(RID p_material) {
	auto *data = static_cast<RendererSceneRenderImplementation::SceneShaderForwardClustered::MaterialData *>(MaterialStorage::get_singleton()->material_get_data(p_material, MaterialStorage::SHADER_TYPE_3D));
	if (!data || !data->shader_data) {
		return false;
	}
	const auto &shader = *data->shader_data;
	if (shader.uses_instance_transform || shader.uses_world_coordinates || shader.uses_normal || shader.uses_tangent) {
		return false;
	}
	for (const auto &uniform : shader.uniforms) {
		if (uniform.value.scope == ShaderLanguage::ShaderNode::Uniform::SCOPE_INSTANCE) {
			return false;
		}
	}
	return true;
}

uint64_t RaytracingGIScene::required_material_tiles(const LocalVector<RendererSceneRender::RaytracingGIInstance> &p_instances, LocalVector<MaterialPlacement> &r_placements) const {
	// Metadata-only preflight: no BLAS construction, capture, allocation, or GPU
	// readback. Count the same shared material keys as the capture loop below.
	MeshStorage *meshes = MeshStorage::get_singleton();
	HashSet<MaterialKey, MaterialKeyHasher> unique;
	uint64_t tiles = 0;
	for (const auto &instance : p_instances) {
		if (instance.mesh.is_null()) {
			continue; // The collection pass reports unsupported geometry.
		}
		Color color(1, 1, 1, 1);
		if (instance.multimesh.is_valid() && !meshes->multimesh_uses_indirect(instance.multimesh) && meshes->multimesh_uses_colors(instance.multimesh)) {
			color = meshes->multimesh_instance_get_color(instance.multimesh, instance.element);
		}
		for (int surface = 0; surface < meshes->mesh_get_surface_count(instance.mesh); surface++) {
			RID material = surface_material(instance, surface);
			auto *data = static_cast<RendererSceneRenderImplementation::SceneShaderForwardClustered::MaterialData *>(MaterialStorage::get_singleton()->material_get_data(material, MaterialStorage::SHADER_TYPE_3D));
			if (data && data->shader_data && data->next_pass.is_null()) {
				const auto &shader = *data->shader_data;
				if (shader.uses_alpha_pass() && !shader.uses_depth_in_alpha_pass() && shader.depth_draw != RendererSceneRenderImplementation::SceneShaderForwardClustered::ShaderData::DEPTH_DRAW_ALWAYS && !shader.casts_shadows()) {
					continue;
				}
			}
			const bool shared = can_share_capture(material);
			const MaterialKey key{ instance.mesh, material, instance.mesh_instance, shared ? RID() : instance.instance, shared ? 0u : instance.element, uint32_t(surface), shared ? color : Color(1, 1, 1, 1) };
			if (unique.has(key)) {
				continue;
			}
			unique.insert(key);
			void *source = meshes->mesh_get_surface(instance.mesh, uint32_t(surface));
			uint32_t count = meshes->mesh_surface_get_index_count(source);
			if (count == 0) {
				count = meshes->mesh_surface_get_vertex_count(source);
			}
			const uint32_t surface_tiles = ((count / 3u + 31u) / 32u) * 32u;
			tiles += surface_tiles;
			r_placements.push_back({ key, surface_tiles, UINT32_MAX });
		}
	}
	return tiles;
}

uint32_t RaytracingGIScene::place_material_tiles(LocalVector<MaterialPlacement> &r_placements, uint32_t p_limit) const {
	struct Interval {
		uint32_t first, end;
		bool operator<(const Interval &p_other) const { return first < p_other.first; }
	};
	LocalVector<Interval> occupied;
	for (MaterialPlacement &placement : r_placements) {
		SurfaceMaterial *const *cached = material_cache.getptr(placement.key);
		// Only last frame's live captures own atlas space. Inactive captures
		// retain their native pixels, but their old slot may already be reused.
		if (cached && (*cached)->last_used + 1 == material_frame && (*cached)->allocated_tiles == placement.count && (*cached)->first_tile < p_limit && placement.count <= p_limit - (*cached)->first_tile) {
			placement.first = (*cached)->first_tile;
			occupied.push_back({ placement.first, placement.first + placement.count });
		}
	}
	occupied.sort();
	LocalVector<Interval> available;
	bool compact = false;
	uint32_t end = 0;
	for (const Interval &span : occupied) {
		compact |= span.first < end;
		if (end < span.first) {
			available.push_back({ end, span.first });
		}
		end = MAX(end, span.end);
	}
	if (end < p_limit) {
		available.push_back({ end, p_limit });
	}
	for (MaterialPlacement &placement : r_placements) {
		if (placement.first != UINT32_MAX) {
			continue;
		}
		for (Interval &span : available) {
			if (placement.count <= span.end - span.first) {
				placement.first = span.first;
				span.first += placement.count;
				break;
			}
		}
		if (placement.first == UINT32_MAX) {
			compact = true; // Preflight proved total capacity; only fragmentation remains.
			break;
		}
	}
	end = 0;
	for (MaterialPlacement &placement : r_placements) {
		if (compact) {
			placement.first = end;
		}
		end = MAX(end, placement.first + placement.count);
	}
	return end;
}

void RaytracingGIScene::update_scene(RaytracingGeometry &p_geometry, const LocalVector<RendererSceneRender::RaytracingGIInstance> &p_instances, const LocalVector<RID> &p_lights) {
	ready = false;
	feedback_compatible = true;
	material_frame++;
	motion_bounds.clear();
	LocalVector<InstanceState> current_instances;
	RD *rd = RD::get_singleton();
	const uint32_t requested_tile_size = int(GLOBAL_GET("rendering/global_illumination/amd_gi/material_tile_size")) == 4 ? 4 : 8;
	const uint32_t atlas_mb = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/material_atlas_mb")), 8, 512);
	const bool adaptive_resolution = GLOBAL_GET("rendering/global_illumination/amd_gi/material_adaptive_resolution");
	// Keep reduced resolution until the settings or scene lifetime change. A
	// flickering object at the budget boundary must not rebuild every capture.
	uint32_t selected_size = configured_tile_size != requested_tile_size || configured_atlas_mb != atlas_mb || configured_adaptive_resolution != adaptive_resolution ? requested_tile_size : tile_size;
	configured_tile_size = requested_tile_size;
	configured_atlas_mb = atlas_mb;
	configured_adaptive_resolution = adaptive_resolution;
	LocalVector<MaterialPlacement> placements;
	const uint64_t required_tiles = required_material_tiles(p_instances, placements);
	const uint64_t required_pages = (required_tiles + PAGE_TRIANGLES - 1) / PAGE_TRIANGLES;
	const uint64_t atlas_budget = uint64_t(atlas_mb) * 1024 * 1024;
	while (adaptive_resolution && selected_size > 2 && required_pages * PAGE_TRIANGLES * selected_size * selected_size * 20u > atlas_budget) {
		selected_size /= 2;
	}
	if (required_pages > rd->limit_get(RD::LIMIT_MAX_TEXTURE_ARRAY_LAYERS) || required_pages * PAGE_TRIANGLES * selected_size * selected_size * 20u > atlas_budget) {
		WARN_PRINT_ONCE(vformat("RT GI material preflight exceeds the configured budget (%d triangles including row padding, %d MiB). Increase material_atlas_mb or reduce max_distance. No partial scene is traced.", required_tiles, atlas_mb));
		prune_materials(material_frame, atlas_budget / 4);
		return;
	}
	if (selected_size != tile_size) {
		prune_materials(UINT64_MAX);
		for (RID &texture : atlas) {
			if (texture.is_valid()) {
				rd->free_rid(texture);
				texture = RID();
			}
		}
		atlas_layers = 0;
		tile_size = selected_size;
		page_size = tile_size * 32;
		revision++;
	}
	// Three RGBA8 planes and one RGBA16F plane: 20 bytes per texel.
	const uint32_t max_pages = MIN(uint32_t(rd->limit_get(RD::LIMIT_MAX_TEXTURE_ARRAY_LAYERS)), atlas_budget / (page_size * page_size * 20u));
	if (atlas_layers > max_pages && !resize_atlas(max_pages)) {
		return;
	}
	const uint32_t atlas_extent = place_material_tiles(placements, max_pages * PAGE_TRIANGLES);
	HashMap<MaterialKey, uint32_t, MaterialKeyHasher> placement_offsets;
	for (const MaterialPlacement &placement : placements) {
		placement_offsets.insert(placement.key, placement.first);
	}
	MeshStorage *meshes = MeshStorage::get_singleton();
	MaterialStorage *materials = MaterialStorage::get_singleton();
	if (p_instances.size() > MAX_INSTANCES || p_lights.size() > MAX_LIGHTS) {
		WARN_PRINT_ONCE("RT GI scene exceeds its bounded instance/light capacity; GI is suppressed.");
		return;
	}
	LocalVector<RD::AccelerationStructureInstance> instances;
	LocalVector<HitData> hits;
	const bool emissive_sampling = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/enabled")) && bool(GLOBAL_GET("rendering/global_illumination/amd_gi/emissive_sampling"));
	LocalVector<EmitterBatch> emitter_batches;
	emitter_count = 0;
	uint32_t resident_pages = 0;
	uint32_t tile_cursor = 0;
	uint32_t prepared_pages = 0;
	const uint32_t preparation_budget = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/material_preparation_budget")), 1, 4096);
	uint32_t drawn_pages = 0;
	uint32_t copied_pages = 0;
	uint32_t new_signature = HASH_MURMUR3_SEED;
	for (const RendererSceneRender::RaytracingGIInstance &instance : p_instances) {
		InstanceState state;
		state.instance = instance.instance;
		state.element = instance.element;
		Color instance_color(1, 1, 1, 1);
		Color instance_custom(0, 0, 0, 0);
		if (instance.multimesh.is_valid()) {
			if (meshes->multimesh_uses_indirect(instance.multimesh)) {
				WARN_PRINT_ONCE("RT GI cannot collect GPU-indirect MultiMesh transforms; GI is suppressed.");
				return;
			}
			if (meshes->multimesh_uses_colors(instance.multimesh)) {
				instance_color = meshes->multimesh_instance_get_color(instance.multimesh, instance.element);
			}
			if (meshes->multimesh_uses_custom_data(instance.multimesh)) {
				instance_custom = meshes->multimesh_instance_get_custom_data(instance.multimesh, instance.element);
			}
		}
		state.transform = instance.transform;
		state.bounds = instance.world_bounds;
		if (instance.mesh.is_null()) {
			WARN_PRINT_ONCE("RT GI currently requires MeshInstance3D geometry without lightmaps or material overlays. GI is suppressed for this scene.");
			return;
		}
		const uint32_t first_surface = instances.size();
		for (int surface = 0; surface < meshes->mesh_get_surface_count(instance.mesh); surface++) {
			RID material = RaytracingGIScene::surface_material(instance, surface);
			auto *data = static_cast<RendererSceneRenderImplementation::SceneShaderForwardClustered::MaterialData *>(materials->material_get_data(material, MaterialStorage::SHADER_TYPE_3D));
			bool stochastic_alpha = false;
			if (data && data->shader_data) {
				const auto &shader_data = *data->shader_data;
				// Forward-only transparency includes outline shells, stencil masks
				// and additive effects. It cannot supply opaque transport geometry.
				// Depth-writing blend materials continue below for stochastic coverage.
				if (data->next_pass.is_null() && shader_data.uses_alpha_pass() && !shader_data.uses_depth_in_alpha_pass() && shader_data.depth_draw != RendererSceneRenderImplementation::SceneShaderForwardClustered::ShaderData::DEPTH_DRAW_ALWAYS && !shader_data.casts_shadows()) {
					continue;
				}
				stochastic_alpha = shader_data.uses_alpha && !shader_data.uses_alpha_clip && shader_data.blend_mode == MaterialStorage::ShaderData::BLEND_MODE_MIX;
				if (data->next_pass.is_valid() || shader_data.uses_screen_texture || shader_data.uses_depth_texture || shader_data.uses_normal_texture || shader_data.uses_position || shader_data.uses_vertex || shader_data.writes_modelview_or_projection || shader_data.uses_blend_alpha || (shader_data.uses_alpha && !shader_data.uses_alpha_clip && !stochastic_alpha) || shader_data.unshaded) {
					WARN_PRINT_ONCE(vformat("RT GI cannot transport material %s (shader '%s'): vertex=%s position=%s transform=%s screen=%s depth=%s normal_texture=%s blend=%s alpha=%s unshaded=%s multipass=%s. GI is suppressed.", material, shader_data.path, shader_data.uses_vertex, shader_data.uses_position, shader_data.writes_modelview_or_projection, shader_data.uses_screen_texture, shader_data.uses_depth_texture, shader_data.uses_normal_texture, shader_data.uses_blend_alpha, shader_data.uses_alpha && !shader_data.uses_alpha_clip, shader_data.unshaded, data->next_pass.is_valid()));
					return;
				}
			}
			const bool share_capture = can_share_capture(material);
			const Transform3D capture_transform = share_capture ? Transform3D() : instance.transform;
			const MaterialKey key{ instance.mesh, material, instance.mesh_instance, share_capture ? RID() : instance.instance, share_capture ? 0u : instance.element, uint32_t(surface), share_capture ? instance_color : Color(1, 1, 1, 1) };
			SurfaceMaterial **cached = material_cache.getptr(key);
			const bool capture_surface = !cached || (*cached)->last_used != material_frame;
			if (capture_surface) {
				tile_cursor = placement_offsets[key];
			}
			const uint64_t material_revision = materials->material_get_content_revision(material);
			Vector<Pair<RID, uint64_t>> texture_revisions;
			bool reusable_pixels = data && data->shader_data && !data->shader_data->uses_time;
			if (reusable_pixels) {
				const auto &shader_data = *data->shader_data;
				for (const auto &uniform : shader_data.uniforms) {
					if (uniform.value.scope != ShaderLanguage::ShaderNode::Uniform::SCOPE_LOCAL) {
						reusable_pixels = false; // Global/instance values retain native per-frame evaluation.
						break;
					}
					if (!uniform.value.is_texture()) {
						continue;
					}
					Variant value = materials->material_get_param(material, uniform.key);
					const Array values = value.get_type() == Variant::ARRAY ? Array(value) : Array();
					const HashMap<int, RID> *defaults = shader_data.default_texture_params.getptr(uniform.key);
					for (int element = 0; element < MAX(1, uniform.value.array_size); element++) {
						RID texture;
						if (value.get_type() == Variant::RID) {
							texture = value;
						} else if (element < values.size() && values[element].get_type() == Variant::RID) {
							texture = values[element];
						}
						if (texture.is_null() && defaults && defaults->has(element)) {
							texture = (*defaults)[element];
						}
						if (texture.is_valid()) {
							RID storage;
							uint64_t content_revision = 0;
							if (!TextureStorage::get_singleton()->texture_get_content_revision(texture, storage, content_revision)) {
								reusable_pixels = false;
								break;
							}
							texture_revisions.push_back(Pair<RID, uint64_t>(storage, content_revision));
						}
					}
					if (!reusable_pixels) {
						break;
					}
				}
			}
			const RaytracingGeometry::Surface *geometry = p_geometry.get_surface(instance.mesh, instance.mesh_instance, surface, true);
			if (!geometry) {
				return; // Budget may defer geometry; never trace a partial scene.
			}
			const uint32_t triangles = (geometry->index_count ? geometry->index_count : geometry->vertex_count) / 3;
			// Pack surfaces by 32-triangle rows instead of wasting a full 1024-tile
			// array layer on every small mesh. Surface IDs still index one hit record.
			const uint32_t surface_tiles = ((triangles + 31) / 32) * 32;
			if (triangles == 0 || (capture_surface && tile_cursor + surface_tiles > max_pages * PAGE_TRIANGLES) || instances.size() == MAX_INSTANCES) {
				static const bool trace_failure = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_MATERIALS").is_empty();
				if (trace_failure) {
					print_line(vformat("GI failed preparation: frame=%d prepared=%d drawn=%d copied=%d tiles=%d limit=%d", material_frame, prepared_pages, drawn_pages, copied_pages, tile_cursor, max_pages * PAGE_TRIANGLES));
				}
				WARN_PRINT_ONCE(vformat("RT GI capacity exceeded: requested atlas tiles=%d, available=%d, surface triangles=%d, instances=%d/%d. GI is suppressed, not partially rendered.", tile_cursor + surface_tiles, max_pages * PAGE_TRIANGLES, triangles, instances.size(), MAX_INSTANCES));
				return;
			}
			if (capture_surface) {
				const uint32_t required = (tile_cursor + surface_tiles + PAGE_TRIANGLES - 1) / PAGE_TRIANGLES;
				if (required > atlas_layers && !resize_atlas(MIN(max_pages, Math::next_power_of_2(required)))) {
					return;
				}
			}
			// Copy before another cache request can invalidate the descriptor pointer.
			RD::AccelerationStructureInstance rd_instance;
			rd_instance.blas = geometry->blas;
			void *source_surface = meshes->mesh_get_surface(instance.mesh, uint32_t(surface));
			const uint64_t data_revision = meshes->mesh_surface_get_data_revision(source_surface);
			const RID source_vertices = meshes->mesh_surface_get_vertex_buffer(source_surface);
			const uint64_t pose_revision = instance.mesh_instance.is_valid() ? meshes->mesh_instance_get_last_change(instance.mesh_instance, surface) : 0;
			state.pose_signature = hash_murmur3_one_64(pose_revision, state.pose_signature);
			rd_instance.transform = instance.transform;
			rd_instance.id = instances.size();
			rd_instance.mask = 0xFF;
			rd_instance.flags = RD::ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT;
			rd_instance.hit_sbt_range = RD::HitShaderBindingTableRange(int64_t(1) << 32);
			if (!cached) {
				material_cache.insert(key, memnew(SurfaceMaterial));
				cached = material_cache.getptr(key);
			}
			SurfaceMaterial &surface_material = **cached;
			if (capture_surface) {
				if (surface_material.last_used + 1 != material_frame) {
					for (MaterialPage &page : surface_material.pages) {
						page.atlas_tile = UINT32_MAX;
					}
				}
				surface_material.first_tile = tile_cursor;
				surface_material.allocated_tiles = surface_tiles;
				uint32_t capture_index = 0;
				LocalVector<MaterialPage> &material_pages = surface_material.pages;
				for (uint32_t first_triangle = 0; first_triangle < triangles;) {
					// Source chunks stay fixed when preceding atlas surfaces enter/leave.
					const uint32_t count = MIN(triangles - first_triangle, PAGE_TRIANGLES);
					if (capture_index == material_pages.size()) {
						MaterialPage entry;
						entry.capture = memnew(RaytracingMaterialCapture);
						material_pages.push_back(entry);
					}
					MaterialPage &entry = material_pages[capture_index];
					RaytracingMaterialCapture &capture = *entry.capture;
					if (entry.mesh != instance.mesh || entry.source_vertices != source_vertices || entry.data_revision != data_revision || entry.surface != uint32_t(surface) || entry.first_triangle != first_triangle || entry.triangle_count != count) {
						if (prepared_pages == preparation_budget) {
							// Completed pages persist. Resume next scene update without
							// publishing a partial TLAS or stale hit-material mapping.
							static const bool trace_preparation = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_MATERIALS").is_empty();
							if (trace_preparation) {
								print_line(vformat("GI material preparation pending: prepared=%d budget=%d", prepared_pages, preparation_budget));
							}
							return;
						}
						// A failed preparation must remain invalid on the next frame.
						entry.source_vertices = RID();
						entry.pixels_valid = false;
						if (capture.prepare(instance.mesh, surface, first_triangle, count, tile_size) != OK) {
							return;
						}
						entry.mesh = instance.mesh;
						entry.source_vertices = source_vertices;
						entry.data_revision = data_revision;
						entry.surface = surface;
						entry.first_triangle = first_triangle;
						entry.triangle_count = count;
						prepared_pages++;
					}
					if (!reusable_pixels || !entry.pixels_valid || entry.mesh_instance != instance.mesh_instance || entry.pose_revision != pose_revision || entry.material != material || entry.material_revision != material_revision || entry.texture_revisions != texture_revisions || entry.transform != capture_transform || entry.instance_color != instance_color || entry.instance_custom != instance_custom) {
						entry.pixels_valid = false;
						if (capture.render(capture_transform, material, instance.uniforms_offset, instance.mesh_instance, instance_color, instance_custom, instance.element) != OK) {
							return;
						}
						entry.atlas_tile = UINT32_MAX;
						entry.mesh_instance = instance.mesh_instance;
						entry.pose_revision = pose_revision;
						entry.material = material;
						entry.material_revision = material_revision;
						entry.texture_revisions = texture_revisions;
						entry.transform = capture_transform;
						entry.instance_color = instance_color;
						entry.instance_custom = instance_custom;
						entry.pixels_valid = reusable_pixels;
						drawn_pages++;
						surface_material.pixels_revision = ++pixels_revision;
					}
					if (entry.atlas_tile != tile_cursor) {
						const Size2i size = capture.get_size();
						// A fixed capture chunk can straddle two packed atlas layers.
						// Copy rows without rebuilding source geometry or material pixels.
						for (uint32_t row = 0; row < uint32_t(size.y) / tile_size;) {
							const uint32_t destination_tile = tile_cursor + row * 32u;
							const uint32_t destination_row = (destination_tile % PAGE_TRIANGLES) / 32u;
							const uint32_t rows = MIN(uint32_t(size.y) / tile_size - row, 32u - destination_row);
							for (int channel = 0; channel < 4; channel++) {
								if (rd->texture_copy(capture.get_texture(channel), atlas[channel], Vector3(0, row * tile_size, 0), Vector3(0, destination_row * tile_size, 0), Vector3(size.x, rows * tile_size, 1), 0, 0, 0, destination_tile / PAGE_TRIANGLES) != OK) {
									return;
								}
							}
							row += rows;
						}

						entry.atlas_tile = tile_cursor;
						copied_pages++;
					}
					first_triangle += count;
					tile_cursor += ((count + 31) / 32) * 32;
					capture_index++;
				}
				while (material_pages.size() > capture_index) {
					memdelete(material_pages[material_pages.size() - 1].capture);
					material_pages.resize(material_pages.size() - 1);
				}
				resident_pages += material_pages.size();
				surface_material.last_used = material_frame;
			}
			state.content_signature = hash_murmur3_one_64(instance.mesh.get_id(), state.content_signature);
			state.content_signature = hash_murmur3_one_32(surface, state.content_signature);
			state.content_signature = hash_murmur3_one_64(source_vertices.get_id(), state.content_signature);
			state.content_signature = hash_murmur3_one_64(data_revision, state.content_signature);
			state.content_signature = hash_murmur3_one_64(material.get_id(), state.content_signature);
			state.content_signature = hash_murmur3_one_64(material_revision, state.content_signature);
			state.content_signature = hash_murmur3_one_32(instance.layer_mask, state.content_signature);
			state.content_signature = hash_murmur3_one_32(instance.shadow_surface_mask, state.content_signature);
			for (const Pair<RID, uint64_t> &texture : texture_revisions) {
				state.content_signature = hash_murmur3_one_64(texture.first.get_id(), state.content_signature);
				state.content_signature = hash_murmur3_one_64(texture.second, state.content_signature);
			}
			for (int component = 0; component < 4; component++) {
				state.content_signature = hash_murmur3_one_float(instance_color[component], state.content_signature);
				state.content_signature = hash_murmur3_one_float(instance_custom[component], state.content_signature);
			}
			instances.push_back(rd_instance);
			const bool casts_shadow = surface < 32 ? (instance.shadow_surface_mask & (1u << surface)) != 0 : instance.shadow_surface_mask != 0;
			uint32_t emitter_base = 0;
			// Bound the optional light hierarchy independently of geometry. Overflow
			// remains visible to ordinary hit-emission sampling.
			if (emissive_sampling && data && data->shader_data && data->shader_data->uses_emission && triangles <= 262144u - emitter_count) {
				emitter_base = emitter_count + 1u;
				emitter_batches.push_back({ geometry->vertex_buffer, geometry->index_buffer, instance.transform, geometry->vertex_count, geometry->index_stride, triangles, surface_material.first_tile, emitter_count, geometry->revision, surface_material.pixels_revision });
				emitter_count += triangles;
			}
			hits.push_back({ surface_material.first_tile, emitter_base | (share_capture ? 0x80000000u : 0u) | (stochastic_alpha ? 0x40000000u : 0u), instance.layer_mask, casts_shadow ? instance.layer_mask : 0 });
		}
		if (instances.size() != first_surface) {
			current_instances.push_back(state);
		}
	}
	update_instance_history(current_instances);
	prune_materials(material_frame > 120 ? material_frame - 120 : 0, uint64_t(atlas_mb) * 1024 * 1024 / 4);
	static const bool validate_materials = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_MATERIALS").is_empty();
	if (validate_materials) {
		print_line(vformat("GI material preparation: resident=%d prepared=%d", resident_pages, prepared_pages));
		print_line(vformat("GI material pixels: resident=%d drawn=%d", resident_pages, drawn_pages));
		print_line(vformat("GI material atlas: tiles=%d copied=%d layers=%d tile_size=%d bytes=%d", atlas_extent, copied_pages, atlas_layers, tile_size, uint64_t(atlas_layers) * page_size * page_size * 20u));
	}
	if (instances.is_empty() || p_lights.size() > MAX_LIGHTS) {
		WARN_PRINT_ONCE("RT GI needs geometry within its scene capacity.");
		return;
	}
	LocalVector<LightData> lights;
	LightStorage *storage = LightStorage::get_singleton();
	const bool physical = RendererSceneRenderRD::get_singleton()->is_using_physical_light_units();
	for (RID instance : p_lights) {
		RID light = storage->light_instance_get_base_light(instance);
		const RSE::LightType type = storage->light_get_type(light);
		if (type == RSE::LIGHT_DIRECTIONAL && storage->light_directional_get_sky_mode(light) == RSE::LIGHT_DIRECTIONAL_SKY_MODE_SKY_ONLY) {
			continue;
		}
		if (storage->light_has_projector(light) || storage->light_is_distance_fade_enabled(light)) {
			WARN_PRINT_ONCE("RT GI does not yet support light projectors or distance fades; GI is suppressed.");
			return;
		}
		if (type != RSE::LIGHT_DIRECTIONAL && type != RSE::LIGHT_OMNI && type != RSE::LIGHT_SPOT) {
			WARN_PRINT_ONCE("RT GI does not yet support area lights; GI is suppressed.");
			return;
		}
		const Transform3D transform = storage->light_instance_get_base_transform(instance);
		const Vector3 direction = transform.basis.get_column(2).normalized();
		LightData data = {};
		data.identity[0] = uint32_t(instance.get_id());
		data.identity[1] = uint32_t(instance.get_id() >> 32);
		for (int axis = 0; axis < 3; axis++) {
			data.position[axis] = transform.origin[axis];
			data.direction[axis] = direction[axis];
		}
		data.type = type == RSE::LIGHT_DIRECTIONAL ? 0 : (type == RSE::LIGHT_OMNI ? 1 : 2);
		data.range = storage->light_get_param(light, RSE::LIGHT_PARAM_RANGE);
		data.decay = storage->light_get_param(light, RSE::LIGHT_PARAM_ATTENUATION);
		data.cos_angle = Math::cos(Math::deg_to_rad(storage->light_get_param(light, RSE::LIGHT_PARAM_SPOT_ANGLE)));
		data.spot_attenuation = storage->light_get_param(light, RSE::LIGHT_PARAM_SPOT_ATTENUATION);
		data.mask = storage->light_get_cull_mask(light);
		data.shadows = storage->light_has_shadow(light) ? 1 : 0;
		data.shadow_mask = storage->light_get_shadow_caster_mask(light);
		data.shadow_opacity = storage->light_get_param(light, RSE::LIGHT_PARAM_SHADOW_OPACITY);
		// Native combined lighting cannot separate per-light indirect multipliers.
		// Retain explicit cache shading when those authored values differ.
		feedback_compatible &= storage->light_get_param(light, RSE::LIGHT_PARAM_INDIRECT_ENERGY) == 1.0f;
		float energy = storage->light_get_param(light, RSE::LIGHT_PARAM_ENERGY) * storage->light_get_param(light, RSE::LIGHT_PARAM_INDIRECT_ENERGY);
		if (storage->light_is_negative(light)) {
			energy = -energy;
		}
		if (physical) {
			energy *= storage->light_get_param(light, RSE::LIGHT_PARAM_INTENSITY);
			if (type != RSE::LIGHT_DIRECTIONAL) {
				energy /= type == RSE::LIGHT_OMNI ? 4.0 * Math::PI : Math::PI;
			}
		} else {
			energy *= Math::PI;
		}
		Color color = storage->light_get_color(light).srgb_to_linear() * energy;
		data.color[0] = color.r;
		data.color[1] = color.g;
		data.color[2] = color.b;
		lights.push_back(data);
		// Reservoir indices must continue to refer to the same sorted lights.
		new_signature = hash_murmur3_one_64(instance.get_id(), new_signature);
	}
	bool lighting_cut = previous_lights.size() != lights.size();
	for (uint32_t i = 0; !lighting_cut && i < lights.size(); i++) {
		lighting_cut = !light_history_compatible(lights[i], previous_lights[i]);
	}
	previous_lights = lights;
	if (signature != new_signature || lighting_cut) {
		static const bool trace_history = !OS::get_singleton()->get_environment("GODOT_AMD_GI_TRACE_HISTORY").is_empty();
		if (trace_history) {
			print_line(vformat("AMD GI scene change: light_membership=%s lighting=%s instances=%d lights=%d", signature != new_signature, lighting_cut, instances.size(), lights.size()));
		}
		signature = new_signature;
		lighting_revision++;
	}
	if (!ensure_scene_buffers(instances.size(), lights.size())) {
		return;
	}
	light_count = lights.size();
	if (light_count) {
		rd->buffer_update(light_buffer, 0, lights.size() * sizeof(LightData), lights.ptr());
	}
	rd->buffer_update(hit_buffer, 0, hits.size() * sizeof(HitData), hits.ptr());
	ready = rd->tlas_build(tlas, instances) == OK && update_emitters(emitter_batches);
}

// Extract emissive triangle geometry and build a power hierarchy entirely on GPU.
// Analytic lights occupy a fixed prefix of the same storage binding, keeping the
// GI shader within the existing 32-storage-buffer device requirement.
bool RaytracingGIScene::update_emitters(const LocalVector<EmitterBatch> &p_batches) {
	RD *rd = RD::get_singleton();
	bool changed = previous_emitters.size() != p_batches.size();
	for (uint32_t i = 0; !changed && i < p_batches.size(); i++) {
		changed = !(previous_emitters[i] == p_batches[i]);
	}
	if (!changed && emitter_buffer_valid) {
		return true;
	}
	if (changed) {
		lighting_revision++;
	}
	previous_emitters = p_batches;
	const uint32_t prefix = MAX_LIGHTS * sizeof(LightData);
	rd->buffer_clear(light_buffer, prefix, emitter_capacity * 2u * 64u);
	if (emitter_count == 0) {
		emitter_buffer_valid = true;
		return true;
	}
	if (emitter_version.is_null()) {
		Vector<String> modes;
		modes.push_back("");
		emitter_shader.initialize(modes);
		emitter_version = emitter_shader.version_create();
		emitter_pipeline = rd->compute_pipeline_create(emitter_shader.version_get_shader(emitter_version, 0));
	}
	ERR_FAIL_COND_V(emitter_pipeline.is_null(), false);
	const RID sampler = MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	struct Push {
		float transform[16];
		uint32_t geometry[4]; // first tile, triangle count, index bytes, first emitter
		uint32_t tree[4]; // leaf capacity, parent offset, parent count, pass
	} push = {};
	static_assert(sizeof(Push) == 96);
	push.tree[0] = emitter_capacity;
	RID last_set;
	for (const EmitterBatch &batch : p_batches) {
		LocalVector<RD::Uniform> uniforms;
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, batch.vertices));
		RID indices = batch.indices.is_valid() ? batch.indices : MeshStorage::get_singleton()->get_default_rd_storage_buffer();
		RID padded;
		if (batch.index_stride == 2 && (batch.triangles * 3u) % 2u != 0) {
			padded = rd->storage_buffer_create(batch.triangles * 6u + 2u);
			rd->buffer_copy(indices, padded, 0, 0, batch.triangles * 6u);
			indices = padded;
		}
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 1, indices));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 2, light_buffer));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, Vector<RID>{ sampler, atlas[3] }));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, Vector<RID>{ sampler, atlas[0] }));
		last_set = UniformSetCacheRD::get_singleton()->get_cache_vec(emitter_shader.version_get_shader(emitter_version, 0), 0, uniforms);
		MaterialStorage::store_transform(batch.transform, push.transform);
		push.geometry[0] = batch.first_tile;
		push.geometry[1] = batch.triangles;
		push.geometry[2] = batch.index_stride;
		push.geometry[3] = batch.first_emitter;
		RD::ComputeListID list = rd->compute_list_begin();
		rd->compute_list_bind_compute_pipeline(list, emitter_pipeline);
		rd->compute_list_bind_uniform_set(list, last_set, 0);
		rd->compute_list_set_push_constant(list, &push, sizeof(push));
		rd->compute_list_dispatch_threads(list, batch.triangles, 1, 1);
		rd->compute_list_end();
		if (padded.is_valid()) {
			rd->free_rid(padded);
			last_set = RID();
		}
	}
	// Bind live source descriptors for the tree-only dispatch (never read there).
	if (last_set.is_null()) {
		LocalVector<RD::Uniform> uniforms;
		RID fallback = MeshStorage::get_singleton()->get_default_rd_storage_buffer();
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, fallback));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 1, fallback));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 2, light_buffer));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, Vector<RID>{ sampler, atlas[3] }));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, Vector<RID>{ sampler, atlas[0] }));
		last_set = UniformSetCacheRD::get_singleton()->get_cache_vec(emitter_shader.version_get_shader(emitter_version, 0), 0, uniforms);
	}
	push.tree[3] = 1;
	RD::ComputeListID list = rd->compute_list_begin();
	rd->compute_list_bind_compute_pipeline(list, emitter_pipeline);
	rd->compute_list_bind_uniform_set(list, last_set, 0);
	for (uint32_t count = emitter_capacity / 2u; count > 0; count /= 2u) {
		push.tree[1] = count;
		push.tree[2] = count;
		rd->compute_list_set_push_constant(list, &push, sizeof(push));
		rd->compute_list_dispatch_threads(list, count, 1, 1);
		rd->compute_list_add_barrier(list);
	}
	rd->compute_list_end();
	emitter_buffer_valid = true;
	return true;
}
