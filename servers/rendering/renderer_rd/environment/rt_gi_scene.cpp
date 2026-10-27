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
#include "servers/rendering/rendering_server.h"

using namespace RendererRD;

RaytracingGIScene::RaytracingGIScene() {
}

void RaytracingGIScene::record_exclusion(const char *p_reason, RID p_instance, RID p_resource, int32_t p_surface, uint32_t p_element, const String &p_shader) {
	if (!diagnostic_exclusions_enabled) {
		return;
	}
	const String reason(p_reason);
	diagnostic_exclusion_counts[reason] = int64_t(diagnostic_exclusion_counts.get(reason, 0)) + 1;
	// Grass can contain hundreds of thousands of elements. Keep aggregate counts
	// exact while bounding detailed report memory and main/render thread copying.
	if (diagnostic_exclusions.size() >= 4096) {
		diagnostic_exclusions_dropped++;
		return;
	}
	Dictionary item;
	item["reason"] = reason;
	item["instance"] = p_instance;
	item["resource"] = p_resource;
	item["surface"] = p_surface;
	item["element"] = p_element;
	item["shader"] = p_shader;
	diagnostic_exclusions.push_back(item);
}

Dictionary RaytracingGIScene::get_scene_diagnostics() const {
	Dictionary result;
	result["enabled"] = diagnostic_exclusions_enabled;
	result["ready"] = ready;
	result["frame"] = material_frame;
	result["collected_instances"] = diagnostic_input_instances;
	result["accepted_surfaces"] = diagnostic_accepted_surfaces;
	result["lights"] = light_count;
	result["emissive_triangles"] = emitter_count;
	result["exclusion_counts"] = diagnostic_exclusion_counts.duplicate();
	result["exclusions"] = diagnostic_exclusions.duplicate(true);
	result["exclusions_truncated"] = diagnostic_exclusions_dropped;
	// Collection policies (distance, GI mode and visibility) run before this
	// adapter. This report explicitly describes only the supplied candidates.
	result["scope"] = "transport_candidates_after_scene_collection";
	return result;
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
		RID replacement_tlas = rd->tlas_create(capacity, RD::ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT | RD::ACCELERATION_STRUCTURE_ALLOW_UPDATE_BIT);
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
		tlas_built = false;
		built_tlas_instances.clear();
		built_tlas_geometry_revisions.clear();
		hit_buffer = replacement_hits;
		uploaded_hits.clear();
		instance_capacity = capacity;
	}
	const uint32_t required_emitters = Math::next_power_of_2(MAX(emitter_count, 1u));
	const bool retain_emitters = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/enabled")) && bool(GLOBAL_GET("rendering/global_illumination/amd_gi/emissive_sampling"));
	if (light_buffer.is_null() || p_lights > light_capacity || required_emitters > emitter_storage_capacity || (!retain_emitters && emitter_storage_capacity > 1)) {
		// Physical storage is independent of the active analytic light count.
		// Flashing lights must not move every retained triangle-light record.
		const uint32_t storage_capacity = retain_emitters ? MAX(required_emitters, emitter_storage_capacity) : 1;
		const uint32_t analytic_capacity = MAX(light_capacity, Math::next_power_of_2(MAX(p_lights, 1u)));
		RID replacement = rd->storage_buffer_create(analytic_capacity * sizeof(LightData) + storage_capacity * 64u);
		if (replacement.is_null()) {
			return false;
		}
		const bool preserve_emitters = retain_emitters && emitter_uses_source_materials && emitter_buffer_valid && light_buffer.is_valid();
		if (preserve_emitters && !previous_emitters.is_empty()) {
			const EmitterBatch &last = previous_emitters[previous_emitters.size() - 1];
			const uint32_t retained_count = last.first_emitter + last.triangles;
			// Copy before retiring the old buffer; RD keeps the queued transfer's
			// resources alive. Only active records are needed, not unused capacity.
			if (rd->buffer_copy(light_buffer, replacement, get_emitter_buffer_offset(), analytic_capacity * sizeof(LightData), retained_count * 64u) != OK) {
				rd->free_rid(replacement);
				return false;
			}
			static const bool validate_storage = OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_LIGHT_STORAGE") == "1";
			if (validate_storage) {
				print_line(vformat("AMD GI light storage copy: lights=%d capacity=%d emitters=%d bytes=%d", p_lights, analytic_capacity, retained_count, retained_count * 64u));
			}
		}
		if (light_buffer.is_valid()) {
			rd->free_rid(light_buffer);
		}
		light_buffer = replacement;
		light_capacity = analytic_capacity;
		emitter_storage_capacity = storage_capacity;
		emitter_buffer_valid = preserve_emitters;
	}
	if (emitter_capacity != required_emitters) {
		emitter_capacity = required_emitters;
		emitter_buffer_valid = false;
	}
	return true;
}

RaytracingGIScene::~RaytracingGIScene() {
	for (RID pipeline : emitter_pipelines) {
		if (pipeline.is_valid()) {
			RD::get_singleton()->free_rid(pipeline);
		}
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
void RaytracingGIScene::add_geometry_reads(RD::ComputeListID p_list) const {
	for (RID buffer : geometry_buffers) {
		RD::get_singleton()->compute_list_add_buffer_read(p_list, buffer);
	}
}

void RaytracingGIScene::append_geometry_buffer_reads(LocalVector<RID> &r_buffers) const {
	for (RID buffer : geometry_buffers) {
		r_buffers.push_back(buffer);
	}
}

void RaytracingGIScene::append_uniforms(LocalVector<RD::Uniform> &r_uniforms, RID p_sampler) const {
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_ACCELERATION_STRUCTURE, 0, tlas));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 4, hit_buffer));
	r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 5, light_buffer));
	for (int i = 0; i < 4; i++) {
		r_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 6 + i, Vector<RID>{ p_sampler, atlas[i].is_valid() ? atlas[i] : TextureStorage::get_singleton()->texture_rd_get_default(TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_WHITE) }));
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

RaytracingGIScene::HitData RaytracingGIScene::build_hit_geometry(const RaytracingGeometry::Surface &p_geometry, uint64_t p_format, RID p_normal_buffer) {
	RD *rd = RD::get_singleton();
	HitData hit = {};
	hit.vertex_address = rd->buffer_get_device_address(p_geometry.vertex_buffer);
	hit.index_address = p_geometry.index_buffer.is_valid() ? rd->buffer_get_device_address(p_geometry.index_buffer) : 0;
	hit.index_stride = p_geometry.index_stride;
	if (p_format & RSE::ARRAY_FORMAT_NORMAL) {
		const uint32_t vertex_stride = RenderingServer::get_singleton()->mesh_surface_get_format_vertex_stride(p_format, p_geometry.vertex_count);
		hit.normal_offset = p_geometry.vertex_count * vertex_stride / sizeof(uint32_t);
		hit.normal_stride = RenderingServer::get_singleton()->mesh_surface_get_format_normal_tangent_stride(p_format, p_geometry.vertex_count) / sizeof(uint32_t);
		hit.normal_address = rd->buffer_get_device_address(p_normal_buffer);
		hit.material_flags = (p_format & RSE::ARRAY_FLAG_COMPRESS_ATTRIBUTES) ? 8u : 0u;
	}
	return hit;
}

