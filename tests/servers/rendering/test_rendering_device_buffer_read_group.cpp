/**************************************************************************/
/*  test_rendering_device_buffer_read_group.cpp                           */
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

#include "tests/test_macros.h"

TEST_FORCE_LINK(test_rendering_device_buffer_read_group)

#ifdef VULKAN_ENABLED
#include "drivers/vulkan/rendering_context_driver_vulkan.h"
#include "servers/rendering/rendering_device.h"

namespace TestRenderingDeviceBufferReadGroup {

struct LocalDevice {
	RenderingDevice *device = memnew(RenderingDevice);
	~LocalDevice() { memdelete(device); }
};

struct ExpectedErrors {
	bool previous = CoreGlobals::print_error_enabled;
	ExpectedErrors() { CoreGlobals::print_error_enabled = false; }
	~ExpectedErrors() { CoreGlobals::print_error_enabled = previous; }
};

struct ComputeListGuard {
	RenderingDevice &device;
	RenderingDevice::ComputeListID list;
	bool active = true;
	explicit ComputeListGuard(RenderingDevice &p_device) : device(p_device), list(device.compute_list_begin()) {}
	void end() {
		device.compute_list_end();
		active = false;
	}
	~ComputeListGuard() {
		if (active) {
			device.compute_list_end();
		}
	}
};

static Vector<uint8_t> initial_data(uint32_t p_value) {
	Vector<uint8_t> bytes;
	bytes.resize(16);
	const uint32_t words[4] = { p_value, 0, 0, 0 };
	memcpy(bytes.ptrw(), words, sizeof(words));
	return bytes;
}

static RID create_shader(RenderingDevice &p_rd, const String &p_source) {
	String error;
	RenderingDevice::ShaderStageSPIRVData stage;
	stage.shader_stage = RenderingDevice::SHADER_STAGE_COMPUTE;
	stage.spirv = p_rd.shader_compile_spirv_from_source(stage.shader_stage, p_source, RenderingDevice::SHADER_LANGUAGE_GLSL, &error, false);
	INFO(error);
	REQUIRE(error.is_empty());
	REQUIRE_FALSE(stage.spirv.is_empty());
	Vector<RenderingDevice::ShaderStageSPIRVData> stages;
	stages.push_back(stage);
	RID shader = p_rd.shader_create_from_spirv(stages);
	REQUIRE(shader.is_valid());
	return shader;
}

static void exercise_device(RenderingDevice &p_rd, RenderingDevice &p_other) {
	using RD = RenderingDevice;
	const char *writer_source = R"GLSL(#version 450
layout(local_size_x=1) in;
layout(set=0,binding=0,std430) writeonly buffer Arguments { uint words[]; } args;
void main() {
    args.words[0]=1; args.words[1]=1; args.words[2]=1; args.words[3]=12345;
}
)GLSL";
	const char *reader_source = R"GLSL(#version 450
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference_uvec2 : require
layout(local_size_x=1) in;
layout(buffer_reference,std430,buffer_reference_align=4) readonly buffer Input { uint words[]; };
layout(set=0,binding=0,std430) writeonly buffer Output { uint words[]; } result;
layout(push_constant,std430) uniform Params {
    uvec2 vertex_address; uvec2 index_address; uvec2 uniform_address;
    uvec2 storage_address; uvec2 indirect_address; uvec2 output_location;
} params;
void main() {
    uint at=params.output_location.x;
    result.words[at+0]=Input(params.vertex_address).words[0];
    result.words[at+1]=Input(params.index_address).words[0];
    result.words[at+2]=Input(params.uniform_address).words[0];
    result.words[at+3]=Input(params.storage_address).words[0];
    result.words[at+4]=Input(params.indirect_address).words[3];
}
)GLSL";
	RID writer_shader = create_shader(p_rd, writer_source);
	RID reader_shader = create_shader(p_rd, reader_source);
	RID writer_pipeline = p_rd.compute_pipeline_create(writer_shader);
	RID reader_pipeline = p_rd.compute_pipeline_create(reader_shader);
	REQUIRE(writer_pipeline.is_valid());
	REQUIRE(reader_pipeline.is_valid());
	// Supplying initial data without AS_STORAGE leaves the vertex/index buffers
	// immutable. Their initial uploads have not been read back or synchronized.
	RID vertex = p_rd.vertex_buffer_create(16, initial_data(11), RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT);
	RID index = p_rd.index_buffer_create(4, RD::INDEX_BUFFER_FORMAT_UINT32, initial_data(22), false, RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT);
	RID uniform = p_rd.uniform_buffer_create(16, initial_data(33), RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT);
	RID storage = p_rd.storage_buffer_create(16, initial_data(44), 0, RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT);
	RID indirect = p_rd.storage_buffer_create(16, {}, RD::STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT, RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT);
	RID output = p_rd.storage_buffer_create(10 * sizeof(uint32_t));
	const RID sources[] = { vertex, index, uniform, storage, indirect };
	for (RID source : sources) {
		REQUIRE(source.is_valid());
		REQUIRE(p_rd.buffer_get_device_address(source) != 0);
	}
	REQUIRE(output.is_valid());
	RD::BufferReadGroup group;
	REQUIRE(p_rd.buffer_read_group_prepare(group, sources) == OK);
	Vector<RD::Uniform> writer_uniforms;
	writer_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, indirect));
	RID writer_set = p_rd.uniform_set_create(writer_uniforms, writer_shader, 0);
	Vector<RD::Uniform> reader_uniforms;
	reader_uniforms.push_back(RD::Uniform(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, output));
	RID reader_set = p_rd.uniform_set_create(reader_uniforms, reader_shader, 0);
	REQUIRE(writer_set.is_valid());
	REQUIRE(reader_set.is_valid());

	// Device isolation and failed publication: none of these lists dispatches.
	{
		ExpectedErrors expected_errors;
		auto other_list = p_other.compute_list_begin();
		CHECK(p_other.compute_list_add_buffer_read_group(other_list, group) == ERR_INVALID_PARAMETER);
		p_other.compute_list_end();
		RD::BufferReadGroup failed_group = group;
		const RID partial[] = { vertex, RID() };
		CHECK(p_rd.buffer_read_group_prepare(failed_group, partial) == ERR_INVALID_PARAMETER);
		auto failed_list = p_rd.compute_list_begin();
		CHECK(p_rd.compute_list_add_buffer_read_group(failed_list, failed_group) == ERR_INVALID_PARAMETER);
		p_rd.compute_list_end();
		const RID missing_address[] = { output };
		CHECK(p_rd.buffer_read_group_prepare(failed_group, missing_address) == ERR_INVALID_PARAMETER);
	}

	struct Push {
		uint64_t addresses[5];
		uint32_t output_offset = 0;
		uint32_t padding = 0;
	} push;
	static_assert(sizeof(Push) == 48);
	for (uint32_t i = 0; i < 5; i++) {
		push.addresses[i] = p_rd.buffer_get_device_address(sources[i]);
	}
	LocalVector<RID> replacements;
	for (uint32_t round = 0; round < 2; round++) {
		if (round == 1) {
			// The already prepared group must observe the new mutable tracker.
			const uint32_t updated_vertex = 111;
			REQUIRE(p_rd.buffer_update(vertex, 0, sizeof(updated_vertex), &updated_vertex) == OK);
		}
		ComputeListGuard list_guard(p_rd);
		auto list = list_guard.list;
		p_rd.compute_list_bind_compute_pipeline(list, writer_pipeline);
		p_rd.compute_list_bind_uniform_set(list, writer_set, 0);
		p_rd.compute_list_dispatch(list, 1, 1, 1);
		p_rd.compute_list_add_barrier(list);
		p_rd.compute_list_bind_compute_pipeline(list, reader_pipeline);
		p_rd.compute_list_bind_uniform_set(list, reader_set, 0);
		for (uint32_t segment = 0; segment < 2; segment++) {
			REQUIRE(p_rd.compute_list_add_buffer_read_group(list, group, true) == OK);
			push.output_offset = segment * 5;
			p_rd.compute_list_set_push_constant(list, &push, sizeof(push));
			// The same argument buffer is both an indirect read and a BDA storage
			// read. The graph must retain the combined usage across each barrier.
			p_rd.compute_list_dispatch_indirect(list, indirect, 0);
			if (segment == 0) {
				p_rd.compute_list_add_barrier(list);
			}
		}
		list_guard.end();
		if (round == 1) {
			// Queued work must retain its driver resources after RID reuse.
			p_rd.free_rid(writer_set);
			for (RID source : sources) {
				p_rd.free_rid(source);
			}
			replacements.push_back(p_rd.vertex_buffer_create(16, initial_data(901), RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT));
			replacements.push_back(p_rd.index_buffer_create(4, RD::INDEX_BUFFER_FORMAT_UINT32, initial_data(902), false, RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT));
			replacements.push_back(p_rd.uniform_buffer_create(16, initial_data(903), RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT));
			replacements.push_back(p_rd.storage_buffer_create(16, initial_data(904), 0, RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT));
			replacements.push_back(p_rd.storage_buffer_create(16, initial_data(905), 0, RD::BUFFER_CREATION_DEVICE_ADDRESS_BIT));
			CHECK(replacements[0] != vertex);
			CHECK(replacements[0].get_local_index() == vertex.get_local_index());
		}
		p_rd.submit();
		p_rd.sync();
		const Vector<uint8_t> result = p_rd.buffer_get_data(output);
		REQUIRE(result.size() == int64_t(10 * sizeof(uint32_t)));
		uint32_t words[10];
		memcpy(words, result.ptr(), sizeof(words));
		for (uint32_t segment = 0; segment < 2; segment++) {
			CHECK(words[segment * 5 + 0] == (round == 0 ? 11 : 111));
			CHECK(words[segment * 5 + 1] == 22);
			CHECK(words[segment * 5 + 2] == 33);
			CHECK(words[segment * 5 + 3] == 44);
			CHECK(words[segment * 5 + 4] == 12345);
		}
	}
	{
		ExpectedErrors expected_errors;
		auto stale_list = p_rd.compute_list_begin();
		CHECK(p_rd.compute_list_add_buffer_read_group(stale_list, group) == ERR_INVALID_PARAMETER);
		p_rd.compute_list_end();
		CHECK(p_rd.buffer_read_group_prepare(group, sources) == ERR_INVALID_PARAMETER);
	}
	for (RID replacement : replacements) {
		p_rd.free_rid(replacement);
	}
	for (RID rid : { reader_set, output, writer_pipeline, reader_pipeline, writer_shader, reader_shader }) {
		p_rd.free_rid(rid);
	}
}

