/**************************************************************************/
/*  streamline_vk.cpp                                                     */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "streamline_vk.h"

#ifdef STREAMLINE_ENABLED

#include "core/config/project_settings.h"
#include "core/error/error_macros.h"
#include "core/io/file_access.h"
#include "core/os/os.h"
#include "core/string/print_string.h"
#include "core/templates/hash_map.h"
#include "core/templates/local_vector.h"
#include "core/version.h"

#include <windows.h>
// Order matters: these three need windows.h first.
#include <softpub.h>
#include <wincrypt.h>
#include <wintrust.h>

// DLSSOptions still carries a deprecated `sharpness` member that its own defaulted constructor
// initializes, so the warning fires from inside the SDK rather than at any call site of ours.
GODOT_GCC_WARNING_PUSH_AND_IGNORE("-Wdeprecated-declarations")
GODOT_CLANG_WARNING_PUSH_AND_IGNORE("-Wdeprecated-declarations")
#include "sl.h"
#include "sl_consts.h"
#include "sl_dlss.h"
#include "sl_dlss_g.h"
#include "sl_helpers.h"
#include "sl_pcl.h"
#include "sl_reflex.h"
GODOT_CLANG_WARNING_POP
GODOT_GCC_WARNING_POP

StreamlineVK *StreamlineVK::singleton = nullptr;

namespace {

// Godot's `Projection` stores columns and multiplies as `M * v`; Streamline's `float4x4` stores
// rows and multiplies as `v * M`. Those two conventions are transposes of each other *and*
// transposes in storage, so the two cancel and a column copies straight into a row.
sl::float4x4 to_sl_matrix(const Projection &p_projection) {
	sl::float4x4 out;
	for (uint32_t i = 0; i < 4; i++) {
		out.row[i] = sl::float4(
				float(p_projection.columns[i][0]),
				float(p_projection.columns[i][1]),
				float(p_projection.columns[i][2]),
				float(p_projection.columns[i][3]));
	}
	return out;
}

sl::float3 to_sl_vector(const Vector3 &p_vector) {
	return sl::float3(float(p_vector.x), float(p_vector.y), float(p_vector.z));
}

sl::Feature to_sl_feature(StreamlineVK::Feature p_feature) {
	switch (p_feature) {
		case StreamlineVK::FEATURE_DLSS_SUPER_RESOLUTION:
			return sl::kFeatureDLSS;
		case StreamlineVK::FEATURE_DLSS_FRAME_GENERATION:
			return sl::kFeatureDLSS_G;
		case StreamlineVK::FEATURE_REFLEX:
			return sl::kFeatureReflex;
		default:
			return sl::kFeatureCommon;
	}
}

const char *feature_name(StreamlineVK::Feature p_feature) {
	switch (p_feature) {
		case StreamlineVK::FEATURE_DLSS_SUPER_RESOLUTION:
			return "DLSS super resolution";
		case StreamlineVK::FEATURE_DLSS_FRAME_GENERATION:
			return "DLSS frame generation";
		case StreamlineVK::FEATURE_REFLEX:
			return "Reflex";
		default:
			return "unknown";
	}
}

sl::Resource to_sl_resource(const StreamlineVK::Texture &p_texture) {
	sl::Resource resource(sl::ResourceType::eTex2d, reinterpret_cast<void *>(uintptr_t(p_texture.image)), nullptr, reinterpret_cast<void *>(uintptr_t(p_texture.view)), p_texture.layout);
	resource.width = uint32_t(p_texture.size.width);
	resource.height = uint32_t(p_texture.size.height);
	resource.nativeFormat = p_texture.format;
	resource.mipLevels = 1;
	resource.arrayLayers = 1;
	// `flags` is the one member of sl::Resource with no default initializer.
	resource.flags = 0;
	resource.usage = p_texture.usage;
	return resource;
}

// Refuses anything the OS does not trust, and anything not signed by NVIDIA.
//
// Streamline ships `sl::security::verifyEmbeddedSignature` for exactly this, and it additionally
// checks the *secondary* NVIDIA signature its binaries carry. It is not used here because it is
// written against the WinTrust dual-signature API, which mingw-w64's headers still do not
// declare, and this engine builds with MinGW as well as MSVC. What is left -- the OS trusts the
// Authenticode signature, and the signer is NVIDIA Corporation -- is the part that matters: it
// is what stops a hostile sl.interposer.dll dropped next to the executable from taking over the
// Vulkan loader for the whole process.
bool verify_nvidia_signature(const wchar_t *p_path) {
	WINTRUST_FILE_INFO file_info = {};
	file_info.cbStruct = sizeof(file_info);
	file_info.pcwszFilePath = p_path;

	GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
	WINTRUST_DATA trust_data = {};
	trust_data.cbStruct = sizeof(trust_data);
	trust_data.dwUIChoice = WTD_UI_NONE;
	trust_data.fdwRevocationChecks = WTD_REVOKE_NONE;
	trust_data.dwUnionChoice = WTD_CHOICE_FILE;
	trust_data.dwStateAction = WTD_STATEACTION_VERIFY;
	trust_data.pFile = &file_info;

	const LONG status = WinVerifyTrust(static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &trust_data);

	trust_data.dwStateAction = WTD_STATEACTION_CLOSE;
	WinVerifyTrust(static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &trust_data);

	if (status != ERROR_SUCCESS) {
		return false;
	}

	DWORD encoding = 0;
	DWORD content_type = 0;
	DWORD format_type = 0;
	HCERTSTORE store = nullptr;
	HCRYPTMSG message = nullptr;
	if (!CryptQueryObject(CERT_QUERY_OBJECT_FILE, p_path, CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
				CERT_QUERY_FORMAT_FLAG_BINARY, 0, &encoding, &content_type, &format_type, &store, &message, nullptr)) {
		return false;
	}

	bool signed_by_nvidia = false;
	DWORD signer_size = 0;
	if (CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0, nullptr, &signer_size) && signer_size > 0) {
		LocalVector<uint8_t> signer_buffer;
		signer_buffer.resize(signer_size);
		if (CryptMsgGetParam(message, CMSG_SIGNER_INFO_PARAM, 0, signer_buffer.ptr(), &signer_size)) {
			const CMSG_SIGNER_INFO *signer = reinterpret_cast<const CMSG_SIGNER_INFO *>(signer_buffer.ptr());

			CERT_INFO certificate_id = {};
			certificate_id.Issuer = signer->Issuer;
			certificate_id.SerialNumber = signer->SerialNumber;

			PCCERT_CONTEXT certificate = CertFindCertificateInStore(store, encoding, 0, CERT_FIND_SUBJECT_CERT, &certificate_id, nullptr);
			if (certificate != nullptr) {
				WCHAR subject[256] = {};
				if (CertGetNameStringW(certificate, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nullptr, subject, 256) > 1) {
					signed_by_nvidia = String::utf16(reinterpret_cast<const char16_t *>(subject)) == "NVIDIA Corporation";
				}
				CertFreeCertificateContext(certificate);
			}
		}
	}