bool RaytracingGIScene::prepare_geometry(RaytracingGeometry &p_geometry, const GeometryPreparationKey &p_key, GeometryPreparation &r_prepared) {
	const RaytracingGeometry::Surface *geometry = p_geometry.get_surface(p_key.mesh, p_key.mesh_instance, p_key.surface, true);
	if (!geometry) {
		return false;
	}
	// The shared geometry map can reallocate on another lookup. Never retain
	// its borrowed Surface pointer in an instance record or preparation cache.
	r_prepared.geometry = *geometry;
	MeshStorage *meshes = MeshStorage::get_singleton();
	void *surface = meshes->mesh_get_surface(p_key.mesh, p_key.surface);
	ERR_FAIL_NULL_V(surface, false);
	r_prepared.source_vertices = meshes->mesh_surface_get_vertex_buffer(surface);
	r_prepared.source_format = meshes->mesh_surface_get_format(surface);
	r_prepared.data_revision = meshes->mesh_surface_get_data_revision(surface);
	r_prepared.pose_revision = p_key.mesh_instance.is_valid() ? meshes->mesh_instance_get_last_change(p_key.mesh_instance, p_key.surface) : 0;
	r_prepared.normal_buffer = p_key.mesh_instance.is_valid() ? meshes->mesh_instance_get_vertex_buffer(p_key.mesh_instance, p_key.surface) : RID();
	if (r_prepared.normal_buffer.is_null()) {
		r_prepared.normal_buffer = r_prepared.source_vertices;
	}
	r_prepared.update = material_frame;
	return true;
}

bool RaytracingGIScene::same_group_input(const RendererSceneRender::RaytracingGIInstance &p_a, const RendererSceneRender::RaytracingGIInstance &p_b) {
	return p_a.instance == p_b.instance && p_a.mesh == p_b.mesh && p_a.mesh_instance == p_b.mesh_instance && p_a.multimesh == p_b.multimesh && p_a.element == p_b.element && p_a.group_generation == p_b.group_generation && p_a.group_count == p_b.group_count && p_a.transform == p_b.transform && p_a.material_override == p_b.material_override && p_a.materials == p_b.materials && p_a.uniforms_offset == p_b.uniforms_offset && p_a.layer_mask == p_b.layer_mask && p_a.shadow_surface_mask == p_b.shadow_surface_mask;
}

