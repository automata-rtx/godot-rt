/**************************************************************************/
/*  amd_gi_pipeline_preparation.h                                         */
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

#include <cstdint>

namespace RendererRD {

// A ready signature describes a fully published shader and pipeline set.
// Failed requests remain distinct: retaining an older set never makes a new
// material/context ABI safe to render. Transient failures can recover without
// requiring an unrelated material edit, but never retry on every frame.
struct AMDGIPipelinePreparationState {
private:
	const void *ready_scene = nullptr;
	uint64_t ready_revision = 0;
	bool ready = false;
	const void *failed_scene = nullptr;
	uint64_t failed_revision = 0;
	uint32_t failures = 0;
	uint64_t next_attempt_usec = 0;

public:
	bool is_ready(const void *p_scene, uint64_t p_revision) const {
		return ready && ready_scene == p_scene && ready_revision == p_revision;
	}

	bool can_attempt(const void *p_scene, uint64_t p_revision, uint64_t p_now_usec) {
		if (failed_scene != p_scene || failed_revision != p_revision) {
			failed_scene = p_scene;
			failed_revision = p_revision;
			failures = 0;
			next_attempt_usec = 0;
		}
		return p_now_usec >= next_attempt_usec;
	}

	// Return whether this failure should be logged. Only the first three
	// failures of an unchanged request log; retries continue at a capped delay.
	bool record_failure(uint64_t p_now_usec) {
		const bool log_failure = failures < 3;
		const uint64_t delay_sec = failures < 5 ? uint64_t(1) << failures : 30;
		if (failures < 6) {
			failures++;
		}
		next_attempt_usec = p_now_usec + delay_sec * 1000000;
		return log_failure;
	}

	void publish(const void *p_scene, uint64_t p_revision) {
		ready_scene = p_scene;
		ready_revision = p_revision;
		ready = true;
		failures = 0;
		next_attempt_usec = 0;
	}
};

// Build an isolated candidate. The caller owns its shader version and publishes
// only when every required pass succeeds. Failure releases every partial
// pipeline before the caller frees that version. This also makes late-pass
// failures (after reflection output) testable without a rendering device.
template <typename Pipeline, uint32_t N, typename Required, typename Create, typename Release>
uint32_t amd_gi_prepare_pipeline_candidate(Pipeline (&r_candidate)[N], Required p_required, Create p_create, Release p_release) {
	for (uint32_t i = 0; i < N; i++) {
		if (!p_required(i)) {
			continue;
		}
		r_candidate[i] = p_create(i);
		if (r_candidate[i] == Pipeline()) {
			for (Pipeline &pipeline : r_candidate) {
				if (pipeline != Pipeline()) {
					p_release(pipeline);
					pipeline = Pipeline();
				}
			}
			return i;
		}
	}
	return N;
}

} // namespace RendererRD