	CryptMsgClose(message);
	CertCloseStore(store, 0);
	return signed_by_nvidia;
}

sl::Extent to_sl_extent(const StreamlineVK::Texture &p_texture) {
	sl::Extent extent;
	if (p_texture.extent.size.width > 0 && p_texture.extent.size.height > 0) {
		extent.left = uint32_t(p_texture.extent.position.x);
		extent.top = uint32_t(p_texture.extent.position.y);
		extent.width = uint32_t(p_texture.extent.size.width);
		extent.height = uint32_t(p_texture.extent.size.height);
	}
	return extent;
}

} // namespace

// Everything that would drag a Vulkan or Streamline type into the header lives here.
struct StreamlineVK::Internal {
	HMODULE module = nullptr;

	// Core entry points, resolved by name straight out of the interposer. The engine links
	// neither `sl.interposer.lib` nor `vulkan-1.lib`, so every one of these is a hand-resolved
	// pointer and a missing symbol only costs the feature, never the process.
	PFun_slInit *init = nullptr;
	PFun_slShutdown *shutdown = nullptr;
	PFun_slIsFeatureSupported *is_feature_supported = nullptr;
	PFun_slSetTagForFrame *set_tag_for_frame = nullptr;
	PFun_slSetConstants *set_constants = nullptr;
	PFun_slEvaluateFeature *evaluate_feature = nullptr;
	PFun_slFreeResources *free_resources = nullptr;
	PFun_slGetNewFrameToken *get_new_frame_token = nullptr;
	PFun_slGetFeatureFunction *get_feature_function = nullptr;

	// Feature entry points. `slGetFeatureFunction` needs a device, so these are resolved once
	// the physical device is known rather than at load time.
	PFun_slDLSSSetOptions *dlss_set_options = nullptr;
	PFun_slDLSSGSetOptions *dlssg_set_options = nullptr;
	PFun_slDLSSGGetState *dlssg_get_state = nullptr;
	PFun_slReflexSetOptions *reflex_set_options = nullptr;
	PFun_slReflexSleep *reflex_sleep = nullptr;
	PFun_slPCLSetMarker *pcl_set_marker = nullptr;

