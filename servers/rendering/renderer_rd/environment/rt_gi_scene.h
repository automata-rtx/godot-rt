/**************************************************************************/
/*  rt_gi_scene.h                                                         */
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

#pragma once
#include "servers/rendering/renderer_rd/environment/rt_geometry.h"
#include "servers/rendering/renderer_rd/environment/rt_material_capture.h"
#include "servers/rendering/renderer_rd/environment/rt_material_source.h"
#include "servers/rendering/renderer_rd/shaders/effects/rt_gi_emitters.glsl.gen.h"
#include "servers/rendering/renderer_scene_render.h"

namespace RendererRD {
// Shared hit-material and light adapter for the reference and cached GI paths.
class RaytracingGIScene {
public:
	struct LightData {
		float position[3];
		float range;
		float direction[3];
		uint32_t type;
		float color[3];
		float decay;
		float cos_angle;
		float spot_attenuation;
		uint32_t mask;
		uint32_t shadows;
		float shadow_opacity;
		uint32_t shadow_mask;
		uint32_t identity[2] = {}; // Full light-instance RID, for temporal remapping.
	};
	const LocalVector<LightData> &get_lights() const { return previous_lights; }

	struct EmissiveRange {
		RID instance, mesh;
		uint32_t element, surface, first, count;
		bool operator==(const EmissiveRange &p_other) const {
			return instance == p_other.instance && mesh == p_other.mesh && element == p_other.element && surface == p_other.surface;
		}
		static uint32_t hash(const EmissiveRange &p_key) {
			uint32_t h = hash_murmur3_one_64(p_key.instance.get_id());
			h = hash_murmur3_one_64(p_key.mesh.get_id(), h);
			h = hash_murmur3_one_32(p_key.element, h);
			return hash_murmur3_one_32(p_key.surface, h);
		}
	};
	const LocalVector<EmissiveRange> &get_emissive_ranges() const { return emissive_ranges; }

private:
	bool diagnostic_exclusions_enabled = false;
	Dictionary diagnostic_exclusion_counts;
	Array diagnostic_exclusions;
	uint32_t diagnostic_exclusions_dropped = 0;
	uint32_t diagnostic_input_instances = 0;
	uint32_t diagnostic_accepted_surfaces = 0;
	void record_exclusion(const char *p_reason, RID p_instance, RID p_resource = RID(), int32_t p_surface = -1, uint32_t p_element = 0, const String &p_shader = String());
	RaytracingMaterialSource source_materials;
	LocalVector<EmissiveRange> emissive_ranges;
	// Tile layout must match atlas_position() in rt_gi_transport_inc.glsl.
	static constexpr uint32_t PAGE_TRIANGLES = 1024;
	uint32_t tile_size = 8;
	uint32_t page_size = 256;
	uint32_t configured_tile_size = 0;
	uint32_t configured_atlas_mb = 0;
	bool configured_adaptive_resolution = true;
	static RID surface_material(const RendererSceneRender::RaytracingGIInstance &p_instance, int p_surface);
	static bool can_share_capture(RID p_material);
	// Collection keeps one overflow entry beyond these limits to signal failure.
	static constexpr uint32_t MAX_LIGHTS = RendererSceneRender::MAX_RT_GI_LIGHTS;
	static constexpr uint32_t MAX_INSTANCES = RendererSceneRender::MAX_RT_GI_INSTANCES;
	struct HitData {
		uint32_t first_tile;
		uint32_t flags_emitter; // Bits 31/30: local normals / stochastic opacity; low bits: emitter base + 1.
		uint32_t mask;
		uint32_t shadow_mask = 0;
		uint64_t vertex_address = 0;
		uint64_t index_address = 0;
		uint32_t index_stride = 0;
		uint32_t material_flags = 0; // Alpha-tested and native cull mode.
		uint32_t normal_offset = 0; // Words from the source vertex buffer's beginning.
		uint32_t normal_stride = 0; // Words per vertex; zero if no vertex normal.
		uint64_t normal_address = 0;
		uint32_t padding[2] = {};
		float object_to_world[12] = {}; // Three vec4 rows.
		float normal_to_world[12] = {}; // Padded mat3 columns.
	};

