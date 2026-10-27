extends SceneTree

var rd: RenderingDevice
var shaders: Array[RID] = []
var pipelines: Array[RID] = []
var failures: Array[String] = []
var cases: int = 0
var pixels_checked: int = 0
var default_marks: int = 0
var custom_marks: int = 0


func _initialize() -> void:
	call_deferred("run_fixture")


func fail(message: String) -> void:
	failures.append(message)
	push_error(message)


func compile_shader(path: String) -> bool:
	var source: RDShaderSource = RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string(path)
	var spirv: RDShaderSPIRV = rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		fail(spirv.compile_error_compute)
		return false
	var shader: RID = rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		fail("Could not create shader " + path)
		return false
	shaders.append(shader)
	var pipeline: RID = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		fail("Could not create pipeline " + path)
		return false
	pipelines.append(pipeline)
	return true


func push_bytes(size: Vector2i, stride: int, phase: int, low: float, high: float, radius: int) -> PackedByteArray:
	var push: PackedByteArray = PackedInt32Array([size.x, size.y, stride, phase, 0, 0, radius, 0]).to_byte_array()
	push.encode_float(16, low)
	push.encode_float(20, high)
	return push


func make_outputs(buffer: RID, size: Vector2i) -> Dictionary:
	var textures: Array[RID] = []
	var sets: Array[RID] = []
	for variant in 2:
		var format: RDTextureFormat = RDTextureFormat.new()
		format.width = size.x
		format.height = size.y
		format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		var texture: RID = rd.texture_create(format, RDTextureView.new())
		textures.append(texture)
		var source: RDUniform = RDUniform.new()
		source.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		source.binding = 0
		source.add_id(buffer)
		var target: RDUniform = RDUniform.new()
		target.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		target.binding = 1
		target.add_id(texture)
		sets.append(rd.uniform_set_create([source, target], shaders[variant], 0))
	return {"textures": textures, "sets": sets}


func free_outputs(outputs: Dictionary) -> void:
	for rid in outputs.sets:
		rd.free_rid(rid)
	for rid in outputs.textures:
		rd.free_rid(rid)


func dispatch(variant: int, bindings: RID, size: Vector2i, push: PackedByteArray, repeats: int = 1) -> void:
	var list: int = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipelines[variant])
	rd.compute_list_bind_uniform_set(list, bindings, 0)
	rd.compute_list_set_push_constant(list, push, push.size())
	for repeat_index in repeats:
		rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		if repeat_index + 1 < repeats:
			rd.compute_list_add_barrier(list)
	rd.compute_list_end()


func compare_case(outputs: Dictionary, size: Vector2i, stride: int, phase: int, low: float, high: float, radius: int) -> void:
	var reflected: Vector2i = Vector2i(ceili(size.x / float(stride)), ceili(size.y / float(stride)))
	var push: PackedByteArray = push_bytes(size, stride, phase, low, high, radius)
	for variant in 2:
		# Differing sentinels expose unwritten pixels as well as value differences.
		rd.texture_clear(outputs.textures[variant], Color(0.25 + variant * 0.25, 0, 0, 0), 0, 1, 0, 1)
		dispatch(variant, outputs.sets[variant], reflected, push)
	rd.submit()
	rd.sync()
	var baseline: PackedByteArray = rd.texture_get_data(outputs.textures[0], 0)
	var optimized: PackedByteArray = rd.texture_get_data(outputs.textures[1], 0)
	cases += 1
	if baseline != optimized:
		fail("Mask differs: size=%s stride=%d phase=%d thresholds=%s radius=%d" % [size, stride, phase, Vector2(low, high), radius])
		return
	for pixel in reflected.x * reflected.y:
		var mark: int = baseline.decode_u16(pixel * 8)
		if mark != 0 and mark != 0x3c00:
			fail("Nonbinary/unwritten mask at case %d pixel %d" % [cases, pixel])
			return
		if low == 0.0 and high == 1.0:
			default_marks += int(mark != 0)
		else:
			custom_marks += int(mark != 0)
	pixels_checked += reflected.x * reflected.y


func time_dispatch(variant: int, outputs: Dictionary, size: Vector2i, push: PackedByteArray, repeats: int) -> float:
	rd.capture_timestamp("begin")
	dispatch(variant, outputs.sets[variant], size, push, repeats)
	rd.capture_timestamp("end")
	rd.submit()
	rd.sync()
	var begin: int = -1
	var end: int = -1
	for index in rd.get_captured_timestamps_count():
		var name: String = rd.get_captured_timestamp_name(index)
		if name == "begin":
			begin = rd.get_captured_timestamp_gpu_time(index)
		elif name == "end":
			end = rd.get_captured_timestamp_gpu_time(index)
	if begin < 0 or end <= begin:
		fail("Missing/nonpositive GPU timestamp interval")
		return -1.0
	# Vulkan timestamp_query_result_to_time returns nanoseconds in this source.
	return (end - begin) / (1000000.0 * repeats)


