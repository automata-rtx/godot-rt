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

#include "core/config/engine.h"
#include "core/config/project_settings.h"
#include "core/error/error_macros.h"
#include "core/io/file_access.h"
#include "core/os/os.h"
#include "core/string/print_string.h"
#include "core/templates/hash_map.h"
#include "core/templates/local_vector.h"
#include "core/version.h"
#include "drivers/vulkan/rendering_device_driver_vulkan.h"
#include "servers/rendering/rendering_device.h"

#include <windows.h>
// Order matters: these three need windows.h first.
#include <softpub.h>
#include <wincrypt.h>
#include <wintrust.h>

// The SDK's headers do not compile under this engine's warning set, and all three complaints are
// about the SDK's own declarations rather than anything a caller here does: DLSSOptions has a
// deprecated `sharpness` member that its own defaulted constructor initializes, PrecisionInfo's
// constructor names its parameters after its members, and FrameToken is a virtual interface with
// a non-virtual destructor -- deliberately, since it is never deleted through a base pointer.
GODOT_GCC_WARNING_PUSH
GODOT_GCC_WARNING_IGNORE("-Wdeprecated-declarations")
GODOT_GCC_WARNING_IGNORE("-Wshadow")
GODOT_GCC_WARNING_IGNORE("-Wnon-virtual-dtor")
GODOT_CLANG_WARNING_PUSH
GODOT_CLANG_WARNING_IGNORE("-Wdeprecated-declarations")
GODOT_CLANG_WARNING_IGNORE("-Wshadow")
GODOT_CLANG_WARNING_IGNORE("-Wnon-virtual-dtor")
GODOT_MSVC_WARNING_PUSH
GODOT_MSVC_WARNING_IGNORE(4458) // Declaration hides class member.
GODOT_MSVC_WARNING_IGNORE(4265) // Class has virtual functions but a non-virtual destructor.
GODOT_MSVC_WARNING_IGNORE(4996) // Deprecated declaration.
#include "sl.h"
#include "sl_consts.h"
#include "sl_dlss.h"
#include "sl_dlss_g.h"
#include "sl_helpers.h"
#include "sl_pcl.h"
#include "sl_reflex.h"
GODOT_MSVC_WARNING_POP
GODOT_CLANG_WARNING_POP
GODOT_GCC_WARNING_POP

StreamlineVK *StreamlineVK::singleton = nullptr;
String StreamlineVK::unavailability_reason;

String StreamlineVK::get_unavailability_reason() {
	if (unavailability_reason.is_empty()) {
		return "the reason was not recorded";
	}
	return unavailability_reason;
}

