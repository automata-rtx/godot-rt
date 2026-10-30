extends "res://gi.gd"

# Targeted response/disocclusion fixture. All changes are process-local.
# Capture AFTER the exact numbered draw; _capture() in the base adds frames.
const GI := "rendering/global_illumination/amd_gi/"
var _draw := 0
var _records: Array[Dictionary] = []
var _output := ""


func _step(count: int) -> void:
	for index in count:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		_draw += 1


func _save(label: String) -> void:
	var image := get_viewport().get_texture().get_image()
	assert(image.save_png(_output.path_join(label + ".png")) == OK)
	_records.append({"label": label, "draw": _draw})
	print("IMPROVEMENTS capture ", label, " draw=", _draw)


func _run() -> void:
	_output = OS.get_environment("SHADOW_OUT_DIR")
	assert(not _output.is_empty())
	DirAccess.make_dir_recursive_absolute(_output)
	var experiment := OS.get_environment("GI_EXPERIMENT")
	assert(experiment in ["baseline", "response", "scheduling", "transitions", "combined"])
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "improvements/responsive_history", experiment in ["response", "combined"])
	ProjectSettings.set_setting(GI + "improvements/demand_scheduling", experiment in ["scheduling", "combined"])
	ProjectSettings.set_setting(GI + "improvements/cache_transitions", experiment in ["transitions", "combined"])
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "denoiser", true)
	ProjectSettings.set_setting(GI + "multibounce", true)
	ProjectSettings.set_setting(GI + "reflections/enabled", true)
	ProjectSettings.set_setting(GI + "debug/view", 0)
	get_viewport().scaling_3d_scale = 1.0
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	get_viewport().use_taa = false
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	var environment := get_viewport().find_world_3d().environment
	environment.ssao_enabled = false
	_light.visible = false
	var lamp := SpotLight3D.new()
	lamp.position = Vector3(0.0, 1.7, 2.2)
	lamp.light_energy = 10.0
	lamp.spot_range = 20.0
	lamp.spot_angle = 23.0
	lamp.light_size = 0.0
	lamp.shadow_enabled = true
	add_child(lamp)
	lamp.look_at(Vector3(-1.8, 1.2, -2.4))
	# Keep direct lighting fixed to isolate bounce response; the light stays in
	# the light list, avoiding a topology/history reset masquerading as response.
	lamp.light_indirect_energy = 0.0
	if not OS.get_environment("GI_STABILITY_ONLY").is_empty():
		lamp.light_indirect_energy = 1.0
		ProjectSettings.set_setting(GI + "enabled", true)
		await _step(256)
		for frame in 16:
			await _step(1)
			_save("steady_%02d" % frame)
		var record := FileAccess.open(_output.path_join("capture.json"), FileAccess.WRITE)
		record.store_string(JSON.stringify({"experiment": experiment, "device": RenderingServer.get_video_adapter_name(), "engine": Engine.get_version_info(), "captures": _records, "settling_frames": 256, "primary_rays_per_pixel": 0.25, "gi_denoiser": true, "taa": false, "fsr2": false}, "\t") + "\n")
		print("IMPROVEMENTS complete ", experiment, " steady-state stability")
		get_tree().quit()
		return
	await _step(4)
	_save("direct_only")
	ProjectSettings.set_setting(GI + "enabled", true)
	await _step(32)
	_save("off_settled")
	lamp.light_indirect_energy = 1.0
	var settle_frames := maxi(int(OS.get_environment("GI_SETTLE_FRAMES")), 64)
	for frame in settle_frames:
		await _step(1)
		if frame + 1 in [1, 4, 8, 16, 32, 64, 128, 256]:
			_save("on_%02d" % (frame + 1))
		if not OS.get_environment("GI_CAPTURE_STEADY").is_empty() and frame >= settle_frames - 16:
			_save("steady_%02d" % (frame - settle_frames + 16))
	lamp.light_indirect_energy = 0.0
	for frame in 32:
		await _step(1)
		if frame + 1 in [1, 4, 8, 16, 32]:
			_save("off_%02d" % (frame + 1))
	lamp.light_indirect_energy = 1.0
	await _step(32)
	var camera := get_viewport().get_camera_3d()
	var origin := camera.transform
	for frame in 16:
		camera.position.x += 0.06
		await _step(1)
		if frame + 1 in [4, 8, 16]:
			_save("motion_%02d" % (frame + 1))
	await _step(16)
	_save("motion_settled")
	# Abrupt exposure of fresh surfaces stresses coverage and cache admission.
	camera.transform = origin
	await _step(1)
	_save("return_01")
	await _step(7)
	_save("return_08")
	await _step(24)
	_save("return_32")
	# Cold cache admission reveals threshold switches concealed by a settled
	# cache. Same light/camera and reset sequence in every experiment.
	ProjectSettings.set_setting(GI + "enabled", false)
	await _step(4)
	ProjectSettings.set_setting(GI + "enabled", true)
	for frame in 16:
		await _step(1)
		if frame + 1 in [1, 4, 8, 12, 16]:
			_save("cache_start_%02d" % (frame + 1))
	# Repeated rapid light changes challenge false change detection/recovery.
	for frame in 24:
		lamp.light_indirect_energy = 0.0 if (frame / 4) % 2 == 0 else 1.0
		await _step(1)
		if (frame + 1) % 4 == 0:
			_save("flash_%02d" % (frame + 1))
	var report := {
		"experiment": experiment,
		"device": RenderingServer.get_video_adapter_name(),
		"engine": Engine.get_version_info(),
		"size": str(get_viewport().size),
		"upscaling": false, "taa": false, "fsr2": false,
		"gi_denoiser": true, "primary_rays_per_pixel": 0.25,
		"multibounce": true, "reflections": true, "vbao": false,
		"cache_bucket_exponent": ProjectSettings.get_setting(GI + "cache_bucket_exponent"),
		"on_settle_frames": settle_frames,
		"captures": _records,
		"notes": "Fixed direct light; only its bounce energy switches. Frame counts, not software-render wall-clock latency. No target-GPU performance inference."
	}
	var file := FileAccess.open(_output.path_join("capture.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t") + "\n")
	print("IMPROVEMENTS complete ", experiment)
	get_tree().quit()