	void *vk_get_instance_proc_addr = nullptr;

	// slInit keeps a copy of the Preferences struct but not of the strings it points at, so
	// these have to live as long as the runtime does.
	Char16String plugin_path;
	Char16String log_path;
	CharString project_id;
	const wchar_t *plugin_paths[1] = {};

	bool supported[FEATURE_MAX] = {};
	bool device_ready = false;
	bool reflex_running = false;

	sl::FrameToken *frame = nullptr;
	uint32_t frame_index = 0;

	// The last options handed to each viewport, so options are only re-sent when they change.
	struct SuperResolutionState {
		Size2i output_size;
		Quality quality = QUALITY_DLAA;
		bool auto_exposure = false;
		bool configured = false;
	};
	struct FrameGenerationState {
		Size2i output_size;
		bool enabled = false;
		bool running = false;
	};
	HashMap<uint32_t, SuperResolutionState> super_resolution;
	HashMap<uint32_t, FrameGenerationState> frame_generation;

	template <typename T>
	bool resolve(T *&r_function, const char *p_name) {
		r_function = reinterpret_cast<T *>(reinterpret_cast<void *>(GetProcAddress(module, p_name)));
		if (r_function == nullptr) {
			ERR_PRINT(vformat("Streamline: '%s' is missing from sl.interposer.dll; the library is too old or damaged.", p_name));
			return false;
		}
		return true;
	}

	template <typename T>
	void resolve_feature(T *&r_function, sl::Feature p_feature, const char *p_name) {
		void *function = nullptr;
		if (get_feature_function != nullptr && get_feature_function(p_feature, p_name, function) == sl::Result::eOk) {
			r_function = reinterpret_cast<T *>(function);
		} else {
			r_function = nullptr;
		}
	}
};

uint64_t StreamlineVK::initialize() {
	ERR_FAIL_COND_V(singleton != nullptr, 0);

	const bool enabled = GLOBAL_GET("rendering/streamline/enabled");
	if (!enabled) {
		return 0;
	}

	// Resolve the directory holding sl.interposer.dll and the plugin DLLs. An empty setting
	// means "next to the executable", which is where an exported game's binaries end up.
	String directory = GLOBAL_GET("rendering/streamline/binary_path");
	if (directory.is_empty()) {
		directory = OS::get_singleton()->get_executable_path().get_base_dir();
	} else {
		directory = ProjectSettings::get_singleton()->globalize_path(directory);
	}
	directory = directory.simplify_path();

	StreamlineVK *instance = memnew(StreamlineVK);
	instance->internal = memnew(Internal);
	if (!instance->_load(directory)) {
		instance->_unload();
		memdelete(instance->internal);
		memdelete(instance);
		return 0;
	}

	singleton = instance;
	return uint64_t(uintptr_t(instance->internal->vk_get_instance_proc_addr));
}

void StreamlineVK::finalize() {
	if (singleton == nullptr) {
		return;
	}
	singleton->_unload();
	memdelete(singleton->internal);
	memdelete(singleton);
	singleton = nullptr;
}

