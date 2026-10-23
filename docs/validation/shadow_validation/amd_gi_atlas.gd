extends "res://amd_gi.gd"

var _padding: MeshInstance3D


func _ready() -> void:
	# Allocate these before the room so resizing the first source shifts every
	# later atlas row without changing those sources' materials or geometry.
	_padding = _box("Padding", Vector3(0, 0, 15), Vector3.ONE, Color.BLACK)
	for index in 40:
		_box("Padding%d" % index, Vector3(float(index % 10) - 5.0, 0, 18.0 + float(index / 10)), Vector3(0.3, 0.3, 0.3), Color.BLACK)
	super._ready()


func _run() -> void:
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/denoiser", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/multibounce", true)
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/max_distance", 20.0)
	await _settle(12)
	await _capture("atlas_disabled")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
	await _settle(64)
	await _capture("atlas_small")
	print("stage atlas: shift")
	var material: Material = _padding.mesh.material
	var sphere := SphereMesh.new()
	sphere.radial_segments = 16
	sphere.rings = 8
	sphere.material = material
	_padding.mesh = sphere
	await _settle(64)
	await _capture("atlas_shifted")
	print("stage atlas: split")
	var larger := SphereMesh.new()
	larger.radial_segments = 32
	larger.rings = 32
	larger.material = material
	_padding.mesh = larger
	await _settle(64)
	await _capture("atlas_split")
	print("stage atlas: grow beyond old capacity")
	var largest := SphereMesh.new()
	largest.radial_segments = 128
	largest.rings = 128
	largest.material = material
	_padding.mesh = largest
	await _settle(64)
	await _capture("atlas_grown")
	print("stage atlas: shrink live budget")
	_padding.mesh = larger
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/material_atlas_mb", 8)
	await _settle(64)
	await _capture("atlas_shrunk")
	ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", false)
	await _settle(12)
	await _capture("atlas_disabled_after")
	print("AMD atlas capture finished: %d failures" % _failures)
	get_tree().quit(1 if _failures else 0)
