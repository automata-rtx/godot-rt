extends Node

const SIDE := 64
# Internal RD slice type, deliberately not part of the bound public enum.
const SLICE_2D_ARRAY := 3
var _rd: RenderingDevice
var _owned: Array[RID] = []


func _shader(code: String) -> RID:
	var source := RDShaderSource.new()
	source.source_compute = code
	var spirv := _rd.shader_compile_spirv_from_source(source)
	assert(spirv.compile_error_compute.is_empty(), spirv.compile_error_compute)
	var shader := _rd.shader_create_from_spirv(spirv)
	_owned.append(shader)
	return shader


func _uniform(kind: int, binding: int, ids: Array[RID]) -> RDUniform:
	var result := RDUniform.new()
	result.uniform_type = kind
	result.binding = binding
	for id in ids:
		result.add_id(id)
	return result


func _ready() -> void:
	_rd = RenderingServer.create_local_rendering_device()
	assert(_rd != null)
	var image := Image.create_empty(SIDE, SIDE, false, Image.FORMAT_RGBAH)
	for y in SIDE:
		for x in SIDE:
			var e := (Vector2(x, y) + Vector2(0.5, 0.5)) / SIDE * 2.0 - Vector2.ONE
			var direction := Vector3(e.x, e.y, 1.0 - absf(e.x) - absf(e.y))
			if direction.z < 0.0:
				direction.x = (1.0 - absf(e.y)) * signf(e.x)
				direction.y = (1.0 - absf(e.x)) * signf(e.y)
			direction = direction.normalized() * 0.5 + Vector3.ONE * 0.5
			image.set_pixel(x, y, Color(direction.x, direction.y, direction.z, 1))
	var format := RDTextureFormat.new()
	format.width = SIDE
	format.height = SIDE
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var octmap := _rd.texture_create(format, RDTextureView.new(), [image.get_data()])
	_owned.append(octmap)
	format.texture_type = RenderingDevice.TEXTURE_TYPE_CUBE
	format.array_layers = 6
	format.mipmaps = 7
	var cube := _rd.texture_create(format, RDTextureView.new())
	_owned.append(cube)
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.max_lod = 100.0
	var sampler := _rd.sampler_create(sampler_state)
	_owned.append(sampler)
	var base := "res://../../../servers/rendering/renderer_rd/shaders/"
	var code := FileAccess.get_file_as_string(base + "effects/amd_gi_environment.glsl").replace("#[compute]", "")
	code = code.replace('#include "../oct_inc.glsl"', FileAccess.get_file_as_string(base + "oct_inc.glsl"))
	var shaders: Array[RID] = [_shader(code.replace("#VERSION_DEFINES", "#define CONVERT_OCTMAP")), _shader(code.replace("#VERSION_DEFINES", ""))]
	var pipelines: Array[RID] = []
	for shader in shaders:
		pipelines.append(_rd.compute_pipeline_create(shader))
		_owned.append(pipelines.back())
	var previous := octmap
	for mip in 7:
		var view := _rd.texture_create_shared_from_slice(RDTextureView.new(), cube, 0, mip, 1, SLICE_2D_ARRAY)
		var mode := 0 if mip == 0 else 1
		var uniforms := _rd.uniform_set_create([
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [sampler, previous]),
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [view]),
		], shaders[mode], 0)
		_owned.append(uniforms)
		var push := PackedByteArray()
		push.resize(16)
		push.encode_u32(0, SIDE >> mip)
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, pipelines[mode])
		_rd.compute_list_bind_uniform_set(list, uniforms, 0)
		_rd.compute_list_set_push_constant(list, push, 16)
		_rd.compute_list_dispatch(list, maxi((SIDE >> mip) / 8, 1), maxi((SIDE >> mip) / 8, 1), 6)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
		previous = view
	var shader := _shader("""#version 450
layout(local_size_x=64) in;
layout(set=0,binding=0) uniform samplerCube sky;
layout(set=0,binding=1,std430) buffer Output { vec4 samples[]; };
void main() {
    uint id=gl_GlobalInvocationID.x;
    vec3 direction=normalize(vec3(float(int(id%17u)-8),float(int((id/17u)%19u)-9),float(int((id/323u)%13u)-6)) + vec3(0.25));
    samples[id]=vec4(abs(textureLod(sky,direction,0).rgb-(direction*0.5+0.5)), 0);
}
""")
	var pipeline := _rd.compute_pipeline_create(shader)
	_owned.append(pipeline)
	var buffer := _rd.storage_buffer_create(4096 * 16)
	_owned.append(buffer)
	var uniforms := _rd.uniform_set_create([
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [sampler, cube]),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, [buffer]),
	], shader, 0)
	_owned.append(uniforms)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, pipeline)
	_rd.compute_list_bind_uniform_set(list, uniforms, 0)
	_rd.compute_list_dispatch(list, 64, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	var worst := 0.0
	for value in _rd.buffer_get_data(buffer).to_float32_array():
		assert(is_finite(value))
		worst = maxf(worst, value)
	var mip_error := 0.0
	for face in 6:
		var bytes := _rd.texture_get_data(cube, face)
		for component in 3:
			var average := 0.0
			for pixel in SIDE * SIDE:
				average += bytes.decode_half(pixel * 8 + component * 2)
			average /= SIDE * SIDE
			mip_error = maxf(mip_error, absf(average - bytes.decode_half(bytes.size() - 8 + component * 2)))
	# Bounds account only for 64x64 native source interpolation and half rounding.
	var failures := int(worst > 0.003) + int(mip_error > 0.003)
	_owned.reverse()
	for handle in _owned:
		_rd.free_rid(handle)
	_rd.free()
	print("AMD environment: 4096 directions, error %.6f, mip mean error %.6f, %d failures" % [worst, mip_error, failures])
	get_tree().quit(1 if failures else 0)