bool StreamlineVK::_load(const String &p_directory) {
	const String interposer = p_directory.path_join("sl.interposer.dll");

	if (!FileAccess::exists(interposer)) {
		print_verbose(vformat("Streamline: '%s' was not found, continuing without it.", interposer));
		return false;
	}

	// NVIDIA signs the interposer and every plugin, and the interposer refuses to load a plugin
	// that is not signed. Checking the interposer itself closes the same hole one level up:
	// without this, dropping a hostile sl.interposer.dll next to the executable would be enough
	// to take over the Vulkan loader for the whole process.
	const Char16String interposer_utf16 = interposer.replace("/", "\\").utf16();
	if (!verify_nvidia_signature(reinterpret_cast<const wchar_t *>(interposer_utf16.get_data()))) {
		ERR_PRINT(vformat("Streamline: '%s' is not signed by NVIDIA and will not be loaded. Use the binaries from an NVIDIA Streamline release.", interposer));
		return false;
	}

	internal->module = LoadLibraryW(reinterpret_cast<LPCWSTR>(interposer_utf16.get_data()));
	if (internal->module == nullptr) {
		ERR_PRINT(vformat("Streamline: '%s' could not be loaded (error %d).", interposer, int(GetLastError())));
		return false;
	}

	const bool resolved =
			internal->resolve(internal->init, "slInit") &&
			internal->resolve(internal->shutdown, "slShutdown") &&
			internal->resolve(internal->is_feature_supported, "slIsFeatureSupported") &&
			internal->resolve(internal->set_tag_for_frame, "slSetTagForFrame") &&
			internal->resolve(internal->set_constants, "slSetConstants") &&
			internal->resolve(internal->evaluate_feature, "slEvaluateFeature") &&
			internal->resolve(internal->free_resources, "slFreeResources") &&
			internal->resolve(internal->get_new_frame_token, "slGetNewFrameToken") &&
			internal->resolve(internal->get_feature_function, "slGetFeatureFunction");
	if (!resolved) {
		return false;
	}

	// The interposer re-exports the Vulkan loader, returning its own proxy for the entry points
	// listed in sl_hooks.h and the loader's function for everything else. Handing this to volk
	// is the whole of the hooking: no engine call site changes.
	internal->vk_get_instance_proc_addr = reinterpret_cast<void *>(GetProcAddress(internal->module, "vkGetInstanceProcAddr"));
	if (internal->vk_get_instance_proc_addr == nullptr) {
		ERR_PRINT("Streamline: sl.interposer.dll does not export 'vkGetInstanceProcAddr'; it cannot proxy Vulkan.");
		return false;
	}

	internal->plugin_path = p_directory.replace("/", "\\").utf16();
	internal->plugin_paths[0] = reinterpret_cast<const wchar_t *>(internal->plugin_path.get_data());
	internal->log_path = OS::get_singleton()->get_user_data_dir().replace("/", "\\").utf16();
	internal->project_id = String(GLOBAL_GET("rendering/streamline/project_id")).utf8();

	// Reflex and PCL are always requested: frame generation refuses to run without Reflex, and
	// PCL carries the latency markers Reflex paces against.
	const sl::Feature features[] = { sl::kFeatureDLSS, sl::kFeatureDLSS_G, sl::kFeatureReflex, sl::kFeaturePCL };

	const bool verbose_logging = GLOBAL_GET("rendering/streamline/verbose_logging");

	sl::Preferences preferences;
	preferences.showConsole = false;
	preferences.logLevel = verbose_logging ? sl::LogLevel::eVerbose : sl::LogLevel::eOff;
	preferences.pathsToPlugins = internal->plugin_paths;
	preferences.numPathsToPlugins = 1;
	preferences.pathToLogsAndData = reinterpret_cast<const wchar_t *>(internal->log_path.get_data());
	// `eUseManualHooking` is what makes the interposer hand out proxies through
	// `vkGetInstanceProcAddr` instead of assuming it replaced the Vulkan loader outright.
	preferences.flags = sl::PreferenceFlags::eDisableCLStateTracking |
			sl::PreferenceFlags::eUseManualHooking |
			sl::PreferenceFlags::eUseFrameBasedResourceTagging |
			sl::PreferenceFlags::eAllowOTA |
			sl::PreferenceFlags::eLoadDownloadedPlugins;
	preferences.featuresToLoad = features;
	preferences.numFeaturesToLoad = sizeof(features) / sizeof(features[0]);
	preferences.engine = sl::EngineType::eCustom;
	preferences.engineVersion = GODOT_VERSION_FULL_CONFIG;
	preferences.projectId = internal->project_id.length() > 0 ? internal->project_id.get_data() : nullptr;
	// Without this, `slGetFeatureRequirements` and the create-device proxy would both assume D3D12.
	preferences.renderAPI = sl::RenderAPI::eVulkan;

	const sl::Result result = internal->init(preferences, sl::kSDKVersion);
	if (result != sl::Result::eOk) {
		ERR_PRINT(vformat("Streamline: slInit failed (%s).", sl::getResultAsStr(result)));
		return false;
	}

	print_verbose(vformat("Streamline %d.%d.%d loaded from '%s'.", SL_VERSION_MAJOR, SL_VERSION_MINOR, SL_VERSION_PATCH, p_directory));
	return true;
}

void StreamlineVK::_unload() {
	if (internal->shutdown != nullptr) {
		internal->shutdown();
	}
	if (internal->module != nullptr) {
		FreeLibrary(internal->module);
		internal->module = nullptr;
	}
}

