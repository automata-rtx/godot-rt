extends SceneTree

var samples: Array = []
var last_frame := -1

func _initialize():
	call_deferred("run_test")

func frames(count):
	for i in count:
		await process_frame
		await RenderingServer.frame_post_draw

func collect():
	var rd = RenderingServer.get_rendering_device()
	var frame = rd.get_captured_timestamps_frame()
	var row = {}
	for i in range(rd.get_captured_timestamps_count() - 1):
		var label = rd.get_captured_timestamp_name(i)
		if not label.begins_with("<") and not label.begins_with(">"):
			row["cpu/" + label] = (rd.get_captured_timestamp_cpu_time(i + 1) - rd.get_captured_timestamp_cpu_time(i)) / 1000.0
			row["gpu/" + label] = (rd.get_captured_timestamp_gpu_time(i + 1) - rd.get_captured_timestamp_gpu_time(i)) / 1000000.0
	if rd.get_captured_timestamps_count() > 1:
		row["cpu/render_span"] = (rd.get_captured_timestamp_cpu_time(rd.get_captured_timestamps_count() - 1) - rd.get_captured_timestamp_cpu_time(0)) / 1000.0
		row["gpu/frame"] = (rd.get_captured_timestamp_gpu_time(rd.get_captured_timestamps_count() - 1) - rd.get_captured_timestamp_gpu_time(0)) / 1000000.0
	accept.call_deferred(frame, row)

func accept(frame, row):
	if frame != last_frame:
		last_frame = frame
		samples.append(row)

func census(node, counts):
	var type = node.get_class()
	if node.get_script() and node.get_script().resource_path == "res://features/npc/runtime/npc_live_world.gd":
		print("CPU_NPCS count=%s guards=%s ready=%s failed=%s" % [node.get("count"),node.get("guard_count"),node.get("ready_world"),node.get("failed")])
	counts[type] = counts.get(type, 0) + 1
	for group in node.get_groups():
		if not str(group).begins_with("_"):
			counts["group/" + str(group)] = counts.get("group/" + str(group), 0) + 1
	for child in node.get_children():
		census(child, counts)

func run_test():
	seed(12345)
	change_scene_to_file("res://features/menu/main_menu.tscn")
	await frames(3)
	var level = int(OS.get_environment("CPU_PROFILE_LEVEL"))
	current_scene._select_level(level)
	current_scene._start()
	await frames(60)
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	root.scaling_3d_mode = 0
	root.scaling_3d_scale = 1.0
	root.screen_space_aa = 0
	await frames(240)
	var counts = {}
	census(root, counts)
	print("CPU_CENSUS " + JSON.stringify(counts))
	print("CPU_CONFIG level=%d size=%s camera=%s GI=%s" % [level,root.size,root.get_camera_3d().global_transform,ProjectSettings.get_setting("rendering/global_illumination/amd_gi/enabled")])
	for phase in ["gi_on", "gi_off", "gi_restored"]:
		ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", phase != "gi_off")
		await frames(120)
		samples.clear()
		var wall = []
		print("CPU_BEGIN " + phase)
		for i in 240:
			var before = Time.get_ticks_usec()
			await frames(1)
			wall.append((Time.get_ticks_usec() - before) / 1000.0)
			RenderingServer.call_on_render_thread(collect)
		await frames(5)
		print("CPU_SAMPLES " + JSON.stringify({"phase":phase,"render":samples,"wall":wall,"process_peak_ms":Performance.get_monitor(Performance.TIME_PROCESS)*1000,"physics_peak_ms":Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000}))
	print("CPU_PROFILE_END")
	await root.get_node("LevelState").return_to_menu()
	await frames(10)
	quit()
