/**************************************************************************/
/*  test_amd_gi_pipeline_preparation.cpp                                  */
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

TEST_FORCE_LINK(test_amd_gi_pipeline_preparation)

#include "servers/rendering/renderer_rd/environment/amd_gi_pipeline_preparation.h"

namespace TestAMDGiPipelinePreparation {

TEST_CASE("[AMDGI] Pipeline failures retain compatible state and recover with bounded retries") {
	using namespace RendererRD;
	AMDGIPipelinePreparationState state;
	const int scene = 0;
	CHECK_FALSE(state.is_ready(&scene, 1));
	CHECK(state.can_attempt(&scene, 1, 0));
	state.publish(&scene, 1);
	CHECK(state.is_ready(&scene, 1));
	CHECK_FALSE(state.is_ready(&scene, 2));

	// Inject failure in every required pass, including passes after the output
	// sentinel formerly used for readiness. Every partial allocation is freed;
	// the disabled diagnostic pass must neither compile nor make readiness fail.
	constexpr uint32_t pass_count = 7;
	constexpr uint32_t optional_pass = 4;
	for (uint32_t failure = 0; failure < pass_count; failure++) {
		int candidate[pass_count] = {};
		uint32_t allocations = 0;
		uint32_t releases = 0;
		uint32_t calls = 0;
		const uint32_t failed_pass = amd_gi_prepare_pipeline_candidate(candidate, [=](uint32_t p_pass) { return p_pass != optional_pass; }, [&](uint32_t p_pass) {
					calls++;
					if (p_pass == failure) {
						return 0;
					}
					allocations++;
					return int(p_pass + 1); }, [&](int p_pipeline) {
					CHECK(p_pipeline > 0);
					releases++; });
		if (failure == optional_pass) {
			CHECK(failed_pass == pass_count);
			CHECK(calls == pass_count - 1);
			CHECK(releases == 0);
			CHECK(candidate[optional_pass] == 0);
		} else {
			CHECK(failed_pass == failure);
			CHECK(releases == allocations);
			for (int pipeline : candidate) {
				CHECK(pipeline == 0);
			}
			CHECK(state.is_ready(&scene, 1));
			CHECK_FALSE(state.is_ready(&scene, 2));
		}
	}

	uint64_t now = 100;
	CHECK(state.can_attempt(&scene, 2, now));
	const uint64_t expected_delays[] = { 1, 2, 4, 8, 16, 30, 30, 30, 30, 30 };
	uint32_t logged_failures = 0;
	for (uint64_t delay : expected_delays) {
		logged_failures += state.record_failure(now);
		CHECK_FALSE(state.can_attempt(&scene, 2, now));
		CHECK_FALSE(state.can_attempt(&scene, 2, now + delay * 1000000 - 1));
		now += delay * 1000000;
		CHECK(state.can_attempt(&scene, 2, now));
		CHECK_FALSE(state.is_ready(&scene, 2));
	}
	CHECK(logged_failures == 3);

	// The SAME revision can recover after long-lived transient pressure.
	int complete[pass_count] = {};
	CHECK(amd_gi_prepare_pipeline_candidate(complete, [](uint32_t) { return true; }, [](uint32_t p_pass) { return int(p_pass + 1); }, [](int) { CHECK(false); }) == pass_count);
	state.publish(&scene, 2);
	CHECK(state.is_ready(&scene, 2));
	CHECK_FALSE(state.is_ready(&scene, 1));

	// A new ABI (or scene) bypasses the failed request's retry delay.
	CHECK(state.can_attempt(&scene, 3, now));
	CHECK(state.record_failure(now));
	CHECK_FALSE(state.can_attempt(&scene, 3, now));
	CHECK(state.can_attempt(&scene, 4, now));
	CHECK(state.record_failure(now));
	const int other_scene = 0;
	CHECK(state.can_attempt(&other_scene, 4, now));
	CHECK_FALSE(state.is_ready(&other_scene, 2));
}

} // namespace TestAMDGiPipelinePreparation
