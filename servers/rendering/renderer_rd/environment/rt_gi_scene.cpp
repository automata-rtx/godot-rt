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
	tf.width = PAGE_SIZE;
	tf.height = PAGE_SIZE;
	tf.array_layers = p_layers;
	tf.usage_bits = RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_CAN_COPY_TO_BIT | RD::TEXTURE_USAGE_CAN_COPY_FROM_BIT;
	bool success = true;
	for (int i = 0; i < 4 && success; i++) {
		tf.format = i == 3 ? RD::DATA_FORMAT_R16G16B16A16_SFLOAT : RD::DATA_FORMAT_R8G8B8A8_UNORM;
		replacement[i] = rd->texture_create(tf, RD::TextureView());
		success = replacement[i].is_valid();
		for (uint32_t layer = 0; layer < MIN(atlas_layers, p_layers) && success; layer++) {
			success = rd->texture_copy(atlas[i], replacement[i], Vector3(), Vector3(), Vector3(PAGE_SIZE, PAGE_SIZE, 1), 0, 0, layer, layer) == OK;
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
	if (MAX(1u, p_lights) > light_capacity) {
		const uint32_t capacity = Math::next_power_of_2(MAX(1u, p_lights));
		RID replacement = rd->storage_buffer_create(capacity * sizeof(LightData));
		if (replacement.is_null()) {
			return false;
		}
		if (light_buffer.is_valid()) {
			rd->free_rid(light_buffer);
		}
		light_buffer = replacement;
		light_capacity = capacity;
	}
	return true;
}

RaytracingGIScene::~RaytracingGIScene() {
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

void RaytracingGIScene::prune_materials(uint64_t p_minimum_frame) {
	LocalVector<MaterialKey> unused;
	for (const KeyValue<MaterialKey, SurfaceMaterial *> &entry : material_cache) {
		if (entry.value->last_used < p_minimum_frame) {
			for (MaterialPage &page : entry.value->pages) {
				memdelete(page.capture);
			}
			memdelete(entry.value);
			unused.push_back(entry.key);
		}
	}
	for (const MaterialKey &key : unused) {
		material_cache.erase(key);
	}
}

void RaytracingGIScene::update_scene(RaytracingGeometry &p_geometry, const LocalVector<RendererSceneRender::RaytracingGIInstance> &p_instances, const LocalVector<RID> &p_lights) {
	ready = false;
	prune_materials(material_frame++);
	motion_bounds.clear();
	LocalVector<InstanceState> current_instances;
	RD *rd = RD::get_singleton();
	// Three RGBA8 planes and one RGBA16F plane: 1.25 MiB per layer.
	// Grow on demand; the setting limits the atlas, not the separate native
	// capture targets, expanded geometry, or transport histories.
	const uint32_t atlas_mb = CLAMP(int(GLOBAL_GET("rendering/global_illumination/amd_gi/material_atlas_mb")), 8, 512);
	const uint32_t max_pages = MIN(uint32_t(rd->limit_get(RD::LIMIT_MAX_TEXTURE_ARRAY_LAYERS)), atlas_mb * 1024u * 1024u / (PAGE_SIZE * PAGE_SIZE * 20u));
	if (atlas_layers > max_pages && !resize_atlas(max_pages)) {
		return;
	}
	MeshStorage *meshes = MeshStorage::get_singleton();
	MaterialStorage *materials = MaterialStorage::get_singleton();
	if (p_instances.size() > MAX_INSTANCES || p_lights.size() > MAX_LIGHTS) {
		WARN_PRINT_ONCE("RT GI scene exceeds its bounded instance/light capacity; GI is suppressed.");
		return;
	}
	LocalVector<RD::AccelerationStructureInstance> instances;
	LocalVector<HitData> hits;
	uint32_t resident_pages = 0;
	uint32_t tile_cursor = 0;
	uint32_t prepared_pages = 0;
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
		for (int surface = 0; surface < meshes->mesh_get_surface_count(instance.mesh); surface++) {
			RID material = instance.material_override;
			if (material.is_null() && surface < instance.materials.size()) {
				material = instance.materials[surface];
			}
			if (material.is_null()) {
				material = meshes->mesh_surface_get_material(instance.mesh, surface);
			}
			auto *data = static_cast<RendererSceneRenderImplementation::SceneShaderForwardClustered::MaterialData *>(materials->material_get_data(material, MaterialStorage::SHADER_TYPE_3D));
			if (data && data->shader_data) {
				const auto &shader_data = *data->shader_data;
				if (data->next_pass.is_valid() || shader_data.uses_screen_texture || shader_data.uses_depth_texture || shader_data.uses_normal_texture || shader_data.uses_position || shader_data.uses_vertex || shader_data.writes_modelview_or_projection || shader_data.uses_blend_alpha || (shader_data.uses_alpha && !shader_data.uses_alpha_clip) || shader_data.unshaded) {
					WARN_PRINT_ONCE("RT GI does not support vertex-deformed, screen-reading, blended, or multipass materials. GI is suppressed.");
					return;
				}
			}
			bool share_capture = instance_color == Color(1, 1, 1, 1) && data && data->shader_data && !data->shader_data->uses_instance_transform && !data->shader_data->uses_world_coordinates && !data->shader_data->uses_normal && !data->shader_data->uses_tangent;
			if (share_capture) {
				for (const auto &uniform : data->shader_data->uniforms) {
					if (uniform.value.scope == ShaderLanguage::ShaderNode::Uniform::SCOPE_INSTANCE) {
						share_capture = false;
						break;
					}
				}
			}
			const Transform3D capture_transform = share_capture ? Transform3D() : instance.transform;
			const MaterialKey key{ instance.mesh, material, instance.mesh_instance, share_capture ? RID() : instance.instance, share_capture ? 0u : instance.element, uint32_t(surface) };
			SurfaceMaterial **cached = material_cache.getptr(key);
			const bool capture_surface = !cached || (*cached)->last_used != material_frame;
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
				WARN_PRINT_ONCE("RT GI scene exceeds its bounded material/instance capacity; GI is suppressed, not partially rendered.");
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
				surface_material.first_tile = tile_cursor;
				uint32_t capture_index = 0;
				LocalVector<MaterialPage> &material_pages = surface_material.pages;
				for (uint32_t first_triangle = 0; first_triangle < triangles;) {
					const uint32_t target_tile = tile_cursor % PAGE_TRIANGLES;
					const uint32_t count = MIN(triangles - first_triangle, PAGE_TRIANGLES - target_tile);
					if (capture_index == material_pages.size()) {
						MaterialPage entry;
						entry.capture = memnew(RaytracingMaterialCapture);
						material_pages.push_back(entry);
					}
					MaterialPage &entry = material_pages[capture_index];
					RaytracingMaterialCapture &capture = *entry.capture;
					if (entry.mesh != instance.mesh || entry.source_vertices != source_vertices || entry.data_revision != data_revision || entry.surface != uint32_t(surface) || entry.first_triangle != first_triangle || entry.triangle_count != count) {
						// A failed preparation must remain invalid on the next frame.
						entry.source_vertices = RID();
						entry.pixels_valid = false;
						if (capture.prepare(instance.mesh, surface, first_triangle, count, TILE_SIZE) != OK) {
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
					}
					if (entry.atlas_tile != tile_cursor) {
						const Size2i size = capture.get_size();
						const Vector3 destination(0, (target_tile / 32) * TILE_SIZE, 0);
						for (int channel = 0; channel < 4; channel++) {
							if (rd->texture_copy(capture.get_texture(channel), atlas[channel], Vector3(), destination, Vector3(size.x, size.y, 1), 0, 0, 0, tile_cursor / PAGE_TRIANGLES) != OK) {
								return;
							}
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
			new_signature = hash_murmur3_one_64(instance.instance.get_id(), new_signature);
			new_signature = hash_murmur3_one_64(instance.mesh.get_id(), new_signature);
			new_signature = hash_murmur3_one_32(instance.element, new_signature);
			new_signature = hash_murmur3_one_64(source_vertices.get_id(), new_signature);
			new_signature = hash_murmur3_one_64(data_revision, new_signature);
			new_signature = hash_murmur3_one_64(material.get_id(), new_signature);
			new_signature = hash_murmur3_one_32(instance.layer_mask, new_signature);
			new_signature = hash_murmur3_one_32(instance.shadow_surface_mask, new_signature);
			instances.push_back(rd_instance);
			const bool casts_shadow = surface < 32 ? (instance.shadow_surface_mask & (1u << surface)) != 0 : instance.shadow_surface_mask != 0;
			hits.push_back({ surface_material.first_tile, triangles | (share_capture ? 0x80000000u : 0u), instance.layer_mask, casts_shadow ? instance.layer_mask : 0 });
		}
		const uint32_t index = current_instances.size();
		if (index < previous_instances.size() && previous_instances[index].instance == state.instance && previous_instances[index].element == state.element) {
			const InstanceState &previous = previous_instances[index];
			if (previous.transform != state.transform || previous.pose_signature != state.pose_signature) {
				// The swept bounds include both vacated and newly occupied space.
				// Merge overflow conservatively instead of ignoring extra movers.
				AABB swept = previous.bounds.merge(state.bounds).grow(0.01);
				if (motion_bounds.size() < MAX_MOTION_BOUNDS) {
					motion_bounds.push_back(swept);
				} else {
					motion_bounds[MAX_MOTION_BOUNDS - 1].merge_with(swept);
				}
			}
		}
		current_instances.push_back(state);
	}
	previous_instances = current_instances;
	prune_materials(material_frame);
	static const bool validate_materials = !OS::get_singleton()->get_environment("GODOT_AMD_GI_VALIDATE_MATERIALS").is_empty();
	if (validate_materials) {
		print_line(vformat("GI material preparation: resident=%d prepared=%d", resident_pages, prepared_pages));
		print_line(vformat("GI material pixels: resident=%d drawn=%d", resident_pages, drawn_pages));
		print_line(vformat("GI material atlas: tiles=%d copied=%d layers=%d", tile_cursor, copied_pages, atlas_layers));
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
		signature = new_signature;
		revision++;
	}
	if (!ensure_scene_buffers(instances.size(), lights.size())) {
		return;
	}
	light_count = lights.size();
	if (light_count) {
		rd->buffer_update(light_buffer, 0, lights.size() * sizeof(LightData), lights.ptr());
	}
	rd->buffer_update(hit_buffer, 0, hits.size() * sizeof(HitData), hits.ptr());
	ready = rd->tlas_build(tlas, instances) == OK;
}