namespace {

// Identifies this engine to NGX when a project has not been given its own id by NVIDIA. Any
// stable GUID satisfies the requirement; what matters is that one is present at all.
constexpr const char *DEFAULT_PROJECT_ID = "b7f4c9a2-3e18-4d6b-91c5-0a7e2d84f36b";

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

// The files a feature is loaded from. DLSS and frame generation each need TWO: the Streamline
// plugin and, separately, the NGX model that does the actual work. Reflex needs neither, which is
// why a directory holding only the sl.*.dll files leaves Reflex working and DLSS reporting
// nothing -- the single most confusing way for this to be set up wrong.
const char *feature_files(StreamlineVK::Feature p_feature) {
	switch (p_feature) {
		case StreamlineVK::FEATURE_DLSS_SUPER_RESOLUTION:
			return "sl.dlss.dll and nvngx_dlss.dll";
		case StreamlineVK::FEATURE_DLSS_FRAME_GENERATION:
			return "sl.dlss_g.dll and nvngx_dlssg.dll";
		case StreamlineVK::FEATURE_REFLEX:
			return "sl.reflex.dll and sl.pcl.dll";
		default:
			return "";
	}
}

// Whether the result points at the feature's own files rather than at the machine.
bool result_blames_the_files(sl::Result p_result) {
	switch (p_result) {
		case sl::Result::eErrorFeatureMissing:
		case sl::Result::eErrorFeatureNotSupported:
		case sl::Result::eErrorFeatureFailedToLoad:
		case sl::Result::eErrorFeatureMissingDependency:
		case sl::Result::eErrorNoSupportedAdapterFound:
		case sl::Result::eErrorNGXFailed:
		case sl::Result::eErrorNoPlugins:
			return true;
		default:
			return false;
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

sl::CommandBuffer *to_sl_command_buffer(uint64_t p_command_buffer) {
	// Safe by construction: the only callers are driver callbacks registered through
	// `RenderingDevice::get_singleton()`, so the driver executing them is this one. Streamline
	// drives that device and no other -- a local rendering device is a separate VkDevice it was
	// never told about.
	RenderingDeviceDriverVulkan *driver = static_cast<RenderingDeviceDriverVulkan *>(RenderingDevice::get_singleton()->get_device_driver());
	return reinterpret_cast<sl::CommandBuffer *>(driver->command_buffer_get_vulkan_handle(RenderingDeviceDriver::CommandBufferID(p_command_buffer)));
}

String frame_generation_status_as_str(sl::DLSSGStatus p_status) {
	if (p_status == sl::DLSSGStatus::eOk) {
		return String();
	}
	Vector<String> reasons;
	if (p_status & sl::DLSSGStatus::eFailResolutionTooLow) {
		reasons.push_back("the output resolution is too low");
	}
	if (p_status & sl::DLSSGStatus::eFailReflexNotDetectedAtRuntime) {
		reasons.push_back("Reflex is not running");
	}
	if (p_status & sl::DLSSGStatus::eFailHDRFormatNotSupported) {
		reasons.push_back("the colour format is not supported");
	}
	if (p_status & sl::DLSSGStatus::eFailCommonConstantsInvalid) {
		reasons.push_back("the common constants are invalid");
	}
	if (p_status & sl::DLSSGStatus::eFailGetCurrentBackBufferIndexNotCalled) {
		reasons.push_back("the back buffer index was not queried");
	}
	if (reasons.is_empty()) {
		reasons.push_back(vformat("an unrecognized status (0x%x)", uint32_t(p_status)));
	}
	return String(", ").join(reasons);
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

sl::DLSSPreset to_sl_preset(StreamlineVK::Preset p_preset) {
	switch (p_preset) {
		case StreamlineVK::PRESET_J:
			return sl::DLSSPreset::ePresetJ;
		case StreamlineVK::PRESET_K:
			return sl::DLSSPreset::ePresetK;
		case StreamlineVK::PRESET_L:
			return sl::DLSSPreset::ePresetL;
		case StreamlineVK::PRESET_M:
			return sl::DLSSPreset::ePresetM;
		default:
			return sl::DLSSPreset::eDefault;
	}
}

const char *preset_letter(StreamlineVK::Preset p_preset) {
	switch (p_preset) {
		case StreamlineVK::PRESET_J:
			return "J";
		case StreamlineVK::PRESET_K:
			return "K";
		case StreamlineVK::PRESET_L:
			return "L";
		case StreamlineVK::PRESET_M:
			return "M";
		default:
			return "";
	}
}

// What the SDK documents each mode falling back to when no preset is forced. This is read off the
// `DLSSPreset` enum's own comments rather than out of the runtime, because nothing reports the
// choice back; the enum also warns that the default "may or may not change after an OTA", so
// anything shown from this table has to be labeled as the documented default and not as fact.
const char *documented_default_letter(StreamlineVK::Quality p_quality) {
	switch (p_quality) {
		case StreamlineVK::QUALITY_MAX_PERFORMANCE:
			return "M";
		case StreamlineVK::QUALITY_ULTRA_PERFORMANCE:
			return "L";
		default:
			return "K"; // DLAA, Quality and Balanced.
	}
}

// Whether NVIDIA's own on-screen DLSS indicator is switched on. It is the only thing that reports
// the model authoritatively -- the runtime draws the letter into the upscaled image from inside
// nvngx_dlss.dll, where the choice is actually made -- but it is a machine-wide registry switch
// with no API behind it, so the most an application can do is notice that it is on and say the
// letter on screen is worth more than a documented default. Reading the value needs no elevation;
// writing it does, which is why the SDK ships ngx_driver_onscreenindicator.reg to do it instead.
enum class IndicatorState {
	Unknown,
	Off,
	On,
};

IndicatorState nvidia_indicator_state() {
	// Read once. It cannot change without the driver being reloaded, and the overlay asking every
	// frame would put a registry hit in the frame loop for a value that never moves.
	static const IndicatorState state = []() {
		DWORD value = 0;
		DWORD size = sizeof(value);
		const LSTATUS result = RegGetValueW(HKEY_LOCAL_MACHINE,
				L"SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore",
				L"ShowDlssIndicator", RRF_RT_REG_DWORD, nullptr, &value, &size);
		if (result == ERROR_FILE_NOT_FOUND) {
			// The key exists on any machine with the NGX runtime; the value only once someone has
			// set it either way, so its absence means off rather than unknown.
			return IndicatorState::Off;
		}
		if (result != ERROR_SUCCESS) {
			return IndicatorState::Unknown;
		}
		return value != 0 ? IndicatorState::On : IndicatorState::Off;
	}();
	return state;
}

const char *quality_name(StreamlineVK::Quality p_quality) {
	switch (p_quality) {
		case StreamlineVK::QUALITY_MAX_QUALITY:
			return "Quality";
		case StreamlineVK::QUALITY_BALANCED:
			return "Balanced";
		case StreamlineVK::QUALITY_MAX_PERFORMANCE:
			return "Performance";
		case StreamlineVK::QUALITY_ULTRA_PERFORMANCE:
			return "Ultra Performance";
		default:
			return "DLAA";
	}
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
	PFun_slGetFeatureRequirements *get_feature_requirements = nullptr;

	// Feature entry points. `slGetFeatureFunction` needs a device, so these are resolved once
	// the physical device is known rather than at load time.
	PFun_slDLSSSetOptions *dlss_set_options = nullptr;
	PFun_slDLSSGSetOptions *dlssg_set_options = nullptr;
	PFun_slDLSSGGetState *dlssg_get_state = nullptr;
	PFun_slReflexSetOptions *reflex_set_options = nullptr;
	PFun_slReflexSleep *reflex_sleep = nullptr;
	PFun_slPCLSetMarker *pcl_set_marker = nullptr;

	void *vk_get_instance_proc_addr = nullptr;

	// The directory in readable form, for messages that have to name it.
	String plugin_directory;

	// slInit keeps a copy of the Preferences struct but not of the strings it points at, so
	// these have to live as long as the runtime does.
	Char16String plugin_path;
	Char16String log_path;
	CharString project_id;
	const wchar_t *plugin_paths[1] = {};

	bool supported[FEATURE_MAX] = {};
	// Whether sl.dlss_g was named in `featuresToLoad`. A feature left out of that list is freed
	// rather than loaded, so this decides both whether frame generation can run at all and
	// whether asking about its support would be meaningful.
	bool frame_generation_requested = false;
	// Mirrors rendering/streamline/verbose_logging, read once at load: the evaluate path runs on
	// the render thread inside a driver callback and must not touch ProjectSettings there.
	bool verbose_logging = false;
	bool device_ready = false;
	bool reflex_running = false;

	sl::FrameToken *frame = nullptr;
	uint32_t frame_index = 0;

	// The last options handed to each viewport, so options are only re-sent when they change.
	struct SuperResolutionState {
		Size2i output_size;
		Quality quality = QUALITY_DLAA;
		Preset preset = PRESET_DEFAULT;
		bool auto_exposure = false;
		bool upscale_alpha = false;
		bool configured = false;
	};
	struct FrameGenerationState {
		Size2i output_size;
		Size2i mvec_depth_size;
		bool enabled = false;
		bool running = false;
		// Only allocated while frame generation is running on this viewport.
		RID hudless_texture;
		Size2i hudless_size;
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
		r_function = nullptr;
		if (get_feature_function == nullptr) {
			return;
		}
		// The result was previously collapsed into the null check and thrown away.
		// A feature can be reported available by slIsFeatureSupported -- which only
		// needs the adapter -- and still fail to hand over its entry points, and
		// the consumer of a null pointer here just returns false. Name the entry
		// point and the reason, or the failure has no symptom at all.
		const sl::Result result = get_feature_function(p_feature, p_name, function);
		if (result != sl::Result::eOk) {
			WARN_PRINT(vformat("Streamline: could not resolve %s (%s). The feature will decline rather than run.", p_name, sl::getResultAsStr(result)));
			return;
		}
		r_function = reinterpret_cast<T *>(function);
	}
};

uint64_t StreamlineVK::initialize() {
	ERR_FAIL_COND_V(singleton != nullptr, 0);

	const bool enabled = GLOBAL_GET("rendering/streamline/enabled");
	if (!enabled) {
		unavailability_reason = "the rendering/streamline/enabled project setting is off (it takes a restart)";
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

	// Everything from here on reports at normal severity rather than through print_verbose. The
	// setting is off by default, so reaching this line means the user asked for Streamline: if it
	// then fails to arrive, saying so is not noise, and needing a command-line flag to find out
	// would make the failure undiagnosable from the editor.
	// The engine's own commit goes on this line too. Everything this integration reports afterwards
	// is read back as warning text and source line numbers, and neither means anything without
	// knowing which binary produced them -- a fix has already been judged against a stale build once
	// because there was no way to tell two builds apart from the output.
	const String build_hash = String(GODOT_VERSION_HASH);
	print_line(vformat("Streamline: enabled, loading from '%s' (engine build %s).", directory, build_hash.is_empty() ? String("unknown") : build_hash.substr(0, 9)));

	StreamlineVK *instance = memnew(StreamlineVK);
	instance->internal = memnew(Internal);
	if (!instance->_load(directory)) {
		instance->_unload();
		memdelete(instance->internal);
		memdelete(instance);
		return 0;
	}

	singleton = instance;
	// Overwritten by set_physical_device() once the adapter can be asked. Until then this is the
	// honest answer: the runtime is up but nothing has been queried yet.
	unavailability_reason = "the graphics device had not finished initializing when it was asked";
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
		unavailability_reason = vformat("'%s' does not exist; put sl.interposer.dll and the sl.*.dll plugins there, or point rendering/streamline/binary_path at the directory that holds them", interposer);
		ERR_PRINT(vformat("Streamline: '%s' does not exist. Put sl.interposer.dll and the sl.*.dll plugins in that directory, or point rendering/streamline/binary_path at the one that holds them.", interposer));
		return false;
	}

	// NVIDIA signs the interposer and every plugin, and the interposer refuses to load a plugin
	// that is not signed. Checking the interposer itself closes the same hole one level up:
	// without this, dropping a hostile sl.interposer.dll next to the executable would be enough
	// to take over the Vulkan loader for the whole process.
	const Char16String interposer_utf16 = interposer.replace("/", "\\").utf16();
	if (!verify_nvidia_signature(reinterpret_cast<const wchar_t *>(interposer_utf16.get_data()))) {
		unavailability_reason = vformat("'%s' is not signed by NVIDIA, so it was refused; use the binaries from an NVIDIA Streamline release", interposer);
		ERR_PRINT(vformat("Streamline: '%s' is not signed by NVIDIA and will not be loaded. Use the binaries from an NVIDIA Streamline release.", interposer));
		return false;
	}

	internal->module = LoadLibraryW(reinterpret_cast<LPCWSTR>(interposer_utf16.get_data()));
	if (internal->module == nullptr) {
		unavailability_reason = vformat("'%s' could not be loaded (Windows error %d)", interposer, int(GetLastError()));
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
			internal->resolve(internal->get_feature_function, "slGetFeatureFunction") &&
			internal->resolve(internal->get_feature_requirements, "slGetFeatureRequirements");
	if (!resolved) {
		return false;
	}

	// The interposer re-exports the Vulkan loader, returning its own proxy for the entry points
	// listed in sl_hooks.h and the loader's function for everything else. Handing this to volk
	// is the whole of the hooking: no engine call site changes.
	internal->vk_get_instance_proc_addr = reinterpret_cast<void *>(GetProcAddress(internal->module, "vkGetInstanceProcAddr"));
	if (internal->vk_get_instance_proc_addr == nullptr) {
		unavailability_reason = "sl.interposer.dll does not export 'vkGetInstanceProcAddr', so it cannot proxy Vulkan";
		ERR_PRINT("Streamline: sl.interposer.dll does not export 'vkGetInstanceProcAddr'; it cannot proxy Vulkan.");
		return false;
	}

	internal->plugin_directory = p_directory;
	internal->plugin_path = p_directory.replace("/", "\\").utf16();
	internal->plugin_paths[0] = reinterpret_cast<const wchar_t *>(internal->plugin_path.get_data());
	internal->log_path = OS::get_singleton()->get_user_data_dir().replace("/", "\\").utf16();
	// NGX will not initialize without an identity, and it accepts only two forms: an
	// NVIDIA-issued application id, or a project GUID paired with an engine name and version.
	// `slInit` takes an empty project id happily and the failure surfaces much later and
	// somewhere else -- sl.common logs "NGX based features will be disabled" and every
	// NGX-backed feature, which is every DLSS feature, reports eErrorFeatureNotSupported while
	// Reflex keeps working because it goes through NVAPI instead. So a default is shipped rather
	// than left to the project to discover.
	String project_id = GLOBAL_GET("rendering/streamline/project_id");
	if (project_id.is_empty()) {
		project_id = DEFAULT_PROJECT_ID;
	}
	internal->project_id = project_id.utf8();

	// Reflex and PCL are always requested: frame generation refuses to run without Reflex, and
	// PCL carries the latency markers Reflex paces against.
	//
	// Frame generation is the exception, and the reason is the swapchain. sl.dlss_g is the only
	// plugin that hooks `vkCreateSwapchainKHR`, and the interposer returns a before-hook's error
	// verbatim without ever calling the driver -- so a swapchain the plugin declines is a
	// swapchain that does not exist. DLSS-G attaches to whichever swapchain it is offered and
	// expects the application to have one, but the editor is a multi-window program in which every
	// context menu and menu bar dropdown is an OS window with a swapchain of its own. It also can
	// never run frame generation, because the image it presents is the editor's own interface
	// rather than a game frame. Loading the plugin there buys nothing and costs every popup in the
	// program. `featuresToLoad` is the documented way to say so: a feature left out of it is freed
	// on discovery rather than loaded, and its hooks go with it.
	internal->frame_generation_requested = !Engine::get_singleton()->is_editor_hint();

	const sl::Feature features[] = { sl::kFeatureDLSS, sl::kFeatureReflex, sl::kFeaturePCL, sl::kFeatureDLSS_G };
	const uint32_t feature_count = internal->frame_generation_requested ? 4 : 3;

	const bool verbose_logging = GLOBAL_GET("rendering/streamline/verbose_logging");
	internal->verbose_logging = verbose_logging;

	sl::Preferences preferences;
	preferences.showConsole = false;
	// Not `eOff`: that drops Streamline's own warnings and errors before they are even formatted,
	// which is how the reason a feature refused something gets lost. `eDefault` is warnings and
	// errors only and they land in sl.log beside the project's user data, which is where to look
	// when a feature loads and then misbehaves.
	preferences.logLevel = verbose_logging ? sl::LogLevel::eVerbose : sl::LogLevel::eDefault;
	preferences.pathsToPlugins = internal->plugin_paths;
	preferences.numPathsToPlugins = 1;
	preferences.pathToLogsAndData = reinterpret_cast<const wchar_t *>(internal->log_path.get_data());
	// `eUseManualHooking` does nothing on Vulkan. The interposer reads it only in
	// `slUpgradeInterface` and in sl.common's D3D12 pipeline restore; the Vulkan wrapper hands out
	// its proxies unconditionally. In particular it does NOT stop DLSS-G attaching to every
	// swapchain, which the DLSS-G guide's "unless manual hooking is used" reads like a promise of
	// -- that sentence is about the DXGI factory proxy, and the guide's own worked example for the
	// multiple-swapchain case uses `slSetFeatureLoaded` instead. On Vulkan the only levers are
	// which features are requested above and that call. The flag stays because it describes how
	// this engine attaches and because clearing it only re-arms D3D paths.
	preferences.flags = sl::PreferenceFlags::eDisableCLStateTracking |
			sl::PreferenceFlags::eUseManualHooking |
			sl::PreferenceFlags::eUseFrameBasedResourceTagging |
			sl::PreferenceFlags::eAllowOTA |
			sl::PreferenceFlags::eLoadDownloadedPlugins;
	preferences.featuresToLoad = features;
	preferences.numFeaturesToLoad = feature_count;
	preferences.engine = sl::EngineType::eCustom;
	preferences.engineVersion = GODOT_VERSION_FULL_CONFIG;
	preferences.projectId = internal->project_id.get_data();
	// Without this, `slGetFeatureRequirements` and the create-device proxy would both assume D3D12.
	preferences.renderAPI = sl::RenderAPI::eVulkan;

	const sl::Result result = internal->init(preferences, sl::kSDKVersion);
	if (result != sl::Result::eOk) {
		unavailability_reason = vformat("slInit failed (%s)", sl::getResultAsStr(result));
		ERR_PRINT(vformat("Streamline: slInit failed (%s).", sl::getResultAsStr(result)));
		return false;
	}

	print_line(vformat("Streamline %d.%d.%d initialized. Feature availability is reported once the graphics device exists.", SL_VERSION_MAJOR, SL_VERSION_MINOR, SL_VERSION_PATCH));
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

String StreamlineVK::_requirements_hint(Feature p_feature) {
	// The result code says which class of problem it is; this says which specific thing fell
	// short. Streamline tracks the versions it detected against the ones the feature needs, plus
	// the two machine-level settings people most often have switched off, so a refusal can be
	// reported as a number to compare rather than an enumerator to look up.
	if (internal->get_feature_requirements == nullptr) {
		return String();
	}

	sl::FeatureRequirements requirements;
	if (internal->get_feature_requirements(to_sl_feature(p_feature), requirements) != sl::Result::eOk) {
		// The usual reason this fails is that the feature's plugin never loaded, which the result
		// code above already conveys.
		return String();
	}

	Vector<String> notes;
	if (requirements.driverVersionRequired && requirements.driverVersionDetected < requirements.driverVersionRequired) {
		notes.push_back(vformat("needs driver %s, found %s", String(requirements.driverVersionRequired.toStr().c_str()), String(requirements.driverVersionDetected.toStr().c_str())));
	}
	if (requirements.osVersionRequired && requirements.osVersionDetected < requirements.osVersionRequired) {
		notes.push_back(vformat("needs OS %s, found %s", String(requirements.osVersionRequired.toStr().c_str()), String(requirements.osVersionDetected.toStr().c_str())));
	}
	// Deliberately not reported here: `eHardwareSchedulingRequired` says the feature *requires*
	// GPU Scheduling, not that this machine has it off. Mentioning it unconditionally told
	// people to change a setting that was already correct. `eErrorOSDisabledHWS` is the code
	// that means it is actually off, and it says so on its own.
	if (!(requirements.flags & sl::FeatureRequirementFlags::eVulkanSupported)) {
		notes.push_back("is not supported on Vulkan by this Streamline build");
	}
	if (notes.is_empty()) {
		return String();
	}
	return vformat(" It %s.", String("; and ").join(notes));
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

	// The LUID is what actually reaches the plugin's own per-adapter test. Without it
	// `slIsFeatureSupported` returns early -- `if (!ctx->isSupported || !adapterInfo.deviceLUID)
	// return Result::eOk;` -- and the only surviving adapter gate is "is any adapter on this
	// machine supported", which on a mixed-vendor machine answers about a GPU we are not
	// rendering on. Kept alive for the whole loop below, since Streamline reads through it.
	uint8_t device_luid[VK_LUID_SIZE] = {};
	if (vkGetPhysicalDeviceProperties2 != nullptr) {
		VkPhysicalDeviceIDProperties id_properties = {};
		id_properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES;

		VkPhysicalDeviceProperties2 properties = {};
		properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
		properties.pNext = &id_properties;

		vkGetPhysicalDeviceProperties2(VkPhysicalDevice(uintptr_t(p_physical_device)), &properties);
		if (id_properties.deviceLUIDValid) {
			memcpy(device_luid, id_properties.deviceLUID, VK_LUID_SIZE);
			adapter.deviceLUID = device_luid;
			adapter.deviceLUIDSizeInBytes = VK_LUID_SIZE;
		}
	}
	if (adapter.deviceLUID == nullptr) {
		WARN_PRINT("Streamline: this device reports no LUID, so feature support is answered for the machine rather than for this GPU.");
	}

	Vector<String> available;
	for (uint32_t i = 0; i < FEATURE_MAX; i++) {
		const Feature feature = Feature(i);
		if (feature == FEATURE_DLSS_FRAME_GENERATION && !internal->frame_generation_requested) {
			// Never asked for in this process, so never loaded. Asking anyway answers
			// `eErrorFeatureMissing` rather than anything that reads as "declined", because the
			// plugin's config is cached on discovery and only then is it freed for not having been
			// requested -- and the warning below would go on to name two DLL files that are
			// already sitting in the directory it points at.
			internal->supported[i] = false;
			continue;
		}
		const sl::Result result = internal->is_feature_supported(to_sl_feature(feature), adapter);
		internal->supported[i] = result == sl::Result::eOk;
		if (internal->supported[i]) {
			available.push_back(feature_name(feature));
		} else {
			// Named individually rather than summarized: the result code is the only thing that
			// separates "this GPU cannot" from "the plugin DLL is missing", and they need
			// different fixes.
			String detail = vformat("%s reported %s.%s", feature_name(feature), sl::getResultAsStr(result), _requirements_hint(feature));
			if (result_blames_the_files(result)) {
				detail += vformat(" It is loaded from %s, both of which must be in '%s'.", feature_files(feature), internal->plugin_directory);
			}
			if (feature == FEATURE_DLSS_SUPER_RESOLUTION) {
				unavailability_reason = detail;
			}
			WARN_PRINT("Streamline: " + detail);
		}
	}
	print_line(available.is_empty() ? String("Streamline: no features are available on this device.") : vformat("Streamline: available features are %s.", String(", ").join(available)));
	if (!internal->frame_generation_requested) {
		print_line("Streamline: DLSS frame generation is not loaded in the editor, where it would take over the swapchain of every window including menus and popups.");
	}

	internal->resolve_feature(internal->dlss_set_options, sl::kFeatureDLSS, "slDLSSSetOptions");
	internal->resolve_feature(internal->dlssg_set_options, sl::kFeatureDLSS_G, "slDLSSGSetOptions");
	internal->resolve_feature(internal->dlssg_get_state, sl::kFeatureDLSS_G, "slDLSSGGetState");
	internal->resolve_feature(internal->reflex_set_options, sl::kFeatureReflex, "slReflexSetOptions");
	internal->resolve_feature(internal->reflex_sleep, sl::kFeatureReflex, "slReflexSleep");
	internal->resolve_feature(internal->pcl_set_marker, sl::kFeaturePCL, "slPCLSetMarker");

	internal->device_ready = true;
	if (internal->supported[FEATURE_DLSS_SUPER_RESOLUTION]) {
		unavailability_reason = String();
	}

	// Reflex is switched on for the whole process rather than per viewport: it paces the CPU
	// against the GPU, which is not a per-view idea, and frame generation refuses to start
	// unless it is already running.
	if (internal->supported[FEATURE_REFLEX] && internal->reflex_set_options != nullptr) {
		sl::ReflexOptions options;
		options.mode = sl::ReflexMode::eLowLatency;
		const sl::Result reflex_result = internal->reflex_set_options(options);
		internal->reflex_running = reflex_result == sl::Result::eOk;
		if (!internal->reflex_running) {
			// Worth a line of its own: frame generation refuses to start unless
			// Reflex is running, and that refusal is otherwise silent all the way
			// up through DLSSFrameGeneration::update, which discards the bool.
			WARN_PRINT(vformat("Streamline: Reflex did not start (%s), so DLSS frame generation will refuse.", sl::getResultAsStr(reflex_result)));
		}
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
	const sl::Result sleep_result = internal->reflex_sleep(*internal->frame);
	if (sleep_result != sl::Result::eOk) {
		WARN_PRINT_ONCE(vformat("Streamline: slReflexSleep failed (%s).", sl::getResultAsStr(sleep_result)));
	}
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
	const sl::Result marker_result = internal->pcl_set_marker(marker, *internal->frame);
	if (marker_result != sl::Result::eOk) {
		WARN_PRINT_ONCE(vformat("Streamline: slPCLSetMarker failed (%s). Frame generation pacing depends on these markers.", sl::getResultAsStr(marker_result)));
	}
}

StreamlineVK::Texture StreamlineVK::texture_from_rid(RID p_texture, TextureUse p_use) {
	Texture texture;
	if (p_texture.is_null()) {
		return texture;
	}

	RenderingDevice *rendering_device = RenderingDevice::get_singleton();
	ERR_FAIL_NULL_V(rendering_device, texture);
	texture.image = rendering_device->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_TEXTURE, p_texture);
	texture.view = rendering_device->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_TEXTURE_VIEW, p_texture);
	texture.format = uint32_t(rendering_device->get_driver_resource(RenderingDevice::DRIVER_RESOURCE_TEXTURE_DATA_FORMAT, p_texture));

	const RenderingDevice::TextureFormat format = rendering_device->texture_get_format(p_texture);
	texture.size = Size2i(int(format.width), int(format.height));

	// Streamline hands these straight to its own Vulkan backend, so they have to be the flags
	// the image was actually created with. This mirrors the mapping in
	// `RenderingDeviceDriverVulkan::texture_create()`; the two must not drift apart.
	uint32_t usage = 0;
	if (format.usage_bits & RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT) {
		usage |= VK_IMAGE_USAGE_SAMPLED_BIT;
	}
	if (format.usage_bits & RenderingDevice::TEXTURE_USAGE_STORAGE_BIT) {
		usage |= VK_IMAGE_USAGE_STORAGE_BIT;
	}
	if (format.usage_bits & RenderingDevice::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT) {
		usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
	}
	if (format.usage_bits & (RenderingDevice::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | RenderingDevice::TEXTURE_USAGE_DEPTH_RESOLVE_ATTACHMENT_BIT)) {
		usage |= VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
	}
	if (format.usage_bits & RenderingDevice::TEXTURE_USAGE_INPUT_ATTACHMENT_BIT) {
		usage |= VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT;
	}
	if (format.usage_bits & RenderingDevice::TEXTURE_USAGE_CAN_UPDATE_BIT) {
		usage |= VK_IMAGE_USAGE_TRANSFER_DST_BIT;
	}
	if (format.usage_bits & RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT) {
		usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
	}
	if (format.usage_bits & RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT) {
		usage |= VK_IMAGE_USAGE_TRANSFER_DST_BIT;
	}
	texture.usage = usage;

	// See TextureUse: the render graph put the image in this layout before the callback ran.
	texture.layout = p_use == TEXTURE_USE_STORAGE ? uint32_t(VK_IMAGE_LAYOUT_GENERAL) : uint32_t(VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

	return texture;
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

	// Camera matrices, jitter and depth conventions. Every feature reads these,
	// so a failure here is a wrong image rather than a missing one -- which is the
	// hardest kind to attribute, and it was previously not reported at all.
	const sl::Result constants_result = internal->set_constants(constants, *internal->frame, sl::ViewportHandle(p_viewport));
	if (constants_result != sl::Result::eOk) {
		ERR_PRINT_ONCE(vformat("Streamline: slSetConstants failed (%s).", sl::getResultAsStr(constants_result)));
	}
}

String StreamlineVK::super_resolution_preset_description(uint32_t p_viewport) const {
	ERR_FAIL_NULL_V(internal, String());
	const Internal::SuperResolutionState *state = internal->super_resolution.getptr(p_viewport);
	if (state == nullptr || !state->configured) {
		return String();
	}
	if (state->preset != PRESET_DEFAULT) {
		// Forced by the project, so this one is fact: it is exactly what was handed to the runtime.
		return String(preset_letter(state->preset));
	}
	// Nothing reads the active model back. `DLSSState` carries only a VRAM estimate, every NGX
	// preset parameter is a write-only hint, and NVIDIA's own debug overlay inside sl.dlss prints
	// the quality mode and not the preset -- the plugin does not know it either. So the honest
	// answer for a viewport on the default is the preset the SDK documents for its mode, said as
	// such, and a pointer at the one thing that does know when it is switched on.
	const String documented = vformat("%s (documented default)", documented_default_letter(state->quality));
	return nvidia_indicator_state() == IndicatorState::On ? documented + " " + String::utf8("\u2014 NVIDIA's indicator is on, trust the letter it draws") : documented;
}

String StreamlineVK::super_resolution_mode_name(uint32_t p_viewport) const {
	ERR_FAIL_NULL_V(internal, String());
	const Internal::SuperResolutionState *state = internal->super_resolution.getptr(p_viewport);
	if (state == nullptr || !state->configured) {
		return String();
	}
	return String(quality_name(state->quality));
}

bool StreamlineVK::super_resolution_evaluate(uint64_t p_command_buffer, uint32_t p_viewport, const Size2i &p_output_size, Quality p_quality, Preset p_preset, bool p_upscale_alpha, const CameraConstants &p_camera, const UpscaleInputs &p_inputs) {
	ERR_FAIL_NULL_V(internal, false);
	// Split three ways deliberately. These are the three distinct reasons DLSS
	// silently does not run, they are reached before the verbose logging below,
	// and collapsing them into one return is what makes "DLSS is enabled and the
	// image never changed" undiagnosable.
	if (!is_supported(FEATURE_DLSS_SUPER_RESOLUTION)) {
		WARN_PRINT_ONCE("Streamline: DLSS super resolution was requested but is not supported on this device, or the device is not ready.");
		return false;
	}
	if (internal->frame == nullptr) {
		WARN_PRINT_ONCE("Streamline: DLSS super resolution was requested but no frame token exists; slGetNewFrameToken has not produced one.");
		return false;
	}
	if (internal->dlss_set_options == nullptr) {
		WARN_PRINT_ONCE("Streamline: DLSS super resolution was requested but slDLSSSetOptions never resolved.");
		return false;
	}
	ERR_FAIL_COND_V(!p_inputs.color.is_valid() || !p_inputs.depth.is_valid() || !p_inputs.motion_vectors.is_valid() || !p_inputs.output.is_valid(), false);

	const bool auto_exposure = !p_inputs.exposure.is_valid();
	Internal::SuperResolutionState &state = internal->super_resolution[p_viewport];
	if (!state.configured || state.output_size != p_output_size || state.quality != p_quality || state.preset != p_preset || state.auto_exposure != auto_exposure || state.upscale_alpha != p_upscale_alpha) {
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
		// DLSS upscales RGB only unless asked otherwise, and the engine reads the upscaled image's
		// alpha straight through -- the tone mapper samples the upscaled colour and writes all four
		// channels. On a viewport with a transparent background that alpha is the subject's
		// coverage, so an RGB-only upscale hands back whatever the runtime happened to leave in the
		// channel: opaque black behind the subject where there should be nothing. Asked for only
		// where the alpha is actually read, because NVIDIA documents it as costing performance.
		options.alphaUpscalingEnabled = p_upscale_alpha ? sl::Boolean::eTrue : sl::Boolean::eFalse;
		// Set on every mode rather than only the active one: the mode follows the viewport's 3D
		// scale, so it changes under the project's feet, and a preset that only applied to
		// whichever mode happened to be selected when it was set would be a confusing knob.
		const sl::DLSSPreset preset = to_sl_preset(p_preset);
		options.dlaaPreset = preset;
		options.qualityPreset = preset;
		options.balancedPreset = preset;
		options.performancePreset = preset;
		options.ultraPerformancePreset = preset;
		options.ultraQualityPreset = preset;

		const sl::Result result = internal->dlss_set_options(sl::ViewportHandle(p_viewport), options);
		if (result != sl::Result::eOk) {
			ERR_PRINT_ONCE(vformat("Streamline: slDLSSSetOptions failed (%s).", sl::getResultAsStr(result)));
			return false;
		}

		state.output_size = p_output_size;
		state.quality = p_quality;
		state.preset = p_preset;
		state.auto_exposure = auto_exposure;
		state.upscale_alpha = p_upscale_alpha;
		state.configured = true;
	}

	if (internal->verbose_logging) {
		// One line per evaluate, naming the viewport handle it is for. Which viewport a Streamline
		// call belongs to is otherwise invisible from outside, which turns any question about one
		// viewport's upscaling reaching another into guesswork.
		const char *letter = preset_letter(p_preset);
		// `extent` rather than `size`: the colour buffer can be larger than the region actually
		// rendered, and the extent is what Streamline upscales from.
		const Size2i input_size = p_inputs.color.extent.size == Size2i() ? p_inputs.color.size : p_inputs.color.extent.size;
		print_line(vformat("Streamline: DLSS evaluate on viewport handle %d, %dx%d -> %dx%d, %s, preset %s%s.",
				int(p_viewport), input_size.width, input_size.height,
				p_output_size.width, p_output_size.height, quality_name(p_quality),
				letter[0] == 0 ? "default" : letter, p_upscale_alpha ? ", alpha" : ""));
	}

	_set_constants(p_viewport, p_camera);

	sl::Resource color = to_sl_resource(p_inputs.color);
	sl::Resource depth = to_sl_resource(p_inputs.depth);
	sl::Resource motion_vectors = to_sl_resource(p_inputs.motion_vectors);
	sl::Resource output = to_sl_resource(p_inputs.output);
	sl::Resource exposure = to_sl_resource(p_inputs.exposure);
	sl::Resource reactive = to_sl_resource(p_inputs.reactive);

	const sl::Extent reactive_extent = to_sl_extent(p_inputs.reactive);
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
	if (p_inputs.reactive.is_valid()) {
		// Which pixels the motion vectors do not describe, so the model leans on the
		// current frame there instead of dragging history across them. The renderer
		// already computes this for FSR2; DLSS needs it copied into an image of its
		// own first, because a view of the colour buffer shares that buffer's
		// VkImage and the two tags collide.
		tags.push_back(sl::ResourceTag(&reactive, sl::kBufferTypeBiasCurrentColorHint, sl::ResourceLifecycle::eValidUntilEvaluate, &reactive_extent));
	}

	sl::CommandBuffer *command_buffer = to_sl_command_buffer(p_command_buffer);
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

bool StreamlineVK::frame_generation_set_enabled(uint32_t p_viewport, bool p_enabled, const Size2i &p_output_size, const Size2i &p_mvec_depth_size) {
	ERR_FAIL_NULL_V(internal, false);

	Internal::FrameGenerationState &state = internal->frame_generation[p_viewport];

	// Frame generation is refused rather than silently downgraded when Reflex is not running:
	// DLSS-G reports eFailReflexNotDetectedAtRuntime and stops presenting interpolated frames,
	// which is a much more confusing failure than not starting at all.
	const bool wanted = p_enabled && is_supported(FEATURE_DLSS_FRAME_GENERATION) && internal->reflex_running && internal->dlssg_set_options != nullptr;

	if (state.running == wanted && state.output_size == p_output_size && state.mvec_depth_size == p_mvec_depth_size) {
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
	// Depth and motion vectors come from the 3D buffers, which are at the internal size when
	// the viewport is upscaling.
	options.mvecDepthWidth = uint32_t(p_mvec_depth_size.width);
	options.mvecDepthHeight = uint32_t(p_mvec_depth_size.height);
	options.queueParallelismMode = sl::DLSSGQueueParallelismMode::eBlockPresentingClientQueue;

	const sl::Result result = internal->dlssg_set_options(sl::ViewportHandle(p_viewport), options);
	if (result != sl::Result::eOk) {
		ERR_PRINT_ONCE(vformat("Streamline: slDLSSGSetOptions failed (%s).", sl::getResultAsStr(result)));
		state.enabled = p_enabled;
		state.running = false;
		_free_hudless(p_viewport);
		return false;
	}

	state.enabled = p_enabled;
	state.running = wanted;
	state.output_size = p_output_size;
	state.mvec_depth_size = p_mvec_depth_size;
	if (!state.running) {
		_free_hudless(p_viewport);
	}
	return state.running;
}

void StreamlineVK::_free_hudless(uint32_t p_viewport) {
	Internal::FrameGenerationState *state = internal->frame_generation.getptr(p_viewport);
	if (state != nullptr && state->hudless_texture.is_valid()) {
		// Null during shutdown, when the render buffers are torn down after the device.
		if (RenderingDevice::get_singleton() != nullptr) {
			RenderingDevice::get_singleton()->free_rid(state->hudless_texture);
		}
		state->hudless_texture = RID();
		state->hudless_size = Size2i();
	}
}

void StreamlineVK::frame_generation_capture_hudless(uint32_t p_viewport, RID p_source_texture, const Size2i &p_size) {
	ERR_FAIL_NULL(internal);
	Internal::FrameGenerationState *state = internal->frame_generation.getptr(p_viewport);
	if (state == nullptr || !state->running || p_source_texture.is_null()) {
		return;
	}

	RenderingDevice *rendering_device = RenderingDevice::get_singleton();
	const RenderingDevice::TextureFormat source_format = rendering_device->texture_get_format(p_source_texture);
	const Size2i size = Size2i(int(source_format.width), int(source_format.height));
	if (size.width <= 0 || size.height <= 0) {
		return;
	}

	// Frame generation was configured with the size the caller expected the presented image to
	// be. If the render target turns out to be a different size, the copy still succeeds but
	// what Streamline interpolates no longer matches what it was told to expect.
	if (size != p_size) {
		WARN_PRINT_ONCE(vformat("Streamline: the render target is %dx%d but frame generation was configured for %dx%d.", size.width, size.height, p_size.width, p_size.height));
	}

	if (state->hudless_texture.is_null() || state->hudless_size != size) {
		_free_hudless(p_viewport);

		RenderingDevice::TextureFormat format;
		format.format = source_format.format;
		format.width = source_format.width;
		format.height = source_format.height;
		format.usage_bits = RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT;

		state->hudless_texture = rendering_device->texture_create(format, RenderingDevice::TextureView());
		ERR_FAIL_COND(state->hudless_texture.is_null());
		state->hudless_size = size;
		rendering_device->set_resource_name(state->hudless_texture, "Streamline HUD-less Color");
	}

	rendering_device->texture_copy(p_source_texture, state->hudless_texture, Vector3(), Vector3(), Vector3(size.width, size.height, 1), 0, 0, 0, 0);
}

RID StreamlineVK::frame_generation_get_hudless(uint32_t p_viewport) const {
	ERR_FAIL_NULL_V(internal, RID());
	const Internal::FrameGenerationState *state = internal->frame_generation.getptr(p_viewport);
	return state != nullptr ? state->hudless_texture : RID();
}

bool StreamlineVK::frame_generation_is_running(uint32_t p_viewport) const {
	ERR_FAIL_NULL_V(internal, false);
	const Internal::FrameGenerationState *state = internal->frame_generation.getptr(p_viewport);
	return state != nullptr && state->running;
}

void StreamlineVK::frame_generation_release(uint32_t p_viewport) {
	ERR_FAIL_NULL(internal);
	Internal::FrameGenerationState *state = internal->frame_generation.getptr(p_viewport);
	if (state == nullptr) {
		return;
	}
	_free_hudless(p_viewport);
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

	const sl::Result result = internal->set_tag_for_frame(*internal->frame, sl::ViewportHandle(p_viewport), tags.ptr(), tags.size(), to_sl_command_buffer(p_command_buffer));
	if (result != sl::Result::eOk) {
		ERR_PRINT_ONCE(vformat("Streamline: tagging the frame generation inputs failed (%s).", sl::getResultAsStr(result)));
	}

	// Frame generation reports why it is not interpolating rather than failing any call, so
	// without this a machine that cannot run it looks identical to one where it is working.
	if (internal->dlssg_get_state != nullptr) {
		sl::DLSSGState fg_state;
		if (internal->dlssg_get_state(sl::ViewportHandle(p_viewport), fg_state, nullptr) == sl::Result::eOk && fg_state.status != sl::DLSSGStatus::eOk) {
			WARN_PRINT_ONCE(vformat("Streamline: frame generation is not running because %s.", frame_generation_status_as_str(fg_state.status)));
		}
	}
}

#endif // STREAMLINE_ENABLED
