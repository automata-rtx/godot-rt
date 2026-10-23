extends "res://amd_gi.gd"

const GI := "rendering/global_illumination/amd_gi/"

func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", false)
	ProjectSettings.set_setting(GI + "probe_spacing", 16)
	ProjectSettings.set_setting(GI + "max_distance", 20.0)
	var camera := get_viewport().get_camera_3d()
	var edge := _box("CollectionEdge", Vector3(20.0, 0.5, 0), Vector3(0.1, 1, 1), Color.WHITE)
	await _settle(4)
	ProjectSettings.set_setting(GI + "enabled", true)
	await _settle(8)
	print("CHURN stage: translation")
	for step in 8:
		camera.position.x = 0.2 if step % 2 == 0 else -0.2
		await _settle(1)
	print("CHURN stage: rotation")
	for step in 8:
		camera.rotate_y(0.01)
		await _settle(1)
	print("CHURN stage: additions/removals")
	for step in 4:
		var transient := _box("Transient", Vector3(-18, 1, 0), Vector3.ONE, Color.WHITE)
		await _settle(1)
		transient.queue_free()
		await _settle(1)
	print("CHURN stage: material edit")
	(get_node("ShortBox").mesh.material as StandardMaterial3D).albedo_color = Color.BLUE
	await _settle(2)
	print("CHURN stage: finished")
	ProjectSettings.set_setting(GI + "enabled", false)
	await _settle(4)
	get_tree().quit()