// Requires a real GPU. Normal unit runs skip it; explicit --no-skip plus this
// test's name opts in. Unsupported Vulkan/BDA is a failure, never a silent pass.
TEST_CASE("[RenderingDevice][GPU] Buffer read groups preserve BDA dependencies" * doctest::skip()) {
	RenderingContextDriverVulkan context;
	REQUIRE(context.initialize() == OK);
	LocalDevice first;
	REQUIRE(first.device->initialize(&context) == OK);
	REQUIRE(first.device->has_feature(RenderingDevice::SUPPORTS_BUFFER_DEVICE_ADDRESS));
	LocalDevice second;
	REQUIRE(second.device->initialize(&context) == OK);
	REQUIRE(second.device->has_feature(RenderingDevice::SUPPORTS_BUFFER_DEVICE_ADDRESS));
	REQUIRE(first.device->get_instance_id() != second.device->get_instance_id());
	exercise_device(*first.device, *second.device);
	exercise_device(*second.device, *first.device);
	print_line("Buffer read group GPU validation: two devices, four upload/dispatch/lifetime rounds completed.");
}

} // namespace TestRenderingDeviceBufferReadGroup
#else
TEST_CASE("[RenderingDevice][GPU] Buffer read groups preserve BDA dependencies" * doctest::skip()) {
	FAIL("This explicit GPU regression requires a Vulkan-enabled build.");
}
#endif
