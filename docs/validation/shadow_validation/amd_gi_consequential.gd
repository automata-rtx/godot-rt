extends "res://gi.gd"

# Integration regression for corrected probe/cache scheduling. Keep the default
# quarter budget throughout; this is not an image-quality reference render.
func _settle(frames: int) -> void:
	for frame in frames:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _settle(32)
	await _capture("consequential_still")
	var camera := get_viewport().get_camera_3d()
	var original := camera.transform
	for frame in 24:
		camera.position.x += 0.025
		await _settle(1)
	camera.transform = original
	await _settle(8)
	await _capture("consequential_return")
	print("CONSEQUENTIAL stage: empty screen")
	camera.position = Vector3(0, 5, 10)
	camera.look_at(Vector3(0, 50, 11))
	await _settle(4)
	camera.transform = original
	await _settle(8)
	print("CONSEQUENTIAL stage: restored screen")
	# A camera switch must reproject/reject history, not globally reset it.
	print("CONSEQUENTIAL stage: camera replacement")
	var replacement := Camera3D.new()
	add_child(replacement)
	replacement.transform = original
	replacement.position.x += 1.0
	replacement.make_current()
	await _settle(8)
	camera.make_current()
	replacement.queue_free()
	await _settle(8)
	print("CONSEQUENTIAL stage: camera restored")
	# Independent render buffers must survive another viewport's creation,
	# resize and destruction. Share the scene but use a separate camera.
	print("CONSEQUENTIAL stage: second viewport")
	var second := SubViewport.new()
	second.size = Vector2i(159, 91)
	second.world_3d = get_viewport().world_3d
	second.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(second)
	var second_camera := Camera3D.new()
	second.add_child(second_camera)
	second_camera.transform = original
	second_camera.make_current()
	await _settle(8)
	var second_image := second.get_texture().get_image()
	var output := OS.get_environment("SHADOW_OUT_DIR")
	if second_image.save_png(output.path_join("consequential_second.png")) != OK:
		_failures += 1
	second.size = Vector2i(157, 89)
	await _settle(4)
	second.queue_free()
	await _settle(8)
	await _capture("consequential_after_viewport")
	print("CONSEQUENTIAL stage: second viewport removed")
	_light.light_energy = 0.0
	await _settle(16)
	_light.light_energy = 1.0
	await _settle(16)
	get_window().size = Vector2i(317, 177)
	await _settle(8)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(8)
	await _capture("consequential_disabled")
	print("AMD consequential integration completed: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
