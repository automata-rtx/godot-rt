extends SceneTree

# External harness for fps-proto 0361687d. Run the editor executable with
# --path <fps-proto> --script <absolute path to this file> --gpu-profile --print-fps.
# Uses existing menu actions; changes only the in-memory AMD GI enable setting.

func _initialize():
	call_deferred("run_test")

func frames(count):
	for i in count:
		await process_frame
		await RenderingServer.frame_post_draw

func run_test():
	change_scene_to_file("res://features/menu/main_menu.tscn")
	await frames(3)
	current_scene._select_level(5)
	current_scene._start()
	await frames(120)
	print("PROFILE: Crossroads AMD GI on")
	await frames(120)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	print("PROFILE: Crossroads AMD GI off")
	await frames(120)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	print("PROFILE: Crossroads AMD GI restored")
	await frames(120)
	quit()