	static_assert(sizeof(HitData) == 160);
	struct PackedInstanceTransform {
		RID instance;
		uint32_t element = 0;
		Transform3D transform;
		float object_to_world[12] = {};
		float normal_to_world[12] = {};
		bool valid = false;
	};
	LocalVector<PackedInstanceTransform> packed_instance_transforms;
	struct GeometryPreparationKey {
		RID mesh, mesh_instance;
		uint32_t surface = 0;
		bool operator==(const GeometryPreparationKey &p_other) const {
			return mesh == p_other.mesh && mesh_instance == p_other.mesh_instance && surface == p_other.surface;
		}
		static uint32_t hash(const GeometryPreparationKey &p_key) {
			uint32_t h = hash_murmur3_one_64(p_key.mesh.get_id());
			h = hash_murmur3_one_64(p_key.mesh_instance.get_id(), h);
			return hash_murmur3_one_32(p_key.surface, h);
		}
	};
	struct GeometryPreparation {
		RaytracingGeometry::Surface geometry;
		RID source_vertices, normal_buffer;
		uint64_t source_format = 0, data_revision = 0, pose_revision = 0;
		uint64_t update = 0;
		bool operator==(const GeometryPreparation &p_other) const {
			return geometry.blas == p_other.geometry.blas && geometry.vertex_buffer == p_other.geometry.vertex_buffer && geometry.index_buffer == p_other.geometry.index_buffer && geometry.vertex_count == p_other.geometry.vertex_count && geometry.index_count == p_other.geometry.index_count && geometry.index_stride == p_other.geometry.index_stride && geometry.revision == p_other.geometry.revision && source_vertices == p_other.source_vertices && normal_buffer == p_other.normal_buffer && source_format == p_other.source_format && data_revision == p_other.data_revision && pose_revision == p_other.pose_revision;
		}
	};
	// Entries own values only. Each unique source is revalidated once per scene
	// update (not once per global frame); successful copies can then be shared.
	HashMap<GeometryPreparationKey, GeometryPreparation, GeometryPreparationKey> geometry_preparations;
	bool prepare_geometry(RaytracingGeometry &p_geometry, const GeometryPreparationKey &p_key, GeometryPreparation &r_prepared);
	struct RetainedSurface {
		RID material, next_pass;
		String shader_code;
		bool has_shader = false;
		GeometryPreparation geometry;
		RaytracingMaterialSource::Context context;
	};
	struct RetainedGroup {
		RendererSceneRender::RaytracingGIInstance input;
		Vector<RetainedSurface> surfaces;
		uint32_t input_count = 1, first_surface = 0, surface_count = 0, accepted_instances = 0;
		uint32_t first_emitter_batch = 0, emitter_batches = 0, first_emitter = 0, emitter_triangles = 0;
		bool reusable = false;
		bool has_emission = false;
		bool emissive_sampling = false;
	};
	LocalVector<RetainedGroup> retained_groups, retained_group_scratch;
	bool retained_groups_valid = false;
	static bool same_group_input(const RendererSceneRender::RaytracingGIInstance &p_a, const RendererSceneRender::RaytracingGIInstance &p_b);
	struct SurfaceGeometryKey {
		RID instance, mesh, mesh_instance, vertices, indices, normals;
		uint32_t element = 0, surface = 0, vertex_count = 0, index_stride = 0;
		uint64_t revision = 0, format = 0;
		bool operator==(const SurfaceGeometryKey &p_other) const {
			return instance == p_other.instance && mesh == p_other.mesh && mesh_instance == p_other.mesh_instance && vertices == p_other.vertices && indices == p_other.indices && normals == p_other.normals && element == p_other.element && surface == p_other.surface && vertex_count == p_other.vertex_count && index_stride == p_other.index_stride && revision == p_other.revision && format == p_other.format;
		}
	};
	struct SurfaceGeometryRecord {
		SurfaceGeometryKey key;
		HitData hit = {};
	};
	LocalVector<SurfaceGeometryRecord> surface_geometry_records;
	LocalVector<HitData> uploaded_hits;
	LocalVector<HitData> hit_scratch;
	LocalVector<RD::AccelerationStructureInstance> instance_scratch;
	LocalVector<uint64_t> geometry_revision_scratch;
	static HitData build_hit_geometry(const RaytracingGeometry::Surface &p_geometry, uint64_t p_format, RID p_normal_buffer);
	HashSet<RID> geometry_buffers;
	bool geometry_buffers_dirty = true;
	static_assert(sizeof(LightData) == 80);
	LocalVector<LightData> previous_lights;
	static bool light_history_compatible(const LightData &p_current, const LightData &p_previous);
	struct MaterialPage {
		RaytracingMaterialCapture *capture = nullptr;
		RID mesh;
		RID source_vertices;
		RID mesh_instance;
		uint64_t pose_revision = 0;
		uint64_t data_revision = 0;
		uint32_t surface = 0;
		uint32_t first_triangle = 0;
		uint32_t triangle_count = 0;
		uint32_t atlas_tile = UINT32_MAX;
		RID material;
		uint64_t material_revision = 0;
		Vector<Pair<RID, uint64_t>> texture_revisions;
		Transform3D transform;
		Color instance_color = Color(1, 1, 1, 1);
		Color instance_custom = Color(0, 0, 0, 0);
		bool pixels_valid = false;
	};
	struct MaterialKey {
		RID mesh;
		RID material;
		RID mesh_instance;
		RID context;
		uint32_t element = 0;
		uint32_t surface = 0;
		Color color = Color(1, 1, 1, 1);
		bool operator==(const MaterialKey &p_other) const {
			return mesh == p_other.mesh && material == p_other.material && mesh_instance == p_other.mesh_instance && context == p_other.context && element == p_other.element && surface == p_other.surface && color == p_other.color;
		}
	};
	struct MaterialKeyHasher {
		static uint32_t hash(const MaterialKey &p_key) {
			uint32_t h = hash_murmur3_one_64(p_key.mesh.get_id());
			h = hash_murmur3_one_64(p_key.material.get_id(), h);
			h = hash_murmur3_one_64(p_key.mesh_instance.get_id(), h);
			h = hash_murmur3_one_64(p_key.context.get_id(), h);
			h = hash_murmur3_one_32(p_key.element, h);
			h = hash_murmur3_one_32(p_key.surface, h);
			for (int i = 0; i < 4; i++) {
				h = hash_murmur3_one_float(p_key.color[i], h);
			}
			return hash_fmix32(h);
		}
	};
	struct MaterialPlacement {
		MaterialKey key;
		uint32_t count = 0;
		uint32_t first = UINT32_MAX;
	};
	uint64_t required_material_tiles(const LocalVector<RendererSceneRender::RaytracingGIInstance> &p_instances, LocalVector<MaterialPlacement> &r_placements) const;
	uint32_t place_material_tiles(LocalVector<MaterialPlacement> &r_placements, uint32_t p_limit) const;
	struct SurfaceMaterial {
		LocalVector<MaterialPage> pages;
		uint32_t first_tile = UINT32_MAX;
		uint32_t allocated_tiles = 0;
		uint64_t last_used = 0;
		uint64_t pixels_revision = 0;
	};
	HashMap<MaterialKey, SurfaceMaterial *, MaterialKeyHasher> material_cache;
	uint64_t material_frame = 0;
	uint64_t pixels_revision = 0;
	void prune_materials(uint64_t p_minimum_frame, uint64_t p_unused_budget = UINT64_MAX);
	struct InstanceState {
		RID instance;
		uint32_t element = 0;
		Transform3D transform;
		AABB bounds;
		uint32_t pose_signature = HASH_MURMUR3_SEED;
		uint32_t content_signature = HASH_MURMUR3_SEED;
	};
	LocalVector<InstanceState> previous_instances;
	LocalVector<AABB> motion_bounds;
	void add_motion_bounds(const AABB &p_bounds);
	void update_instance_history(const LocalVector<InstanceState> &p_instances);

