extends SceneTree

func _initialize():
	call_deferred("run_test")

func frames(count):
	for i in count:
		await process_frame
		await RenderingServer.frame_post_draw

func run_test():
	change_scene_to_file("res://features/menu/main_menu.tscn")
	await frames(3)
	for level in [0, 5, 1]:
		current_scene._select_level(level)
		current_scene._start()
		await frames(100)
		root.scaling_3d_mode = 6
		root.scaling_3d_scale = 0.67
		root.screen_space_aa = 0
		await frames(100)
		print("LEVEL_TEST level=%d scene=%s GI=%s effective_upscaler=%s FPS=%s" % [level, current_scene.scene_file_path, ProjectSettings.get_setting("rendering/global_illumination/amd_gi/enabled"), RenderingServer.viewport_get_effective_scaling_3d_mode(root.get_viewport_rid()), Engine.get_frames_per_second()])
		await root.get_node("LevelState").return_to_menu()
		await frames(3)
	print("LEVEL_TEST completed")
	quit()
