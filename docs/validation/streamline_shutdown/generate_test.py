"""Generate an isolated C++ test of the production Streamline cleanup methods.

Compile the output as a standalone executable (C++17). It uses fake Vulkan/SDK
entry points and never loads Godot, Streamline, Vulkan, or a game project.
"""

import argparse
from pathlib import Path


def extract(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


PREAMBLE = r"""
#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

using String = std::string;
using HMODULE = void *;
using VkDevice = void *;
using VkResult = int;
constexpr int VK_SUCCESS = 0;
std::vector<std::string> events;
int wait_result = VK_SUCCESS;
bool fail_free = false;
bool fail_shutdown = false;
void *waited_device = nullptr;

namespace sl {
enum class Result { eOk, eError };
constexpr int kFeatureDLSS = 0;
constexpr int kFeatureDLSS_G = 1;
using ViewportHandle = uint32_t;
const char *getResultAsStr(Result) { return "fake result"; }
}
template <class... T> String vformat(const char *message, T...) { return message; }
void print_verbose(const String &) { events.push_back("success"); }
#define ERR_PRINT(message) events.push_back("error")
#define ERR_FAIL_COND(condition) if (condition) { events.push_back("guard"); return; }
#define ERR_FAIL_COND_MSG(condition, message) ERR_FAIL_COND(condition)
#define memdelete(pointer) delete pointer

VkResult vkDeviceWaitIdle(VkDevice device) {
    waited_device = device;
    events.push_back("idle");
    return wait_result;
}
void FreeLibrary(HMODULE) { events.push_back("unload"); }
sl::Result fake_free(int feature, uint32_t viewport) {
    events.push_back((feature == 0 ? "sr:" : "fg:") + std::to_string(viewport));
    return fail_free ? sl::Result::eError : sl::Result::eOk;
}
sl::Result fake_shutdown() {
    events.push_back("shutdown");
    return fail_shutdown ? sl::Result::eError : sl::Result::eOk;
}
template <class K, class V> struct KeyValue { K key; V value; };

class StreamlineVK {
public:
    enum { FEATURE_DLSS_FRAME_GENERATION, FEATURE_MAX };
    struct Internal {
        struct SuperResolutionState {};
        struct FrameGenerationState {};
        bool initialized = false;
        bool shutdown_attempted = false;
        bool device_ready = false;
        bool reflex_running = false;
        bool supported[FEATURE_MAX] = {};
        uint64_t device = 0;
        void *frame = nullptr;
        HMODULE module = nullptr;
        HMODULE vulkan_loader = nullptr;
        void *dlssg_set_options = nullptr;
        std::vector<KeyValue<uint32_t, SuperResolutionState>> super_resolution;
        std::vector<KeyValue<uint32_t, FrameGenerationState>> frame_generation;
        sl::Result (*free_resources)(int, uint32_t) = fake_free;
        sl::Result (*shutdown)() = fake_shutdown;
    };
    Internal *internal = nullptr;
    static StreamlineVK *singleton;
    static String unavailability_reason;
    void bind_device(uint64_t);
    void shutdown_device(uint64_t);
    void _shutdown();
    void _unload();
    static void finalize();
    void _free_hudless(uint32_t viewport) {
        events.push_back("hudless:" + std::to_string(viewport));
    }
};
StreamlineVK *StreamlineVK::singleton = nullptr;
String StreamlineVK::unavailability_reason;
"""

TESTS = r"""
void expect(std::initializer_list<const char *> expected) {
    std::vector<std::string> wanted(expected.begin(), expected.end());
    if (events != wanted) {
        for (const auto &event : events) std::cerr << event << ' ';
        std::cerr << '\n';
        std::abort();
    }
}
void fresh(bool initialized) {
    events.clear();
    wait_result = VK_SUCCESS;
    fail_free = fail_shutdown = false;
    waited_device = nullptr;
    StreamlineVK::singleton = new StreamlineVK;
    auto *state = new StreamlineVK::Internal;
    StreamlineVK::singleton->internal = state;
    state->initialized = initialized;
    state->module = reinterpret_cast<void *>(1);
}
int main() {
    // Missing exports / failed slInit: unloading must not call an uninitialized SDK.
    fresh(false);
    StreamlineVK::singleton->shutdown_device(0);
    StreamlineVK::finalize();
    expect({"unload"});

    // slInit succeeded, but Vulkan device creation failed. No wait on a null device.
    fresh(true);
    StreamlineVK::singleton->shutdown_device(0);
    StreamlineVK::singleton->shutdown_device(0);
    StreamlineVK::finalize();
    StreamlineVK::finalize();
    expect({"shutdown", "success", "unload"});

    // A separate device neither replaces ownership nor triggers SDK shutdown.
    fresh(true);
    auto *runtime = StreamlineVK::singleton;
    runtime->bind_device(17);
    runtime->bind_device(23);
    runtime->shutdown_device(23);
    runtime->shutdown_device(0);
    expect({});
    assert(runtime->internal->device == 17);
    runtime->internal->device_ready = true;
    runtime->internal->reflex_running = true;
    runtime->internal->frame = reinterpret_cast<void *>(1);
    runtime->internal->super_resolution.push_back({3, {}});
    runtime->internal->frame_generation.push_back({5, {}});
    runtime->internal->supported[0] = true;
    runtime->internal->dlssg_set_options = reinterpret_cast<void *>(1);
    runtime->internal->vulkan_loader = reinterpret_cast<void *>(2);
    runtime->shutdown_device(17);
    expect({"idle", "sr:3", "fg:5", "hudless:5", "shutdown", "success"});
    assert(waited_device == reinterpret_cast<void *>(17));
    assert(!runtime->internal->device_ready && !runtime->internal->reflex_running);
    assert(!runtime->internal->frame);
    assert(runtime->internal->super_resolution.empty());
    assert(runtime->internal->frame_generation.empty());
    runtime->shutdown_device(17); // Driver destructor fallback must be harmless.
    StreamlineVK::finalize();
    expect({"idle", "sr:3", "fg:5", "hudless:5", "shutdown", "success", "unload", "unload"});

    // SDK failure after partial plugin destruction is logged, never retried.
    fresh(true);
    runtime = StreamlineVK::singleton;
    runtime->bind_device(17);
    wait_result = -4; // Device lost: still attempt shutdown once and report both errors.
    fail_free = fail_shutdown = true;
    runtime->internal->super_resolution.push_back({3, {}});
    runtime->shutdown_device(17);
    runtime->shutdown_device(17);
    StreamlineVK::finalize();
    expect({"idle", "error", "sr:3", "error", "shutdown", "error", "unload"});

    // A recorded viewport does not imply the optional DLSS-G plugin was loaded.
    fresh(true);
    runtime = StreamlineVK::singleton;
    runtime->bind_device(17);
    runtime->internal->frame_generation.push_back({5, {}});
    runtime->shutdown_device(17);
    StreamlineVK::finalize();
    expect({"idle", "hudless:5", "shutdown", "success", "unload"});

    // If the integration ever omits early shutdown, do not call into a dead device.
    fresh(true);
    StreamlineVK::finalize();
    expect({"guard"});
    assert(StreamlineVK::singleton != nullptr);
    StreamlineVK::singleton->shutdown_device(0);
    StreamlineVK::finalize();
    expect({"guard", "shutdown", "success", "unload"});
    std::cout << "PASS: 6 production-cleanup scenarios; no engine or SDK loaded.\n";
}
"""


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    source = (root / "drivers/vulkan/streamline_vk.cpp").read_text(encoding="utf-8")
    methods = [
        "void StreamlineVK::bind_device(",
        "void StreamlineVK::shutdown_device(",
        "void StreamlineVK::_shutdown(",
        "void StreamlineVK::_unload(",
        "void StreamlineVK::finalize(",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        PREAMBLE + "\n".join(extract(source, method) for method in methods) + TESTS,
        encoding="utf-8",
    )
    print(f"Generated standalone test from production methods: {args.output}")


if __name__ == "__main__":
    main()
