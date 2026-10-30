extends "res://gi.gd"

const GI := "rendering/global_illumination/amd_gi/"


func _stage(label: String) -> void:
	for frame in 6:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	var info := RenderingServer.viewport_get_amd_gi_diagnostics(get_viewport().get_viewport_rid())
	assert(not info.is_empty(), "Missing GI diagnostics: " + label)
	var gpu: Dictionary = info.get("gpu", {})
	assert(not gpu.is_empty(), "Missing GPU counters: " + label)
	var size: Vector2i = info["size"]
	var spacing: int = ProjectSettings.get_setting(GI + "probe_spacing")
	var budget := ceili(float(size.x) / spacing) * ceili(float(size.y) / spacing)
	assert(gpu["updated_probes"] <= budget, "Exceeded primary ray budget: " + label)
	print("IMPROVEMENTS_LIFECYCLE ", label, " size=", size, " updated=", gpu["updated_probes"], " budget=", budget)


func _run() -> void:
	ProjectSettings.set_setting(GI + "enabled", true)
	ProjectSettings.set_setting(GI + "cache_bucket_exponent", 8)
	ProjectSettings.set_setting(GI + "debug/statistics", true)
	ProjectSettings.set_setting(GI + "debug/readback_interval", 1)
	for flags in [0, 1, 2, 4, 7, 0, 7]:
		ProjectSettings.set_setting(GI + "improvements/responsive_history", (flags & 1) != 0)
		ProjectSettings.set_setting(GI + "improvements/demand_scheduling", (flags & 2) != 0)
		ProjectSettings.set_setting(GI + "improvements/cache_transitions", (flags & 4) != 0)
		await _stage("flags_%d" % flags)
	for option in ["probe_cache", "adaptive_sampling", "multibounce", "cache_all_hits", "reflections/enabled"]:
		ProjectSettings.set_setting(GI + option, false)
		await _stage(option + "_off")
		ProjectSettings.set_setting(GI + option, true)
		await _stage(option + "_on")
	for spacing in [8, 32, 16]:
		ProjectSettings.set_setting(GI + "probe_spacing", spacing)
		await _stage("spacing_%d" % spacing)
	get_window().size = Vector2i(333, 187)
	await _stage("odd_resize")
	ProjectSettings.set_setting(GI + "enabled", false)
	for frame in 8:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	var before := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)
	for setting in ["responsive_history", "demand_scheduling", "cache_transitions"]:
		ProjectSettings.set_setting(GI + "improvements/" + setting, false)
	for frame in 8:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	var after := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)
	assert(before == after, "Improvement flags changed buffer allocation while GI was disabled")
	ProjectSettings.set_setting(GI + "enabled", true)
	await _stage("restored_original")
	print("IMPROVEMENTS_LIFECYCLE complete")
	get_tree().quit()