void StreamlineVK::set_physical_device(uint64_t p_physical_device) {
	ERR_FAIL_NULL(internal);
	if (internal->device_ready) {
		// A second VkDevice -- a local rendering device, say. Streamline drives one device, and
		// it is the one the main window renders through.
		return;
	}

	sl::AdapterInfo adapter;
	adapter.vkPhysicalDevice = reinterpret_cast<void *>(uintptr_t(p_physical_device));

	for (uint32_t i = 0; i < FEATURE_MAX; i++) {
		const Feature feature = Feature(i);
		const sl::Result result = internal->is_feature_supported(to_sl_feature(feature), adapter);
		internal->supported[i] = result == sl::Result::eOk;
		if (!internal->supported[i]) {
			print_verbose(vformat("Streamline: %s is unavailable (%s).", feature_name(feature), sl::getResultAsStr(result)));
		}
	}

	internal->resolve_feature(internal->dlss_set_options, sl::kFeatureDLSS, "slDLSSSetOptions");
	internal->resolve_feature(internal->dlssg_set_options, sl::kFeatureDLSS_G, "slDLSSGSetOptions");
	internal->resolve_feature(internal->dlssg_get_state, sl::kFeatureDLSS_G, "slDLSSGGetState");
	internal->resolve_feature(internal->reflex_set_options, sl::kFeatureReflex, "slReflexSetOptions");
	internal->resolve_feature(internal->reflex_sleep, sl::kFeatureReflex, "slReflexSleep");
	internal->resolve_feature(internal->pcl_set_marker, sl::kFeaturePCL, "slPCLSetMarker");

	internal->device_ready = true;

	// Reflex is switched on for the whole process rather than per viewport: it paces the CPU
	// against the GPU, which is not a per-view idea, and frame generation refuses to start
	// unless it is already running.
	if (internal->supported[FEATURE_REFLEX] && internal->reflex_set_options != nullptr) {
		sl::ReflexOptions options;
		options.mode = sl::ReflexMode::eLowLatency;
		internal->reflex_running = internal->reflex_set_options(options) == sl::Result::eOk;
	}
}

bool StreamlineVK::is_supported(Feature p_feature) const {
	ERR_FAIL_INDEX_V(p_feature, FEATURE_MAX, false);
	return internal != nullptr && internal->device_ready && internal->supported[p_feature];
}

void StreamlineVK::frame_begin() {
	ERR_FAIL_NULL(internal);
	if (!internal->device_ready) {
		return;
	}

	internal->frame = nullptr;
	const uint32_t index = internal->frame_index++;
	if (internal->get_new_frame_token(internal->frame, &index) != sl::Result::eOk) {
		internal->frame = nullptr;
	}
}

void StreamlineVK::frame_end() {
	ERR_FAIL_NULL(internal);
	internal->frame = nullptr;
}

void StreamlineVK::sleep() {
	ERR_FAIL_NULL(internal);
	if (internal->frame == nullptr || !internal->reflex_running || internal->reflex_sleep == nullptr) {
		return;
	}
	internal->reflex_sleep(*internal->frame);
}

void StreamlineVK::set_marker(Marker p_marker) {
	ERR_FAIL_NULL(internal);
	if (internal->frame == nullptr || internal->pcl_set_marker == nullptr) {
		return;
	}

	sl::PCLMarker marker = sl::PCLMarker::eSimulationStart;
	switch (p_marker) {
		case MARKER_SIMULATION_START:
			marker = sl::PCLMarker::eSimulationStart;
			break;
		case MARKER_SIMULATION_END:
			marker = sl::PCLMarker::eSimulationEnd;
			break;
		case MARKER_RENDER_SUBMIT_START:
			marker = sl::PCLMarker::eRenderSubmitStart;
			break;
		case MARKER_RENDER_SUBMIT_END:
			marker = sl::PCLMarker::eRenderSubmitEnd;
			break;
		case MARKER_PRESENT_START:
			marker = sl::PCLMarker::ePresentStart;
			break;
		case MARKER_PRESENT_END:
			marker = sl::PCLMarker::ePresentEnd;
			break;
	}
	internal->pcl_set_marker(marker, *internal->frame);
}

StreamlineVK::Quality StreamlineVK::quality_from_scale(float p_scale) {
	// The thresholds sit halfway between the presets' own scale factors, so a viewport set to
	// one of DLSS's canonical scales lands on that preset exactly.
	if (p_scale >= 0.834f) {
		return QUALITY_DLAA; // 1.0
	} else if (p_scale >= 0.624f) {
		return QUALITY_MAX_QUALITY; // 0.667
	} else if (p_scale >= 0.539f) {
		return QUALITY_BALANCED; // 0.58
	} else if (p_scale >= 0.417f) {
		return QUALITY_MAX_PERFORMANCE; // 0.5
	}
	return QUALITY_ULTRA_PERFORMANCE; // 0.333
}