	bool resize_atlas(uint32_t p_layers);
	bool ensure_scene_buffers(uint32_t p_instances, uint32_t p_lights);
	uint32_t atlas_layers = 0;
	uint32_t instance_capacity = 0;
	uint32_t light_capacity = 0;
	RID tlas;
	// Snapshot only successful builds. BLAS revisions also catch in-place
	// rebuilds across an earlier scene-preparation failure.
	LocalVector<RD::AccelerationStructureInstance> built_tlas_instances;
	LocalVector<uint64_t> built_tlas_geometry_revisions;
	bool tlas_built = false;
	RID atlas[4];
	RID hit_buffer;
	RID light_buffer;
	RtGiEmittersShaderRD emitter_shader;
	RID emitter_version, emitter_pipelines[2];
	bool emitter_uses_source_materials = false;
	uint32_t emitter_count = 0;
	uint32_t emitter_capacity = 0;
	uint32_t emitter_storage_capacity = 0;
	struct EmitterBatch {
		RID vertices, indices;
		Transform3D transform;
		uint32_t vertex_count, index_stride, triangles, first_tile, first_emitter;
		uint64_t geometry_revision, pixels_revision;
		bool operator==(const EmitterBatch &p_other) const {
			return vertices == p_other.vertices && indices == p_other.indices && transform == p_other.transform && vertex_count == p_other.vertex_count && index_stride == p_other.index_stride && triangles == p_other.triangles && first_tile == p_other.first_tile && first_emitter == p_other.first_emitter && geometry_revision == p_other.geometry_revision && pixels_revision == p_other.pixels_revision;
		}
	};
	LocalVector<EmitterBatch> previous_emitters;
	LocalVector<EmitterBatch> emitter_batch_scratch;
	struct RecordRange {
		uint32_t begin = 0, end = 0;
	};
	bool emitter_buffer_valid = false;
	bool update_emitters(const LocalVector<EmitterBatch> &p_batches, bool p_source_materials, bool p_reference = false, const LocalVector<RecordRange> *p_changed_ranges = nullptr);
	uint32_t light_count = 0;
	uint32_t signature = 0;
	uint64_t revision = 1;
	uint64_t lighting_revision = 1;
	bool ready = false;
	bool feedback_compatible = true;

public:
	Dictionary get_scene_diagnostics() const;
	const RaytracingMaterialSource &get_source_materials() const { return source_materials; }
	static constexpr uint32_t MAX_MOTION_BOUNDS = 8;
	const LocalVector<AABB> &get_motion_bounds() const { return motion_bounds; }
	bool is_ready() const { return ready; }
	bool is_feedback_compatible() const { return feedback_compatible; }
	uint32_t get_light_count() const { return light_count; }
	uint32_t get_emitter_count() const { return emitter_count; }
	uint32_t get_emitter_buffer_offset() const { return light_capacity * sizeof(LightData); }
	uint32_t get_emitter_capacity() const { return emitter_capacity; }
	uint64_t get_revision() const { return revision; }
	uint64_t get_lighting_revision() const { return lighting_revision; }
	void append_uniforms(LocalVector<RD::Uniform> &r_uniforms, RID p_sampler) const;
	void add_geometry_reads(RD::ComputeListID p_list) const;
	void append_geometry_buffer_reads(LocalVector<RID> &r_buffers) const;
	void update_scene(RaytracingGeometry &p_geometry, const LocalVector<RendererSceneRender::RaytracingGIInstance> &p_instances, const LocalVector<RID> &p_lights);
	RaytracingGIScene();
	~RaytracingGIScene();
};
} // namespace RendererRD