void RaytracingGIScene::update_scene(RaytracingGeometry &p_geometry, const LocalVector<RendererSceneRender::RaytracingGIInstance> &p_instances, const LocalVector<RID> &p_lights) {
	static const bool trace_motion = !OS::get_singleton()->get_environment("GODOT_AMD_GI_TRACE_HISTORY").is_empty();
	static const bool validate_records = OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_SCENE_CACHE") == "1";
	ready = false;
	// Any early return after a partial write invalidates retained metadata.
	// Only a completely prepared, successfully built scene publishes it again.
	const bool previous_groups_valid = retained_groups_valid;
	retained_groups_valid = false;
	retained_group_scratch.clear();
	feedback_compatible = true;
	material_frame++;
	static const bool disable_scene_reuse = OS::get_singleton()->get_environment("GODOT_AMD_GI_DISABLE_SCENE_REUSE") == "1";
	static const bool trace_scene_reuse = OS::get_singleton()->get_environment("GODOT_AMD_GI_TRACE_SCENE_REUSE") == "1";
	uint32_t reused_geometry = 0, prepared_geometry = 0;
	// Retain allocation for sources used on the preceding update, but never
	// consume their metadata before refreshing it for this update's inputs.
	LocalVector<GeometryPreparationKey> expired_geometry;
	for (const auto &entry : geometry_preparations) {
		if (disable_scene_reuse || entry.value.update != material_frame - 1) {
			expired_geometry.push_back(entry.key);
		}
	}
	for (const GeometryPreparationKey &key : expired_geometry) {
		geometry_preparations.erase(key);
	}
	motion_bounds.clear();
	LocalVector<InstanceState> current_instances;
	HashSet<RID> reference_geometry_buffers;
	RD *rd = RD::get_singleton();
	const bool use_source_materials = GLOBAL_GET("rendering/global_illumination/amd_gi/enabled");
	diagnostic_exclusions_enabled = use_source_materials && bool(GLOBAL_GET("rendering/global_illumination/amd_gi/debug/exclusion_reports"));
	diagnostic_exclusion_counts.clear();
	diagnostic_exclusions.clear();
	diagnostic_exclusions_dropped = 0;
	diagnostic_input_instances = p_instances.size();
	diagnostic_accepted_surfaces = 0;
	uint32_t max_pages = 0, atlas_extent = 0;
	HashMap<MaterialKey, uint32_t, MaterialKeyHasher> placement_offsets;
	const uint32_t requested_tile_size = int(GLOBAL_GET("rendering/global_illumination/amd_gi/material_tile_size")) == 4 ? 4 : 8;
	const uint32_t atlas_mb = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/material_atlas_mb")), 8, 512);
	const bool adaptive_resolution = GLOBAL_GET("rendering/global_illumination/amd_gi/material_adaptive_resolution");
	// The uncached transport diagnostic retains its legacy capture adapter.
	// AMD GI reads native source attributes/textures and has no atlas budget.
	if (!use_source_materials) {
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
		max_pages = MIN(uint32_t(rd->limit_get(RD::LIMIT_MAX_TEXTURE_ARRAY_LAYERS)), atlas_budget / (page_size * page_size * 20u));
		if (atlas_layers > max_pages && !resize_atlas(max_pages)) {
			return;
		}
		atlas_extent = place_material_tiles(placements, max_pages * PAGE_TRIANGLES);
		for (const MaterialPlacement &placement : placements) {
			placement_offsets.insert(placement.key, placement.first);
		}
	}
	MeshStorage *meshes = MeshStorage::get_singleton();
	MaterialStorage *materials = MaterialStorage::get_singleton();
	if (!use_source_materials && (p_instances.size() > MAX_INSTANCES || p_lights.size() > MAX_LIGHTS)) {
		WARN_PRINT_ONCE("RT GI scene exceeds its bounded instance/light capacity; GI is suppressed.");
		return;
	}
	LocalVector<RD::AccelerationStructureInstance> &instances = instance_scratch;
	LocalVector<uint64_t> &geometry_revisions = geometry_revision_scratch;
	LocalVector<HitData> &hits = hit_scratch;
	uint32_t surface_cursor = 0;
	const bool emissive_sampling = bool(GLOBAL_GET("rendering/global_illumination/amd_gi/enabled")) && bool(GLOBAL_GET("rendering/global_illumination/amd_gi/emissive_sampling"));
	LocalVector<EmitterBatch> &emitter_batches = emitter_batch_scratch;
	uint32_t emitter_batch_cursor = 0;
	emitter_count = 0;
	uint32_t resident_pages = 0;
	uint32_t tile_cursor = 0;
	uint32_t prepared_pages = 0;
	const uint32_t preparation_budget = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/material_preparation_budget")), 1, 4096);
	uint32_t drawn_pages = 0;
	uint32_t copied_pages = 0;
	uint32_t new_signature = HASH_MURMUR3_SEED;
	if (use_source_materials) {
		source_materials.begin_frame();
	} else {
		source_materials.clear();
	}
	packed_instance_transforms.resize(p_instances.size());
	uint32_t instance_index = 0;
	uint32_t repacked_transforms = 0;
	static const bool disable_retained_groups = OS::get_singleton()->get_environment("GODOT_AMD_GI_DISABLE_RETAINED_GROUPS") == "1";
	static const bool trace_retained_groups = OS::get_singleton()->get_environment("GODOT_AMD_GI_TRACE_RETAINED_GROUPS") == "1";
	const bool retain_groups = use_source_materials && !disable_retained_groups && !disable_scene_reuse && !trace_motion && !diagnostic_exclusions_enabled;
	uint32_t reused_groups = 0, reused_surfaces = 0, oracle_groups = 0, oracle_surfaces = 0, emissive_fallback_surfaces = 0;
	uint32_t reused_emitter_batches = 0, reused_emitter_triangles = 0, oracle_emitter_batches = 0, oracle_emitter_triangles = 0;
	uint32_t group_begin = 0, group_end = 0, group_first_instance = 0;
	RetainedGroup current_group;
	bool group_active = false, group_oracle = false, group_reused = false;
	uint32_t oracle_surface_count = 0, oracle_batch_count = 0, oracle_triangle_count = 0, oracle_accepted_instances = 0;
	LocalVector<RecordRange> changed_surface_ranges, changed_emitter_ranges;
	auto append_range = [](LocalVector<RecordRange> &r_ranges, uint32_t p_begin, uint32_t p_end) {
		if (p_begin == p_end) {
			return;
		}
		if (!r_ranges.is_empty() && r_ranges[r_ranges.size() - 1].end == p_begin) {
			r_ranges[r_ranges.size() - 1].end = p_end;
		} else {
			r_ranges.push_back({ p_begin, p_end });
		}
	};
	auto finish_group = [&]() -> bool {
		if (!group_active) {
			return true;
		}
		current_group.surface_count = surface_cursor - current_group.first_surface;
		current_group.accepted_instances = instance_index - group_first_instance;
		current_group.emitter_batches = emitter_batch_cursor - current_group.first_emitter_batch;
		current_group.emitter_triangles = emitter_count - current_group.first_emitter;
		if (group_oracle) {
			ERR_FAIL_COND_V_MSG(current_group.surface_count != oracle_surface_count, false, "AMD GI retained group surface count differs from full reconstruction.");
			ERR_FAIL_COND_V_MSG(current_group.emitter_batches != oracle_batch_count || current_group.emitter_triangles != oracle_triangle_count || current_group.accepted_instances != oracle_accepted_instances, false, "AMD GI retained group emitter/instance counts differ from full reconstruction.");
			print_line(vformat("AMD GI retained group oracle: instance=%s multimesh=%s inputs=%d surfaces=%d matches=true batches=%d triangles=%d", current_group.input.instance, current_group.input.multimesh, current_group.input_count, current_group.surface_count, current_group.emitter_batches, current_group.emitter_triangles));
		}
		// Groups with exclusions or zero-triangle failures are never silently
		// reused. Their eligibility continues through the complete current path.
		current_group.reusable = current_group.reusable && current_group.surface_count == current_group.input_count * uint32_t(current_group.surfaces.size());
		if (current_group.has_emission && !group_reused && !group_oracle) {
			emissive_fallback_surfaces += current_group.surface_count;
		}
		if (!group_reused && !group_oracle) {
			append_range(changed_surface_ranges, current_group.first_surface, surface_cursor);
			append_range(changed_emitter_ranges, current_group.first_emitter_batch, emitter_batch_cursor);
		}
		retained_group_scratch.push_back(current_group);
		return true;
	};
	for (uint32_t input_index = 0; input_index < p_instances.size(); input_index++) {
		const RendererSceneRender::RaytracingGIInstance &instance = p_instances[input_index];
		if (retain_groups && input_index == group_end) {
			if (!finish_group()) {
				return;
			}
			group_active = true;
			group_oracle = false;
			group_reused = false;
			group_begin = input_index;
			group_first_instance = instance_index;
			current_group = RetainedGroup();
			current_group.input = instance;
			current_group.first_surface = surface_cursor;
			current_group.first_emitter_batch = emitter_batch_cursor;
			current_group.first_emitter = emitter_count;
			current_group.emissive_sampling = emissive_sampling;
			const bool complete_multimesh = instance.multimesh.is_valid() && instance.group_generation != 0 && instance.element == 0 && instance.group_count > 0 && instance.group_count <= p_instances.size() - input_index && p_instances[input_index + instance.group_count - 1].instance == instance.instance && p_instances[input_index + instance.group_count - 1].group_generation == instance.group_generation && p_instances[input_index + instance.group_count - 1].element == instance.group_count - 1;
			current_group.input_count = complete_multimesh ? instance.group_count : 1;
			group_end = input_index + current_group.input_count;
			current_group.reusable = retain_groups && instance.mesh.is_valid() && (instance.multimesh.is_null() || complete_multimesh);
			const uint32_t group_index = retained_group_scratch.size();
			const RetainedGroup *previous = previous_groups_valid && group_index < retained_groups.size() ? &retained_groups[group_index] : nullptr;
			bool reuse = current_group.reusable && previous && previous->reusable && same_group_input(instance, previous->input) && current_group.input_count == previous->input_count && surface_cursor == previous->first_surface && previous->surface_count <= hits.size() - MIN(surface_cursor, hits.size()) && uint32_t(previous->surfaces.size()) == uint32_t(meshes->mesh_get_surface_count(instance.mesh));
			// Source emitters contain geometry and IDs, not evaluated emission.
			// Retain them only at the same dense batch/triangle prefixes, including
			// the sampling mode; earlier membership changes must rebuild offsets.
			reuse = reuse && previous->emissive_sampling == emissive_sampling && previous->first_emitter_batch == emitter_batch_cursor && previous->first_emitter == emitter_count && emitter_batches.size() == emissive_ranges.size() && emitter_batch_cursor <= emitter_batches.size() && previous->emitter_batches <= emitter_batches.size() - emitter_batch_cursor;
			// Refresh shared resources in original first-use order. Geometry region
			// writes need polling; material next_pass can change without a content
			// revision. Shader code/next_pass and native base contexts cover both.
			for (uint32_t surface = 0; reuse && surface < uint32_t(previous->surfaces.size()); surface++) {
				const RetainedSurface &old = previous->surfaces[surface];
				const RID material = RaytracingGIScene::surface_material(instance, surface);
				auto *data = static_cast<RendererSceneRenderImplementation::SceneShaderForwardClustered::MaterialData *>(materials->material_get_data(material, MaterialStorage::SHADER_TYPE_3D));
				const bool has_shader = data && data->shader_data;
				// The owning String keeps shared COW storage alive. Identity avoids
				// scanning unchanged shader text once per parent; edits still fall
				// back to complete content equality when the allocation changes.
				reuse = old.material == material && old.has_shader == has_shader && (!has_shader || ((old.shader_code.ptr() == data->shader_data->code.ptr() || old.shader_code == data->shader_data->code) && old.next_pass == data->next_pass));
				if (!reuse) {
					break;
				}
				const GeometryPreparationKey key{ instance.mesh, instance.mesh_instance, surface };
				GeometryPreparation *prepared = geometry_preparations.getptr(key);
				if (!prepared || prepared->update != material_frame) {
					GeometryPreparation current;
					if (!prepare_geometry(p_geometry, key, current)) {
						return;
					}
					prepared = &geometry_preparations.insert(key, current)->value;
					prepared_geometry++;
				}
				reuse = old.geometry == *prepared;
				if (reuse) {
					RaytracingMaterialSource::Context context;
					Error error = source_materials.prepare_surface(material, instance.mesh, surface, context);
					if (error != OK && error != ERR_UNAVAILABLE) {
						return;
					}
					reuse = error == OK && memcmp(&old.context, &context, sizeof(context)) == 0;
				}
			}
			if (reuse) {
				current_group = *previous;
				if (validate_records) {
					group_oracle = true;
					oracle_surface_count = previous->surface_count;
					oracle_batch_count = previous->emitter_batches;
					oracle_triangle_count = previous->emitter_triangles;
					oracle_accepted_instances = previous->accepted_instances;
					oracle_groups++;
					oracle_surfaces += previous->surface_count;
					oracle_emitter_batches += previous->emitter_batches;
					oracle_emitter_triangles += previous->emitter_triangles;
				} else {
					if (!source_materials.retain_contexts(previous->surface_count)) {
						return;
					}
					surface_cursor += previous->surface_count;
					instance_index += previous->accepted_instances;
					emitter_batch_cursor += previous->emitter_batches;
					emitter_count += previous->emitter_triangles;
					diagnostic_accepted_surfaces += previous->surface_count;
					group_reused = true;
					reused_groups++;
					reused_surfaces += previous->surface_count;
					reused_emitter_batches += previous->emitter_batches;
					reused_emitter_triangles += previous->emitter_triangles;
					input_index = group_end - 1;
					continue;
				}
			}
			if (!group_oracle) {
				current_group.surfaces.clear();
			}
		}
		// Rejected effects (such as an additive muzzle flare) must not shift the
		// transform cache for every supported object following them in RID order.
		PackedInstanceTransform &packed_transform = packed_instance_transforms[instance_index];
		bool transform_prepared = false;
		InstanceState state;
		state.instance = instance.instance;
		state.element = instance.element;
		Color instance_color(1, 1, 1, 1);
		Color instance_custom(0, 0, 0, 0);
		if (instance.multimesh.is_valid()) {
			if (meshes->multimesh_uses_indirect(instance.multimesh)) {
				record_exclusion("gpu_indirect_multimesh", instance.instance, instance.multimesh, -1, instance.element);
				WARN_PRINT_ONCE("RT GI cannot collect GPU-indirect MultiMesh transforms; this MultiMesh is omitted from the transport scene.");
				if (use_source_materials) {
					continue;
				}
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
			record_exclusion("unsupported_geometry_overlay_or_lightmap", instance.instance, RID(), -1, instance.element);
			WARN_PRINT_ONCE("RT GI cannot transport this geometry class/overlay/lightmap combination; the instance is omitted from the transport scene.");
			if (use_source_materials) {
				continue;
			}
			return;
		}
		const uint32_t first_surface = surface_cursor;
		for (int surface = 0; surface < meshes->mesh_get_surface_count(instance.mesh); surface++) {
			RID material = RaytracingGIScene::surface_material(instance, surface);
			auto *data = static_cast<RendererSceneRenderImplementation::SceneShaderForwardClustered::MaterialData *>(materials->material_get_data(material, MaterialStorage::SHADER_TYPE_3D));
			bool stochastic_alpha = false;
			uint32_t material_flags = 0;
			if (data && data->shader_data) {
				const auto &shader_data = *data->shader_data;
				material_flags = uint32_t(shader_data.uses_alpha || shader_data.uses_alpha_clip || shader_data.uses_discard);
				material_flags |= uint32_t(shader_data.cull_mode == RSE::CULL_MODE_BACK) << 1;
				material_flags |= uint32_t(shader_data.cull_mode == RSE::CULL_MODE_FRONT) << 2;
				// Approved native encoding: an EMISSION-writing program has a unit
				// base factor, independent of its sampled texture or procedural phase.
				material_flags |= uint32_t(shader_data.uses_emission) << 4;
				// Forward-only transparency includes outline shells, stencil masks
				// and additive effects. It cannot supply opaque transport geometry.
				// Depth-writing blend materials continue below for stochastic coverage.
				if (data->next_pass.is_null() && shader_data.uses_alpha_pass() && !shader_data.uses_depth_in_alpha_pass() && shader_data.depth_draw != RendererSceneRenderImplementation::SceneShaderForwardClustered::ShaderData::DEPTH_DRAW_ALWAYS && !shader_data.casts_shadows()) {
					record_exclusion("forward_only_transparency", instance.instance, material, surface, instance.element, shader_data.path);
					continue;
				}
				stochastic_alpha = shader_data.uses_alpha && !shader_data.uses_alpha_clip && shader_data.blend_mode == MaterialStorage::ShaderData::BLEND_MODE_MIX;
				if (data->next_pass.is_valid() || shader_data.uses_screen_texture || shader_data.uses_depth_texture || shader_data.uses_normal_texture || shader_data.uses_position || shader_data.uses_vertex || shader_data.writes_modelview_or_projection || shader_data.uses_blend_alpha || (shader_data.uses_alpha && !shader_data.uses_alpha_clip && !stochastic_alpha) || shader_data.unshaded) {
					const char *reason = data->next_pass.is_valid() ? "material_next_pass" : shader_data.uses_screen_texture ? "material_screen_texture"
							: shader_data.uses_depth_texture																 ? "material_depth_texture"
							: shader_data.uses_normal_texture																 ? "material_screen_normal_texture"
							: shader_data.uses_position																		 ? "material_position_override"
							: shader_data.uses_vertex																		 ? "material_vertex_displacement"
							: shader_data.writes_modelview_or_projection													 ? "material_transform_override"
							: shader_data.uses_blend_alpha																	 ? "material_blend_alpha"
							: shader_data.unshaded																			 ? "material_unshaded"
																															 : "material_unsupported_alpha";
					record_exclusion(reason, instance.instance, material, surface, instance.element, shader_data.path);
					WARN_PRINT_ONCE(vformat("RT GI cannot transport material %s (shader '%s'): vertex=%s position=%s transform=%s screen=%s depth=%s normal_texture=%s blend=%s alpha=%s unshaded=%s multipass=%s. This surface is omitted from AMD GI transport.", material, shader_data.path, shader_data.uses_vertex, shader_data.uses_position, shader_data.writes_modelview_or_projection, shader_data.uses_screen_texture, shader_data.uses_depth_texture, shader_data.uses_normal_texture, shader_data.uses_blend_alpha, shader_data.uses_alpha && !shader_data.uses_alpha_clip, shader_data.unshaded, data->next_pass.is_valid()));
					if (use_source_materials) {
						continue;
					}
					return;
				}
			}
			const bool share_capture = !use_source_materials && can_share_capture(material);
			const Transform3D capture_transform = share_capture ? Transform3D() : instance.transform;
			const MaterialKey key{ instance.mesh, material, instance.mesh_instance, share_capture ? RID() : instance.instance, share_capture ? 0u : instance.element, uint32_t(surface), share_capture ? instance_color : Color(1, 1, 1, 1) };
			SurfaceMaterial **cached = use_source_materials ? nullptr : material_cache.getptr(key);
			const bool capture_surface = !use_source_materials && (!cached || (*cached)->last_used != material_frame);
			if (capture_surface) {
				tile_cursor = placement_offsets[key];
			}
			const uint64_t material_revision = (!use_source_materials || trace_motion) ? materials->material_get_content_revision(material) : 0;
			Vector<Pair<RID, uint64_t>> texture_revisions;
			bool reusable_pixels = !use_source_materials && data && data->shader_data && !data->shader_data->uses_time;
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
			const GeometryPreparationKey preparation_key{ instance.mesh, instance.mesh_instance, uint32_t(surface) };
			GeometryPreparation uncached_preparation;
			GeometryPreparation *preparation = use_source_materials && !disable_scene_reuse ? geometry_preparations.getptr(preparation_key) : nullptr;
			if (!preparation || preparation->update != material_frame) {
				if (!prepare_geometry(p_geometry, preparation_key, uncached_preparation)) {
					if (validate_records) {
						print_line(vformat("AMD GI retained preparation deferred: instance=%s surface=%d", instance.instance, surface));
					}
					return; // Budget may defer geometry; never trace a partial scene.
				}
				prepared_geometry++;
				if (use_source_materials && !disable_scene_reuse) {
					preparation = &geometry_preparations.insert(preparation_key, uncached_preparation)->value;
				} else {
					preparation = &uncached_preparation;
				}
			} else {
				reused_geometry++;
				if (validate_records) {
					ERR_FAIL_COND_MSG(!prepare_geometry(p_geometry, preparation_key, uncached_preparation) || !(*preparation == uncached_preparation), "AMD GI shared geometry preparation differs from current uncached source.");
				}
			}
			const RaytracingGeometry::Surface *geometry = &preparation->geometry;
			const uint32_t triangles = (geometry->index_count ? geometry->index_count : geometry->vertex_count) / 3;
			// Pack surfaces by 32-triangle rows instead of wasting a full 1024-tile
			// array layer on every small mesh. Surface IDs still index one hit record.
			const uint32_t surface_tiles = ((triangles + 31) / 32) * 32;
			if (triangles == 0 || (capture_surface && tile_cursor + surface_tiles > max_pages * PAGE_TRIANGLES) || (!use_source_materials && surface_cursor == MAX_INSTANCES)) {
				static const bool trace_failure = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_MATERIALS").is_empty();
				if (trace_failure) {
					print_line(vformat("GI failed preparation: frame=%d prepared=%d drawn=%d copied=%d tiles=%d limit=%d", material_frame, prepared_pages, drawn_pages, copied_pages, tile_cursor, max_pages * PAGE_TRIANGLES));
				}
				WARN_PRINT_ONCE(vformat("RT GI capacity exceeded: requested atlas tiles=%d, available=%d, surface triangles=%d, instances=%d/%d. GI is suppressed, not partially rendered.", tile_cursor + surface_tiles, max_pages * PAGE_TRIANGLES, triangles, surface_cursor, MAX_INSTANCES));
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
			const uint64_t data_revision = (!use_source_materials || trace_motion) ? preparation->data_revision : 0;
			const RID source_vertices = preparation->source_vertices;
			const uint64_t pose_revision = (!use_source_materials || trace_motion) ? preparation->pose_revision : 0;
			if (trace_motion) {
				state.pose_signature = hash_murmur3_one_64(pose_revision, state.pose_signature);
			}
			rd_instance.transform = instance.transform;
			rd_instance.id = surface_cursor;
			rd_instance.mask = 0xFF;
			// Godot's native clockwise winding requires the Vulkan facing flip.
			// BLAS front-face classification is independent of instance mirroring.
			rd_instance.flags = RD::ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT | RD::ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FLIP_FACING_BIT;
			if ((material_flags & 1u) != 0u) {
				rd_instance.flags.set_flag(RD::ACCELERATION_STRUCTURE_INSTANCE_FORCE_NO_OPAQUE_BIT);
			}
			rd_instance.hit_sbt_range = RD::HitShaderBindingTableRange(int64_t(1) << 32);
			if (!use_source_materials && !cached) {
				material_cache.insert(key, memnew(SurfaceMaterial));
				cached = material_cache.getptr(key);
			}
			SurfaceMaterial source_surface_material;
			SurfaceMaterial &surface_material = use_source_materials ? source_surface_material : **cached;
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
						if (capture.render(capture_transform, material, instance.uniforms_offset, instance.mesh_instance, instance_color, instance_custom, instance.element, true) != OK) {
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
			if (trace_motion) {
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
			}
			const bool first_retained_input = retain_groups && input_index == group_begin && !group_oracle;
			const bool writes_emission = data && data->shader_data && data->shader_data->uses_emission;
			const bool capture_retained_surface = first_retained_input && current_group.reusable;
			RaytracingMaterialSource::Context base_context;
			if (use_source_materials) {
				Error source_error = source_materials.add_surface(material, instance, surface, instance_color, instance_custom, capture_retained_surface ? &base_context : nullptr, group_oracle);
				if (source_error == ERR_UNAVAILABLE) {
					record_exclusion("unsupported_shader_operation", instance.instance, material, surface, instance.element);
					continue; // Unsupported shader operations affect only this surface.
				}
				if (source_error != OK) {
					return;
				}
			}
			if (group_oracle) {
				ERR_FAIL_COND_MSG(surface_cursor >= instances.size(), "AMD GI retained AS record count differs from full reconstruction.");
				const RD::AccelerationStructureInstance &old = instances[surface_cursor];
				ERR_FAIL_COND_MSG(old.blas != rd_instance.blas || old.transform != rd_instance.transform || old.id != rd_instance.id || old.mask != rd_instance.mask || old.hit_sbt_range != rd_instance.hit_sbt_range || old.flags != rd_instance.flags || geometry_revisions[surface_cursor] != geometry->revision, "AMD GI retained AS record differs from full reconstruction.");
			}
			if (surface_cursor == instances.size()) {
				instances.push_back(rd_instance);
				geometry_revisions.push_back(geometry->revision);
			} else {
				instances[surface_cursor] = rd_instance;
				geometry_revisions[surface_cursor] = geometry->revision;
			}
			diagnostic_accepted_surfaces++;
			if (first_retained_input && writes_emission) {
				current_group.has_emission = true;
			}
			if (capture_retained_surface) {
				RetainedSurface retained;
				retained.material = material;
				retained.has_shader = data && data->shader_data;
				if (retained.has_shader) {
					retained.shader_code = data->shader_data->code;
					retained.next_pass = data->next_pass;
				}
				retained.geometry = *preparation;
				retained.context = base_context;
				current_group.surfaces.push_back(retained);
			}
			const bool casts_shadow = surface < 32 ? (instance.shadow_surface_mask & (1u << surface)) != 0 : instance.shadow_surface_mask != 0;
			uint32_t emitter_base = 0;
			// Bound the optional light hierarchy independently of geometry. Overflow
			// remains visible to ordinary hit-emission sampling.
			if (emissive_sampling && data && data->shader_data && data->shader_data->uses_emission && (use_source_materials || triangles <= 262144u - emitter_count)) {
				emitter_base = emitter_count + 1u;
				const EmissiveRange range{ instance.instance, instance.mesh, instance.element, uint32_t(surface), emitter_count, triangles };
				const EmitterBatch batch{ geometry->vertex_buffer, geometry->index_buffer, instance.transform, geometry->vertex_count, geometry->index_stride, triangles, use_source_materials ? rd_instance.id : surface_material.first_tile, emitter_count, geometry->revision, surface_material.pixels_revision };
				if (group_oracle) {
					ERR_FAIL_COND_MSG(emitter_batch_cursor >= emitter_batches.size() || emitter_batch_cursor >= emissive_ranges.size(), "AMD GI retained emitter record count differs from full reconstruction.");
					const EmissiveRange &old_range = emissive_ranges[emitter_batch_cursor];
					ERR_FAIL_COND_MSG(!(emitter_batches[emitter_batch_cursor] == batch) || !(old_range == range) || old_range.first != range.first || old_range.count != range.count, "AMD GI retained emitter batch/range differs from full reconstruction.");
				}
				if (emitter_batch_cursor == emitter_batches.size()) {
					emitter_batches.push_back(batch);
					emissive_ranges.push_back(range);
				} else {
					emitter_batches[emitter_batch_cursor] = batch;
					emissive_ranges[emitter_batch_cursor] = range;
				}
				emitter_batch_cursor++;
				emitter_count += triangles;
			}
			// Pose buffers can alternate without replacing the mesh. Validate the
			// current normal source independently of the retained BLAS metadata.
			const uint64_t source_format = preparation->source_format;
			const RID normal_buffer = preparation->normal_buffer;
			const SurfaceGeometryKey geometry_key{ instance.instance, instance.mesh, instance.mesh_instance, geometry->vertex_buffer, geometry->index_buffer, normal_buffer, instance.element, uint32_t(surface), geometry->vertex_count, geometry->index_stride, geometry->revision, source_format };
			const uint32_t record_index = surface_cursor;
			if (record_index == surface_geometry_records.size()) {
				surface_geometry_records.push_back({ geometry_key, build_hit_geometry(*geometry, source_format, normal_buffer) });
				geometry_buffers_dirty = true;
			} else if (!(surface_geometry_records[record_index].key == geometry_key)) {
				surface_geometry_records[record_index] = { geometry_key, build_hit_geometry(*geometry, source_format, normal_buffer) };
				geometry_buffers_dirty = true;
			}
			HitData hit = surface_geometry_records[record_index].hit;
			hit.first_tile = surface_material.first_tile;
			hit.flags_emitter = emitter_base | (share_capture ? 0x80000000u : 0u) | (stochastic_alpha ? 0x40000000u : 0u);
			hit.mask = instance.layer_mask;
			hit.shadow_mask = casts_shadow ? instance.layer_mask : 0;
			hit.material_flags |= material_flags;
			if (!transform_prepared) {
				// Cache only value-derived matrices, never borrowed geometry or
				// material state. The key also guards collection-order changes.
				if (!packed_transform.valid || packed_transform.instance != instance.instance || packed_transform.element != instance.element || packed_transform.transform != instance.transform) {
					repacked_transforms++;
					packed_transform.instance = instance.instance;
					packed_transform.element = instance.element;
					packed_transform.transform = instance.transform;
					for (uint32_t row = 0; row < 3; row++) {
						for (uint32_t column = 0; column < 3; column++) {
							packed_transform.object_to_world[row * 4 + column] = instance.transform.basis.rows[row][column];
						}
						packed_transform.object_to_world[row * 4 + 3] = instance.transform.origin[row];
					}
					MaterialStorage::store_basis_3x4(instance.transform.basis.inverse().transposed(), packed_transform.normal_to_world);
					packed_transform.valid = true;
				}
				transform_prepared = true;
			}
			memcpy(hit.object_to_world, packed_transform.object_to_world, sizeof(hit.object_to_world));
			memcpy(hit.normal_to_world, packed_transform.normal_to_world, sizeof(hit.normal_to_world));
			if (validate_records) {
				reference_geometry_buffers.insert(geometry->vertex_buffer);
				if (geometry->index_buffer.is_valid()) {
					reference_geometry_buffers.insert(geometry->index_buffer);
				}
				if (source_format & RSE::ARRAY_FORMAT_NORMAL) {
					reference_geometry_buffers.insert(normal_buffer);
				}
				// Reconstruct the original uncached record from current inputs. This
				// deliberately bypasses both retained geometry and packed transforms.
				HitData reference = build_hit_geometry(*geometry, source_format, normal_buffer);
				reference.first_tile = surface_material.first_tile;
				reference.flags_emitter = emitter_base | (share_capture ? 0x80000000u : 0u) | (stochastic_alpha ? 0x40000000u : 0u);
				reference.mask = instance.layer_mask;
				reference.shadow_mask = casts_shadow ? instance.layer_mask : 0;
				reference.material_flags |= material_flags;
				for (uint32_t row = 0; row < 3; row++) {
					for (uint32_t column = 0; column < 3; column++) {
						reference.object_to_world[row * 4 + column] = instance.transform.basis.rows[row][column];
					}
					reference.object_to_world[row * 4 + 3] = instance.transform.origin[row];
				}
				MaterialStorage::store_basis_3x4(instance.transform.basis.inverse().transposed(), reference.normal_to_world);
				// Floating equality treats +0 and -0 as the same transform, just as
				// Transform3D does. Compare matrices numerically and metadata by byte.
				bool matches = memcmp(&hit, &reference, offsetof(HitData, object_to_world)) == 0;
				for (uint32_t component = 0; component < 12; component++) {
					matches = matches && hit.object_to_world[component] == reference.object_to_world[component] && hit.normal_to_world[component] == reference.normal_to_world[component];
				}
				ERR_FAIL_COND_MSG(!matches, vformat("AMD GI cached hit record differs from uncached preparation at surface %d.", record_index));
			}
			if (group_oracle) {
				ERR_FAIL_COND_MSG(surface_cursor >= hits.size() || memcmp(&hits[surface_cursor], &hit, sizeof(hit)) != 0, "AMD GI retained hit record differs from full reconstruction.");
			}
			if (surface_cursor == hits.size()) {
				hits.push_back(hit);
			} else {
				hits[surface_cursor] = hit;
			}
			surface_cursor++;
		}
		if (transform_prepared) {
			instance_index++;
		}
		if (trace_motion && surface_cursor != first_surface) {
			current_instances.push_back(state);
		}
	}
	if (!finish_group()) {
		return;
	}
	// Only a completely successful previous scene proves that untouched CPU
	// ranges match every consumer's published snapshot. A failed partial update
	// or disabled retention must recover through the original complete checks.
	static const bool disable_changed_ranges = OS::get_singleton()->get_environment("GODOT_AMD_GI_DISABLE_CHANGED_RANGES") == "1";
	if (!retain_groups || !previous_groups_valid || disable_changed_ranges) {
		changed_surface_ranges.clear();
		changed_emitter_ranges.clear();
		append_range(changed_surface_ranges, 0, surface_cursor);
		append_range(changed_emitter_ranges, 0, emitter_batch_cursor);
	}
	instances.resize(surface_cursor);
	geometry_revisions.resize(surface_cursor);
	hits.resize(surface_cursor);
	emitter_batches.resize(emitter_batch_cursor);
	emissive_ranges.resize(emitter_batch_cursor);
	packed_instance_transforms.resize(instance_index);
	if (trace_scene_reuse) {
		print_line(vformat("AMD GI geometry reuse: reused=%d prepared=%d", reused_geometry, prepared_geometry));
	}
	static const bool validate_light_storage = OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_LIGHT_STORAGE") == "1";
	if (validate_light_storage) {
		print_line(vformat("AMD GI transform cache: repacked=%d", repacked_transforms));
	}
	geometry_buffers_dirty = geometry_buffers_dirty || surface_geometry_records.size() != hits.size();
	surface_geometry_records.resize(hits.size());
	if (geometry_buffers_dirty) {
		geometry_buffers.clear();
		for (const SurfaceGeometryRecord &record : surface_geometry_records) {
			geometry_buffers.insert(record.key.vertices);
			if (record.key.indices.is_valid()) {
				geometry_buffers.insert(record.key.indices);
			}
			// Packed normals remain in their native (possibly posed/compressed)
			// source buffer even when BLAS positions are dequantized separately.
			if (record.key.format & RSE::ARRAY_FORMAT_NORMAL) {
				geometry_buffers.insert(record.key.normals);
			}
		}
		geometry_buffers_dirty = false;
	}
	if (validate_records) {
		bool matches = reference_geometry_buffers.size() == geometry_buffers.size();
		for (RID buffer : reference_geometry_buffers) {
			matches = matches && geometry_buffers.has(buffer);
		}
		ERR_FAIL_COND_MSG(!matches, "AMD GI retained geometry dependencies differ from full reconstruction.");
	}
	// Bounds are diagnostic only. Reference history uses surface reprojection,
	// never a swept-box invalidation; avoid collecting this unused work normally.
	if (trace_motion) {
		update_instance_history(current_instances);
	}
	if (!use_source_materials) {
		prune_materials(material_frame > 120 ? material_frame - 120 : 0, uint64_t(atlas_mb) * 1024 * 1024 / 4);
	}
	static const bool validate_materials = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_MATERIALS").is_empty();
	if (validate_materials) {
		print_line(vformat("GI material preparation: resident=%d prepared=%d", resident_pages, prepared_pages));
		print_line(vformat("GI material pixels: resident=%d drawn=%d", resident_pages, drawn_pages));
		print_line(vformat("GI material atlas: tiles=%d copied=%d layers=%d tile_size=%d bytes=%d", atlas_extent, copied_pages, atlas_layers, tile_size, uint64_t(atlas_layers) * page_size * page_size * 20u));
	}
	if (instances.is_empty() || (!use_source_materials && p_lights.size() > MAX_LIGHTS)) {
		WARN_PRINT_ONCE("RT GI needs geometry within its scene capacity.");
		return;
	}
	LocalVector<LightData> lights;
	LightStorage *storage = LightStorage::get_singleton();
	const bool physical = RendererSceneRenderRD::get_singleton()->is_using_physical_light_units();
	for (RID instance : p_lights) {
		RID light = storage->light_instance_get_base_light(instance);
		const RSE::LightType type = storage->light_get_type(light);
		if (use_source_materials && storage->light_is_negative(light)) {
			record_exclusion("negative_light", instance, light);
			WARN_PRINT_ONCE("AMD GI does not support negative lights; these lights contribute only to native direct lighting.");
			continue;
		}
		if (type == RSE::LIGHT_DIRECTIONAL && storage->light_directional_get_sky_mode(light) == RSE::LIGHT_DIRECTIONAL_SKY_MODE_SKY_ONLY) {
			record_exclusion("sky_only_light", instance, light);
			continue;
		}
		if (storage->light_has_projector(light) || storage->light_is_distance_fade_enabled(light)) {
			record_exclusion("light_projector_or_distance_fade", instance, light);
			WARN_PRINT_ONCE("RT GI does not yet transport light projectors or distance fades; this light contributes only to native direct lighting.");
			if (use_source_materials) {
				continue;
			}
			return;
		}
		if (type != RSE::LIGHT_DIRECTIONAL && type != RSE::LIGHT_OMNI && type != RSE::LIGHT_SPOT) {
			record_exclusion("unsupported_light_type", instance, light);
			WARN_PRINT_ONCE("RT GI does not yet transport native area lights; this light contributes only to native direct lighting.");
			if (use_source_materials) {
				continue;
			}
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
		// The native feedback attachment applies this same multiplier per light.
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
	struct ReferenceLightOrder {
		bool operator()(const LightData &p_a, const LightData &p_b) const {
			if (p_a.type != p_b.type) {
				return p_a.type < p_b.type;
			}
			return p_a.identity[1] != p_b.identity[1] ? p_a.identity[1] < p_b.identity[1] : p_a.identity[0] < p_b.identity[0];
		}
	};
	lights.sort_custom<ReferenceLightOrder>();
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
	if (use_source_materials && !source_materials.end_frame()) {
		return;
	}
	if (!use_source_materials && light_count != lights.size()) {
		emitter_buffer_valid = false; // The legacy capture path uses a packed prefix.
	}
	light_count = lights.size();
	if (light_count && rd->buffer_update(light_buffer, 0, lights.size() * sizeof(LightData), lights.ptr()) != OK) {
		return;
	}
	// Retain the dense GPU layout. One bounding changed span avoids both a full
	// static-scene upload and thousands of small updates when objects move.
	uint32_t first_changed_hit = hits.size();
	uint32_t last_changed_hit = 0;
	const bool full_hit_scan = uploaded_hits.size() != hits.size();
	for (uint32_t range_index = 0; range_index < (full_hit_scan ? 1u : changed_surface_ranges.size()); range_index++) {
		const RecordRange range = full_hit_scan ? RecordRange{ 0, hits.size() } : changed_surface_ranges[range_index];
		for (uint32_t i = range.begin; i < range.end; i++) {
			if (i >= uploaded_hits.size() || memcmp(&hits[i], &uploaded_hits[i], sizeof(HitData)) != 0) {
				first_changed_hit = MIN(first_changed_hit, i);
				last_changed_hit = i;
			}
		}
	}
	if (validate_records) {
		uint32_t reference_first = hits.size(), reference_last = 0;
		for (uint32_t i = 0; i < hits.size(); i++) {
			if (i >= uploaded_hits.size() || memcmp(&hits[i], &uploaded_hits[i], sizeof(HitData)) != 0) {
				reference_first = MIN(reference_first, i);
				reference_last = i;
			}
		}
		ERR_FAIL_COND_MSG(first_changed_hit != reference_first || last_changed_hit != reference_last, "AMD GI changed hit ranges differ from a complete scan.");
	}
	if (first_changed_hit < hits.size()) {
		const uint32_t changed_bytes = (last_changed_hit - first_changed_hit + 1) * sizeof(HitData);
		if (rd->buffer_update(hit_buffer, first_changed_hit * sizeof(HitData), changed_bytes, hits.ptr() + first_changed_hit) != OK) {
			return;
		}
		uploaded_hits.resize(hits.size());
		memcpy(uploaded_hits.ptr() + first_changed_hit, hits.ptr() + first_changed_hit, changed_bytes);
	} else {
		uploaded_hits.resize(hits.size());
	}
	// Material contexts and geometry lifetimes are still validated every frame.
	// Ordered TLAS IDs index the current hit and material records, and a BLAS
	// rebuilt at the same RID has new bounds even when its handle is unchanged.
	bool rebuild_tlas = !tlas_built || built_tlas_instances.size() != instances.size();
	bool refit_tlas = !rebuild_tlas;
	if (!rebuild_tlas) {
		for (const RecordRange &range : changed_surface_ranges) {
			for (uint32_t i = range.begin; i < range.end; i++) {
				const RD::AccelerationStructureInstance &current = instances[i];
				const RD::AccelerationStructureInstance &built = built_tlas_instances[i];
				const bool same_structure = current.blas == built.blas && current.id == built.id && current.mask == built.mask && current.hit_sbt_range == built.hit_sbt_range && current.flags == built.flags && geometry_revisions[i] == built_tlas_geometry_revisions[i];
				rebuild_tlas |= !same_structure || current.transform != built.transform;
				refit_tlas &= same_structure;
			}
		}
	}
	if (validate_records) {
		bool reference_rebuild = !tlas_built || built_tlas_instances.size() != instances.size();
		bool reference_refit = !reference_rebuild;
		for (uint32_t i = 0; tlas_built && built_tlas_instances.size() == instances.size() && i < instances.size(); i++) {
			const RD::AccelerationStructureInstance &current = instances[i];
			const RD::AccelerationStructureInstance &built = built_tlas_instances[i];
			const bool same_structure = current.blas == built.blas && current.id == built.id && current.mask == built.mask && current.hit_sbt_range == built.hit_sbt_range && current.flags == built.flags && geometry_revisions[i] == built_tlas_geometry_revisions[i];
			reference_rebuild |= !same_structure || current.transform != built.transform;
			reference_refit &= same_structure;
		}
		ERR_FAIL_COND_MSG(rebuild_tlas != reference_rebuild || refit_tlas != reference_refit, "AMD GI changed TLAS ranges differ from a complete scan.");
	}
	if (rebuild_tlas) {
		// Only CPU comparisons are narrowed. Preserve the whole build input and
		// the device's distinct upload allocation for each queued build/refit.
		tlas_built = rd->tlas_build(tlas, instances, refit_tlas) == OK;
		if (tlas_built) {
			built_tlas_instances = instances;
			built_tlas_geometry_revisions = geometry_revisions;
		}
	}
	ready = tlas_built && update_emitters(emitter_batches, use_source_materials, false, &changed_emitter_ranges);
	if (ready && validate_records) {
		const Vector<uint8_t> uploaded = rd->buffer_get_data(hit_buffer, 0, hits.size() * sizeof(HitData));
		const bool matches = uploaded.size() == int64_t(hits.size() * sizeof(HitData)) && memcmp(uploaded.ptr(), hits.ptr(), uploaded.size()) == 0;
		if (!matches) {
			ready = false;
		}
		ERR_FAIL_COND_MSG(!matches, "AMD GI retained hit buffer differs from current CPU records.");
		if (material_frame % 60u == 1u) {
			print_line(vformat("AMD GI scene cache validation: surfaces=%d hit_records_match=true hit_upload_match=true", hits.size()));
		}
	}
	// Opt-in GPU oracle: retained/incremental records must match a complete
	// regeneration byte for byte. Never enabled by a rendering preset.
	if (ready && use_source_materials && emitter_count > 0 && OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_EMITTER_UPDATES") == "1") {
		Vector<uint8_t> incremental = rd->buffer_get_data(light_buffer, get_emitter_buffer_offset(), emitter_count * 64u);
		emitter_buffer_valid = false;
		ready = update_emitters(emitter_batches, true, true);
		Vector<uint8_t> rebuilt = rd->buffer_get_data(light_buffer, get_emitter_buffer_offset(), emitter_count * 64u);
		bool matches = incremental == rebuilt;
		print_line(vformat("AMD GI emitter validation: triangles=%d matches=%s", emitter_count, matches));
		ERR_FAIL_COND_MSG(!matches, "Incremental emitter records differ from a full rebuild.");
	}
	if (ready && retain_groups) {
		SWAP(retained_groups, retained_group_scratch);
		retained_groups_valid = true;
	}
	if (ready && trace_retained_groups) {
		print_line(vformat("AMD GI retained groups: groups=%d reused_groups=%d reused_surfaces=%d oracle_groups=%d oracle_surfaces=%d emissive_fallback_surfaces=%d total_surfaces=%d reused_emitter_batches=%d reused_emitter_triangles=%d oracle_emitter_batches=%d oracle_emitter_triangles=%d", retain_groups ? retained_groups.size() : retained_group_scratch.size(), reused_groups, reused_surfaces, oracle_groups, oracle_surfaces, emissive_fallback_surfaces, hits.size(), reused_emitter_batches, reused_emitter_triangles, oracle_emitter_batches, oracle_emitter_triangles));
	}
}

// Extract emissive triangle geometry and build a power hierarchy entirely on GPU.
// Analytic lights occupy a fixed prefix of the same storage binding, keeping the
// GI shader within the existing 32-storage-buffer device requirement.
bool RaytracingGIScene::update_emitters(const LocalVector<EmitterBatch> &p_batches, bool p_source_materials, bool p_reference, const LocalVector<RecordRange> *p_changed_ranges) {
	RD *rd = RD::get_singleton();
	const bool full_update = !p_source_materials || !emitter_buffer_valid || emitter_uses_source_materials != p_source_materials || previous_emitters.size() != p_batches.size();
	LocalVector<uint32_t> dirty_batches;
	bool changed = emitter_uses_source_materials != p_source_materials || previous_emitters.size() != p_batches.size();
	const bool scan_all = full_update || p_changed_ranges == nullptr;
	for (uint32_t range_index = 0; range_index < (scan_all ? 1u : p_changed_ranges->size()); range_index++) {
		const RecordRange range = scan_all ? RecordRange{ 0, p_batches.size() } : (*p_changed_ranges)[range_index];
		for (uint32_t i = range.begin; i < range.end; i++) {
			const bool batch_changed = i >= previous_emitters.size() || !(previous_emitters[i] == p_batches[i]);
			changed |= batch_changed;
			if (full_update || batch_changed) {
				dirty_batches.push_back(i);
			}
		}
	}
	static const bool validate_ranges = OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_SCENE_CACHE") == "1";
	if (validate_ranges) {
		bool reference_changed = emitter_uses_source_materials != p_source_materials || previous_emitters.size() != p_batches.size();
		uint32_t dirty_index = 0;
		for (uint32_t i = 0; i < p_batches.size(); i++) {
			const bool batch_changed = i >= previous_emitters.size() || !(previous_emitters[i] == p_batches[i]);
			reference_changed |= batch_changed;
			if (full_update || batch_changed) {
				ERR_FAIL_COND_V_MSG(dirty_index >= dirty_batches.size() || dirty_batches[dirty_index++] != i, false, "AMD GI changed emitter ranges missed a batch.");
			}
		}
		ERR_FAIL_COND_V_MSG(reference_changed != changed || dirty_index != dirty_batches.size(), false, "AMD GI changed emitter ranges differ from a complete scan.");
	}
	static const bool validate_storage = OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_LIGHT_STORAGE") == "1";
	if (validate_storage) {
		const uint32_t dispatches = (!changed && emitter_buffer_valid) || emitter_count == 0 ? 0 : dirty_batches.size();
		print_line(vformat("AMD GI light storage: reference=%d lights=%d capacity=%d full=%d dispatches=%d emitters=%d", int(p_reference), light_count, light_capacity, int(full_update), dispatches, emitter_count));
	}
	if (!changed && emitter_buffer_valid) {
		return true;
	}
	if (changed) {
		lighting_revision++;
	}
	// Native records contain geometry and source IDs, not evaluated emission.
	// Unchanged records remain valid across material/time changes. Invalidation
	// or a changed batch count forces a complete update. EmitterBatch also
	// compares source offsets, buffer identities, geometry revisions and transforms,
	// so repacked ranges are regenerated even when the batch count stays the same.
	emitter_buffer_valid = false;
	const uint32_t prefix_count = p_source_materials ? light_capacity : light_count;
	const uint32_t prefix = prefix_count * sizeof(LightData);
	if (full_update) {
		rd->buffer_clear(light_buffer, prefix, emitter_capacity * 64u);
	}
	if (emitter_count == 0) {
		previous_emitters = p_batches;
		emitter_uses_source_materials = p_source_materials;
		emitter_buffer_valid = true;
		return true;
	}
	if (emitter_version.is_null()) {
		Vector<String> modes;
		modes.push_back("");
		modes.push_back("#define SOURCE_MATERIALS\n");
		emitter_shader.initialize(modes);
		emitter_version = emitter_shader.version_create();
	}
	const uint32_t variant = p_source_materials ? 1 : 0;
	RID &emitter_pipeline = emitter_pipelines[variant];
	if (emitter_pipeline.is_null()) {
		emitter_pipeline = rd->compute_pipeline_create(emitter_shader.version_get_shader(emitter_version, variant));
	}
	ERR_FAIL_COND_V(emitter_pipeline.is_null(), false);
	const RID sampler = MaterialStorage::get_singleton()->sampler_rd_get_default(RSE::CANVAS_ITEM_TEXTURE_FILTER_NEAREST, RSE::CANVAS_ITEM_TEXTURE_REPEAT_DISABLED);
	struct Push {
		float transform[16];
		uint32_t geometry[4]; // source instance/tile, triangle count, index bytes, first emitter
		uint32_t prefix[4]; // physical analytic storage slots, independent of active count
	} push = {};
	static_assert(sizeof(Push) == 96);
	push.prefix[0] = prefix_count;
	RID last_set;
	for (uint32_t batch_index : dirty_batches) {
		const EmitterBatch &batch = p_batches[batch_index];
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
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, Vector<RID>{ sampler, atlas[3].is_valid() ? atlas[3] : TextureStorage::get_singleton()->texture_rd_get_default(TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_WHITE) }));
		uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, Vector<RID>{ sampler, atlas[0].is_valid() ? atlas[0] : TextureStorage::get_singleton()->texture_rd_get_default(TextureStorage::DEFAULT_RD_TEXTURE_2D_ARRAY_WHITE) }));
		last_set = UniformSetCacheRD::get_singleton()->get_cache_vec(emitter_shader.version_get_shader(emitter_version, variant), 0, uniforms);
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
	previous_emitters = p_batches;
	emitter_uses_source_materials = p_source_materials;
	emitter_buffer_valid = true;
	return true;
}