void StreamlineVK::_set_constants(uint32_t p_viewport, const CameraConstants &p_camera) {
	sl::Constants constants;
	constants.cameraViewToClip = to_sl_matrix(p_camera.view_to_clip);
	constants.clipToCameraView = to_sl_matrix(p_camera.clip_to_view);
	constants.clipToPrevClip = to_sl_matrix(p_camera.clip_to_prev_clip);
	constants.prevClipToClip = to_sl_matrix(p_camera.prev_clip_to_clip);
	constants.jitterOffset = sl::float2(p_camera.jitter_pixels.x, p_camera.jitter_pixels.y);
	// The engine writes `prev_uv - uv` scaled by 0.5, so a displacement across the whole screen
	// is 1.0 -- which is the same unit Streamline asks for when it says "normalized", and the
	// same one a pixel-space buffer reaches after being divided by the render size.
	constants.mvecScale = sl::float2(1.0f, 1.0f);
	constants.cameraPos = to_sl_vector(p_camera.camera_transform.origin);
	constants.cameraRight = to_sl_vector(p_camera.camera_transform.basis.get_column(0));
	constants.cameraUp = to_sl_vector(p_camera.camera_transform.basis.get_column(1));
	// Godot's cameras look down -Z, so the forward vector is the negated third basis column.
	constants.cameraFwd = to_sl_vector(-p_camera.camera_transform.basis.get_column(2));
	constants.cameraNear = p_camera.z_near;
	constants.cameraFar = p_camera.z_far;
	constants.cameraFOV = p_camera.fov_y;
	constants.cameraAspectRatio = p_camera.aspect;
	// Reverse-Z: the engine's depth buffer holds 1.0 at the near plane.
	constants.depthInverted = sl::Boolean::eTrue;
	constants.cameraMotionIncluded = sl::Boolean::eTrue;
	constants.motionVectors3D = sl::Boolean::eFalse;
	// The motion vector pass subtracts the jitter from both endpoints before differencing them.
	constants.motionVectorsJittered = sl::Boolean::eFalse;
	constants.motionVectorsDilated = sl::Boolean::eFalse;
	constants.reset = p_camera.reset ? sl::Boolean::eTrue : sl::Boolean::eFalse;
	constants.orthographicProjection = p_camera.orthographic ? sl::Boolean::eTrue : sl::Boolean::eFalse;

	internal->set_constants(constants, *internal->frame, sl::ViewportHandle(p_viewport));
}

