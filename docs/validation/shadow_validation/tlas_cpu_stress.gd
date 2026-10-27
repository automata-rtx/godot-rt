extends SceneTree

# CPU submission stress, not a GPU performance or image-quality benchmark.
# All 16,000 instances share one valid BLAS. The cold phase rebuilds that same
# BLAS before every submission, exercising conservative dependency invalidation.
const INSTANCE_COUNT := 16000
const ITERATIONS := 120
const MOVING_COUNT := 64


func _initialize() -> void:
	call_deferred("run_test")


func measure_phase(rd: RenderingDevice, tlas: RID, blas: RID, instances: Array[RDAccelerationStructureInstance], force_cold: bool) -> Dictionary:
	var name := "forced_blas_rebuild" if force_cold else "retained_topology"
	print("RT_TLAS_STRESS begin phase=%s iterations=%d instances=%d" % [name, ITERATIONS, INSTANCE_COUNT])
	var samples := PackedInt64Array()
	var started := Time.get_unix_time_from_system()
	for iteration in ITERATIONS:
		# Prepare changed inputs outside the timed call. The script-to-native
		# array conversion remains inside both comparison modes equally.
		for index in MOVING_COUNT:
			var transform := instances[index].transform
			transform.origin.z = 0.01 * float(iteration & 1)
			instances[index].transform = transform
		if force_cold:
			var blas_error := rd.blas_build(blas)
			assert(blas_error == OK)
		var start := Time.get_ticks_usec()
		var tlas_error := rd.tlas_build(tlas, instances)
		var elapsed := Time.get_ticks_usec() - start
		assert(tlas_error == OK)
		samples.append(elapsed)
		# Finish this iteration before any input or AS storage is reused. GPU
		# execution/fence waiting is deliberately outside the CPU measurement.
		rd.submit()
		rd.sync()
	var sorted := samples.duplicate()
	sorted.sort()
	var result := {
		"phase": name,
		"started_unix": started,
		"finished_unix": Time.get_unix_time_from_system(),
		"cpu_usec": Array(samples),
		"median_ms": 0.0005 * float(sorted[ITERATIONS / 2 - 1] + sorted[ITERATIONS / 2]),
		"p95_ms": 0.001 * float(sorted[int(0.95 * float(ITERATIONS - 1))]),
		"min_ms": 0.001 * float(sorted[0]),
		"max_ms": 0.001 * float(sorted[ITERATIONS - 1]),
	}
	print("RT_TLAS_STRESS end phase=%s median_ms=%.6f p95_ms=%.6f" % [name, result.median_ms, result.p95_ms])
	return result


func run_test() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	assert(rd != null, "TLAS CPU stress requires a local Vulkan RenderingDevice")
	var vertices := PackedVector3Array([Vector3(-0.25, -0.25, 0), Vector3(0.25, -0.25, 0), Vector3(0, 0.25, 0)]).to_byte_array()
	var usage := RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT | RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT
	var vertex_buffer := rd.vertex_buffer_create(vertices.size(), vertices, usage)
	assert(rd.buffer_get_device_address(vertex_buffer) != 0, "BLAS input must have a device address")
	var geometry := RDAccelerationStructureGeometry.new()
	geometry.vertex_buffer = vertex_buffer
	geometry.vertex_count = 3
	geometry.vertex_stride = 12
	geometry.vertex_format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	geometry.flags = RenderingDevice.ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT
	var blas := rd.blas_create([geometry], 0)
	assert(blas.is_valid())
	var blas_error := rd.blas_build(blas)
	assert(blas_error == OK)
	var tlas := rd.tlas_create(INSTANCE_COUNT, RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT)
	assert(tlas.is_valid())
	var instances: Array[RDAccelerationStructureInstance] = []
	instances.resize(INSTANCE_COUNT)
	for index in INSTANCE_COUNT:
		var item := RDAccelerationStructureInstance.new()
		item.blas = blas
		item.hit_sbt_range = 1 << 32
		item.id = index
		item.flags = RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT
		item.transform = Transform3D(Basis.IDENTITY, Vector3(index % 160, index / 160, 0))
		instances[index] = item
	var results := [
		measure_phase(rd, tlas, blas, instances, false),
		measure_phase(rd, tlas, blas, instances, true),
	]
	var report := {
		"instance_count": INSTANCE_COUNT,
		"unique_blas_count": 1,
		"iterations_per_phase": ITERATIONS,
		"moving_instances_per_iteration": MOVING_COUNT,
		"reuse_disabled": OS.get_environment("GODOT_RT_DISABLE_TLAS_REUSE") == "1",
		"cpu_profile_enabled": OS.get_environment("GODOT_RT_CPU_PROFILE") == "1",
		"includes_script_binding_conversion": true,
		"includes_gpu_wait": false,
		"phases": results,
	}
	var path := OS.get_environment("RT_TLAS_STRESS_OUT")
	if path.is_empty():
		path = "user://tlas_cpu_stress.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "Cannot write TLAS CPU stress report: " + path)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	for rid in [tlas, blas, vertex_buffer]:
		rd.free_rid(rid)
	rd.free()
	print("RT_TLAS_STRESS complete phases=2 iterations=240 failures=0")
	quit(0)
