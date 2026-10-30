"""Execute production scalar shader policies as C++; not a GPU quality test."""

import re
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[3]
source = root / "servers/rendering/renderer_rd/shaders/effects/amd_gi_response_inc.glsl"
policy = source.read_text().split("// One byte per cell")[0]
lights = source.with_name("amd_gi_lights_inc.glsl").read_text()
certificate = (
    "bool gi_confirm_unlit_analytic_hit"
    + lights.split("bool gi_confirm_unlit_analytic_hit", 1)[1].split("vec3 resampled_direct", 1)[0]
)
certificate = certificate.replace("ray.geometry_normal.xyz", "ray.geometry_normal")
test = r"""
#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>
using uint = unsigned;
using std::min;
using std::max;
using std::clamp;
float mix(float a, float b, float t) { return a + (b-a)*t; }
float smoothstep(float a, float b, float x) {
    x = std::clamp((x-a)/(b-a), 0.0f, 1.0f);
    return x*x*(3-2*x);
}
POLICY
struct vec2 { explicit vec2(float) {} };
struct vec3 {
    float x,y,z;
    explicit vec3(float v=0) : x(v), y(v), z(v) {}
};
vec3 abs(vec3 v) { v.x=std::abs(v.x); v.y=std::abs(v.y); v.z=std::abs(v.z); return v; }
float dot(vec3 a,vec3 b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
struct RayHit { vec3 geometry_normal; };
struct { uint light_count=0; } params;
struct { struct { uint z=1; } options; struct { uint x=0; } emitters; } frame;
uint environment=0;
uint gi_environment_count() { return environment; }
const float PI=3.14159265f;
vec3 targets[8];
vec3 gi_light_target_normal(RayHit,vec3,uint light,vec2,float,vec3&,float&) { return targets[light]; }
CERTIFICATE
int main() {
    // Execute the actual certification guard with controlled light values.
    RayHit hit;
    for (uint count=0; count<=8; ++count) {
        params.light_count=count;
        assert(gi_confirm_unlit_analytic_hit(hit));
        for (uint i=0;i<count;++i) {
            targets[i]=vec3(0.001f);
            assert(!gi_confirm_unlit_analytic_hit(hit));
            targets[i]=vec3(NAN);
            assert(!gi_confirm_unlit_analytic_hit(hit));
            targets[i]=vec3(0);
        }
    }
    params.light_count=9;
    assert(!gi_confirm_unlit_analytic_hit(hit));
    params.light_count=0;
    environment=1;
    assert(!gi_confirm_unlit_analytic_hit(hit));
    environment=0; frame.emitters.x=1;
    assert(!gi_confirm_unlit_analytic_hit(hit));
    frame.emitters.x=0; frame.options.z=0;
    assert(!gi_confirm_unlit_analytic_hit(hit));
    // Isolated fireflies and alternating estimates never confirm a change.
    uint state = 0;
    for (int i=0; i<100; ++i) {
        state = gi_response_update(state, 1.0f, i%4 == 0 ? 100.0f : 1.0f);
        assert(gi_response_confidence(state) == 0);
    }
    state = 0;
    for (int i=0; i<100; ++i) {
        state = gi_response_update(state, 1.0f, i%2 ? 3.0f : 0.0f);
        assert(gi_response_confidence(state) == 0);
    }
    // Both directions require three significant consecutive observations.
    for (bool brighten : {false, true}) {
        state=0;
        for (int i=0; i<3; ++i) {
            state=gi_response_update(state, brighten ? 0.0f : 2.0f, brighten ? 2.0f : 0.0f);
            assert((gi_response_confidence(state)>0) == (i==2));
        }
        for (int i=0; i<15; ++i) state=gi_response_update(state, 2, 2);
        assert(gi_response_confidence(state)==0);
    }
    // Dim real changes still need persistent evidence; sub-floor noise does not.
    state=0;
    for (int i=0; i<3; ++i) state=gi_response_update(state, 0.003f, 0.012f);
    assert(gi_response_confidence(state)==1);
    state=0;
    for (int i=0; i<30; ++i) state=gi_response_update(state, 0.0001f, 0.0008f);
    assert(gi_response_confidence(state)==0);
    // The response cap preserves both original endpoints and interpolates the
    // fresh observation's weight. It never creates negative history evidence.
    for (int i=0; i<=100; ++i) {
        float c=float(i)/100;
        float count=gi_response_history_limit(c);
        assert(count>=2.999f && count<=64.001f);
        assert(std::abs(1/(count+1)-mix(1.0f/65,1.0f/4,c*c))<1e-6f);
    }
    // The entry/exit of the transition has zero slope and no brightness jump.
    for (float threshold : {12.0f, 16.0f}) {
        assert(gi_cache_detail_blend(0,threshold)==0);
        assert(gi_cache_detail_blend(.75f*threshold,threshold)==0);
        assert(gi_cache_detail_blend(threshold,threshold)==1);
        float previous=0;
        for (int i=0; i<=1000; ++i) {
            float value=gi_cache_detail_blend(threshold*i/1000,threshold);
            assert(value>=previous && value<=1);
            previous=value;
        }
    }
    // A permanently demanding probe cannot starve other valid local probes.
    // This bounds the stable reprojection case, not arbitrary camera motion.
    for (uint span : {2u,4u}) {
        assert(gi_probe_priority(1,span,false,1)==gi_probe_priority(1,span,false,0));
        std::vector<uint> age(span*span);
        for (int frame=0; frame<1024; ++frame) {
            uint selected=0;
            float best=-1;
            for (uint i=0; i<age.size(); ++i) {
                ++age[i];
                float score=gi_probe_priority(age[i],span,false,i==0 ? 1.0f : 0.0f);
                if (score>best) {best=score; selected=i;}
            }
            age[selected]=0;
            for (uint value : age) assert(value<=2*span*span);
        }
    }
    // Every padded tile byte maps to its own bit range; neighboring owners'
    // masked atomic updates commute. No word crosses a tile allocation.
    for (uint cell=0;cell<85;++cell) {
        uint word=cell/4, shift=(cell&3)*8;
        assert(word<22 && shift<=24);
        for (uint other=0;other<85;++other) if(other!=cell && other/4==word) {
            assert(((255u<<shift)&(255u<<((other&3)*8)))==0);
        }
    }
    std::cout << "PASS: response, recovery, transitions, starvation, metadata packing\n";
}
"""
# GLSL's unqualified abs accepts floating point; use the same C++ overload.
policy = policy.replace("abs(", "std::abs(")
# GLSL literals adapt to float overloads; C++ template deduction does not.
policy = re.sub(r"(?<![\w.])(\d+\.\d+)(?![\w.])", r"\1f", policy)
with tempfile.TemporaryDirectory() as folder:
    path = Path(folder)
    (path / "check.cpp").write_text(test.replace("POLICY", policy).replace("CERTIFICATE", certificate))
    subprocess.run(["c++", "-std=c++17", str(path / "check.cpp"), "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)