bool StreamlineVK::super_resolution_evaluate(uint64_t p_command_buffer, uint32_t p_viewport, const Size2i &p_output_size, Quality p_quality, const CameraConstants &p_camera, const UpscaleInputs &p_inputs) {
	ERR_FAIL_NULL_V(internal, false);
	if (!is_supported(FEATURE_DLSS_SUPER_RESOLUTION) || internal->frame == nullptr || internal->dlss_set_options == nullptr) {
		return false;
	}
	ERR_FAIL_COND_V(!p_inputs.color.is_valid() || !p_inputs.depth.is_valid() || !p_inputs.motion_vectors.is_valid() || !p_inputs.output.is_valid(), false);

	const bool auto_exposure = !p_inputs.exposure.is_valid();
	Internal::SuperResolutionState &state = internal->super_resolution[p_viewport];
	if (!state.configured || state.output_size != p_output_size || state.quality != p_quality || state.auto_exposure != auto_exposure) {
		sl::DLSSOptions options;
		switch (p_quality) {
			case QUALITY_DLAA:
				options.mode = sl::DLSSMode::eDLAA;
				break;
			case QUALITY_MAX_QUALITY:
				options.mode = sl::DLSSMode::eMaxQuality;
				break;
			case QUALITY_BALANCED:
				options.mode = sl::DLSSMode::eBalanced;
				break;
			case QUALITY_MAX_PERFORMANCE:
				options.mode = sl::DLSSMode::eMaxPerformance;
				break;
			case QUALITY_ULTRA_PERFORMANCE:
				options.mode = sl::DLSSMode::eUltraPerformance;
				break;
		}
		options.outputWidth = uint32_t(p_output_size.width);
		options.outputHeight = uint32_t(p_output_size.height);
		// The engine's internal colour buffer is linear HDR, and the tone mapper runs after
		// upscaling, so DLSS is being handed pre-tonemap colour.
		options.colorBuffersHDR = sl::Boolean::eTrue;
		options.useAutoExposure = auto_exposure ? sl::Boolean::eTrue : sl::Boolean::eFalse;

		const sl::Result result = internal->dlss_set_options(sl::ViewportHandle(p_viewport), options);
		if (result != sl::Result::eOk) {
			ERR_PRINT_ONCE(vformat("Streamline: slDLSSSetOptions failed (%s).", sl::getResultAsStr(result)));
			return false;
		}

		state.output_size = p_output_size;
		state.quality = p_quality;
		state.auto_exposure = auto_exposure;
		state.configured = true;
	}

	_set_constants(p_viewport, p_camera);

	sl::Resource color = to_sl_resource(p_inputs.color);
	sl::Resource depth = to_sl_resource(p_inputs.depth);
	sl::Resource motion_vectors = to_sl_resource(p_inputs.motion_vectors);
	sl::Resource output = to_sl_resource(p_inputs.output);
	sl::Resource exposure = to_sl_resource(p_inputs.exposure);

	const sl::Extent color_extent = to_sl_extent(p_inputs.color);
	const sl::Extent depth_extent = to_sl_extent(p_inputs.depth);
	const sl::Extent motion_vectors_extent = to_sl_extent(p_inputs.motion_vectors);
	const sl::Extent output_extent = to_sl_extent(p_inputs.output);

	// These four are read and written inside this one `slEvaluateFeature` and nowhere else, so
	// they only have to survive until it returns.
	LocalVector<sl::ResourceTag> tags;
	tags.push_back(sl::ResourceTag(&color, sl::kBufferTypeScalingInputColor, sl::ResourceLifecycle::eValidUntilEvaluate, &color_extent));
	tags.push_back(sl::ResourceTag(&depth, sl::kBufferTypeDepth, sl::ResourceLifecycle::eValidUntilEvaluate, &depth_extent));
	tags.push_back(sl::ResourceTag(&motion_vectors, sl::kBufferTypeMotionVectors, sl::ResourceLifecycle::eValidUntilEvaluate, &motion_vectors_extent));
	tags.push_back(sl::ResourceTag(&output, sl::kBufferTypeScalingOutputColor, sl::ResourceLifecycle::eValidUntilEvaluate, &output_extent));
	if (p_inputs.exposure.is_valid()) {
		tags.push_back(sl::ResourceTag(&exposure, sl::kBufferTypeExposure, sl::ResourceLifecycle::eValidUntilEvaluate));
	}

	sl::CommandBuffer *command_buffer = reinterpret_cast<sl::CommandBuffer *>(uintptr_t(p_command_buffer));
	sl::Result result = internal->set_tag_for_frame(*internal->frame, sl::ViewportHandle(p_viewport), tags.ptr(), tags.size(), command_buffer);
	if (result != sl::Result::eOk) {
		ERR_PRINT_ONCE(vformat("Streamline: tagging the super resolution inputs failed (%s).", sl::getResultAsStr(result)));
		return false;
	}

	const sl::ViewportHandle viewport(p_viewport);
	const sl::BaseStructure *inputs[] = { &viewport };
	result = internal->evaluate_feature(sl::kFeatureDLSS, *internal->frame, inputs, 1, command_buffer);
	if (result != sl::Result::eOk) {
		ERR_PRINT_ONCE(vformat("Streamline: evaluating DLSS failed (%s).", sl::getResultAsStr(result)));
		return false;
	}

	return true;
}

void StreamlineVK::super_resolution_release(uint32_t p_viewport) {
	ERR_FAIL_NULL(internal);
	if (!internal->super_resolution.has(p_viewport)) {
		return;
	}
	internal->super_resolution.erase(p_viewport);
	if (internal->device_ready) {
		internal->free_resources(sl::kFeatureDLSS, sl::ViewportHandle(p_viewport));
	}
}