func median(values: Array) -> float:
	var ordered: Array = values.duplicate()
	ordered.sort()
	return float(ordered[floori(ordered.size() / 2.0)])


func benchmark() -> Array:
	var data: PackedByteArray = FileAccess.get_file_as_bytes("res://bench_samples.bin")
	var buffer: RID = rd.storage_buffer_create(data.size(), data)
	data.clear()
	var results: Array = []
	for stride in [1, 2]:
		var full_size: Vector2i = Vector2i(1280, 720)
		var size: Vector2i = full_size / int(stride)
		var outputs: Dictionary = make_outputs(buffer, size)
		for thresholds in [Vector2(0.0, 1.0), Vector2(0.05, 0.95)]:
			var push: PackedByteArray = push_bytes(full_size, stride, 0, thresholds.x, thresholds.y, 2 if stride == 1 else 3)
			var samples: Array = [[], []]
			# Alternate order to limit thermal/order bias; discard warmup pairs.
			for pair in 15:
				for order in 2:
					var variant: int = (pair + order) % 2
					var milliseconds: float = time_dispatch(variant, outputs, size, push, 8)
					if pair >= 4:
						samples[variant].append(milliseconds)
			results.append({"stride": stride, "thresholds": [thresholds.x, thresholds.y], "baseline_median_ms": median(samples[0]), "optimized_median_ms": median(samples[1]), "baseline_samples_ms": samples[0], "optimized_samples_ms": samples[1]})
		free_outputs(outputs)
	rd.free_rid(buffer)
	return results


func finish(timings: Array = []) -> void:
	var result: Dictionary = {"result": "pass" if failures.is_empty() else "fail", "cases": cases, "pixels_checked": pixels_checked, "default_negative_distance_marks": default_marks, "custom_threshold_marks": custom_marks, "failures": failures, "timings": timings, "timing_scope": "Synthetic isolated marking pass, every pixel eligible; not a game/whole-GI benchmark", "engine": Engine.get_version_info(), "gpu": RenderingServer.get_video_adapter_name()}
	var output: String = OS.get_environment("FIREFLY_GPU_OUTPUT")
	if not output.is_empty():
		var file: FileAccess = FileAccess.open(output.path_join("gpu_result.json"), FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(result, "\t"))
	print("FIREFLY_GPU_RESULT " + JSON.stringify(result))
	for pipeline in pipelines:
		rd.free_rid(pipeline)
	for shader in shaders:
		rd.free_rid(shader)
	if rd != null:
		rd.free()
	quit(0 if failures.is_empty() else 1)


func run_fixture() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		fail("No Vulkan local RenderingDevice")
		finish()
		return
	if not compile_shader("res://baseline.comp") or not compile_shader("res://optimized.comp"):
		finish()
		return
	var data: PackedByteArray = FileAccess.get_file_as_bytes("res://samples.bin")
	var buffer: RID = rd.storage_buffer_create(data.size(), data)
	var thresholds: Array[Vector2] = [Vector2(0, 1), Vector2(-0.0, 1), Vector2(0.05, 0.95), Vector2(0, 0.5), Vector2(0.5, 1), Vector2(1, 0), Vector2(NAN, 1), Vector2(0, NAN)]
	for size in [Vector2i(1, 1), Vector2i(1, 7), Vector2i(3, 5), Vector2i(17, 13), Vector2i(32, 24)]:
		for stride in [1, 2]:
			var reflected: Vector2i = Vector2i(ceili(size.x / float(stride)), ceili(size.y / float(stride)))
			var outputs: Dictionary = make_outputs(buffer, reflected)
			for phase in (1 if stride == 1 else 4):
				for radius in [0, 1, 2, 3, 16]:
					for threshold in thresholds:
						compare_case(outputs, size, stride, phase, threshold.x, threshold.y, radius)
			free_outputs(outputs)
	rd.free_rid(buffer)
	if default_marks == 0 or custom_marks == 0:
		fail("Missing negative-distance or custom-threshold coverage")
	var timings: Array = []
	if failures.is_empty() and OS.get_environment("FIREFLY_GPU_SKIP_TIMING") != "1":
		timings = benchmark()
	finish(timings)