bool StreamlineVK::frame_generation_set_enabled(uint32_t p_viewport, bool p_enabled, const Size2i &p_output_size) {
	ERR_FAIL_NULL_V(internal, false);

	Internal::FrameGenerationState &state = internal->frame_generation[p_viewport];

	// Frame generation is refused rather than silently downgraded when Reflex is not running:
	// DLSS-G reports eFailReflexNotDetectedAtRuntime and stops presenting interpolated frames,
	// which is a much more confusing failure than not starting at all.
	const bool wanted = p_enabled && is_supported(FEATURE_DLSS_FRAME_GENERATION) && internal->reflex_running && internal->dlssg_set_options != nullptr;

	if (state.running == wanted && state.output_size == p_output_size) {
		return state.running;
	}
	if (!wanted && !state.running) {
		// Nothing to turn off, and the plugin may not even be loaded.
		state.enabled = p_enabled;
		return false;
	}

	sl::DLSSGOptions options;
	options.mode = wanted ? sl::DLSSGMode::eOn : sl::DLSSGMode::eOff;
	// A fixed 2x multiplier. Dynamic multi-frame generation is deliberately not used: it is
	// D3D12-only in this SDK, and `DLSSGMode::eDynamic` would silently do nothing here.
	options.numFramesToGenerate = 1;
	options.colorWidth = uint32_t(p_output_size.width);
	options.colorHeight = uint32_t(p_output_size.height);
	options.mvecDepthWidth = uint32_t(p_output_size.width);
	options.mvecDepthHeight = uint32_t(p_output_size.height);
	// Vulkan is the only API where the presenting queue does not have to be blocked while the
	// interpolation workload runs, which is where most of the multiplier actually comes from.
	options.queueParallelismMode = sl::DLSSGQueueParallelismMode::eBlockPresentingClientQueue;

	const sl::Result result = internal->dlssg_set_options(sl::ViewportHandle(p_viewport), options);
	if (result != sl::Result::eOk) {
		ERR_PRINT_ONCE(vformat("Streamline: slDLSSGSetOptions failed (%s).", sl::getResultAsStr(result)));
		state.enabled = p_enabled;
		state.running = false;
		return false;
	}

	state.enabled = p_enabled;
	state.running = wanted;
	state.output_size = p_output_size;
	return state.running;
}

bool StreamlineVK::frame_generation_is_running(uint32_t p_viewport) const {
	ERR_FAIL_NULL_V(internal, false);
	const Internal::FrameGenerationState *state = internal->frame_generation.getptr(p_viewport);
	return state != nullptr && state->running;
}

void StreamlineVK::frame_generation_release(uint32_t p_viewport) {
	ERR_FAIL_NULL(internal);
	if (!internal->frame_generation.has(p_viewport)) {
		return;
	}
	internal->frame_generation.erase(p_viewport);
	if (internal->device_ready) {
		internal->free_resources(sl::kFeatureDLSS_G, sl::ViewportHandle(p_viewport));
	}
}

void StreamlineVK::frame_generation_tag(uint64_t p_command_buffer, uint32_t p_viewport, const CameraConstants &p_camera, const FrameGenerationInputs &p_inputs) {
	ERR_FAIL_NULL(internal);
	if (!frame_generation_is_running(p_viewport) || internal->frame == nullptr) {
		return;
	}
	ERR_FAIL_COND(!p_inputs.depth.is_valid() || !p_inputs.motion_vectors.is_valid());

	_set_constants(p_viewport, p_camera);

	sl::Resource depth = to_sl_resource(p_inputs.depth);
	sl::Resource motion_vectors = to_sl_resource(p_inputs.motion_vectors);
	sl::Resource hudless = to_sl_resource(p_inputs.hudless_color);

	const sl::Extent depth_extent = to_sl_extent(p_inputs.depth);
	const sl::Extent motion_vectors_extent = to_sl_extent(p_inputs.motion_vectors);
	const sl::Extent hudless_extent = to_sl_extent(p_inputs.hudless_color);

	// Frame generation reads these inside the present hook, long after this command buffer has
	// been submitted, so they have to hold still until the frame is presented. That is exactly
	// why the hudless copy exists instead of tagging the render target directly: the render
	// target has the UI drawn over it before present.
	LocalVector<sl::ResourceTag> tags;
	tags.push_back(sl::ResourceTag(&depth, sl::kBufferTypeDepth, sl::ResourceLifecycle::eValidUntilPresent, &depth_extent));
	tags.push_back(sl::ResourceTag(&motion_vectors, sl::kBufferTypeMotionVectors, sl::ResourceLifecycle::eValidUntilPresent, &motion_vectors_extent));
	if (p_inputs.hudless_color.is_valid()) {
		tags.push_back(sl::ResourceTag(&hudless, sl::kBufferTypeHUDLessColor, sl::ResourceLifecycle::eValidUntilPresent, &hudless_extent));
	}

	sl::CommandBuffer *command_buffer = reinterpret_cast<sl::CommandBuffer *>(uintptr_t(p_command_buffer));
	const sl::Result result = internal->set_tag_for_frame(*internal->frame, sl::ViewportHandle(p_viewport), tags.ptr(), tags.size(), command_buffer);
	if (result != sl::Result::eOk) {
		ERR_PRINT_ONCE(vformat("Streamline: tagging the frame generation inputs failed (%s).", sl::getResultAsStr(result)));
	}
}

#endif // STREAMLINE_ENABLED
