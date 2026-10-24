"""Run extracted Capsaicin normal reconstruction expressions on equivalent meshes.

This is a CPU algebra check, not an execution of Capsaicin's GPU renderer.
The three reconstruction blocks are copied programmatically without editing.
Host vector/matrix primitives implement their HLSL mathematical operations.
"""

import os
import subprocess
from pathlib import Path

root = Path(os.environ.get("AMD_CAPSAICIN_ROOT", "/workspace/amd-capsaicin-reference"))
out = Path(os.environ.get("AMD_GI_PROOF_OUT", "/tmp/amd-gi-source-proofs")) / "normal-space"
out.mkdir(parents=True, exist_ok=True)
source = (root / "src/core/src/render_techniques/gi1/gi1.comp").read_text()

blocks = {}
for name in ("GenerateReservoirs", "GenerateMultibounceReservoirs", "PopulateCells"):
    start = source.index("void " + name + "(")
    start = source.index("    vertices.v0 = transformPoint", start)
    end_token = "float3 shadingNormal =" if name == "PopulateCells" else "visibility.barycentrics));"
    if name == "GenerateReservoirs":
        end_token = "visibility.barycentrics));"
    end = source.index(end_token, start)
    end = source.index(";", end) + 1
    blocks[name] = source[start:end]

header = r"""
#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <iomanip>
#include <iostream>
struct float3 { double x,y,z; };
struct float2 { double x,y; };
float3 operator+(float3 a,float3 b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
float3 operator-(float3 a,float3 b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
float3 operator*(float3 a,double s){return {a.x*s,a.y*s,a.z*s};}
float3 operator*(double s,float3 a){return a*s;}
double dot(float3 a,float3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
float3 cross(float3 a,float3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
float3 normalize(float3 a){return a*(1/std::sqrt(dot(a,a)));}
struct float3x4 { std::array<float3,3> row; float3 translation; };
float3 mul(const float3x4 &m,float3 v){return {dot(m.row[0],v),dot(m.row[1],v),dot(m.row[2],v)};}
float3 transformPoint(float3 v,const float3x4 &m){return mul(m,v)+m.translation;}
// math/transform.hlsl: getNormalTransform's row cofactors and determinant sign.
float3 transformNormal(float3 v,const float3x4 &m){
    float3x4 n{{cross(m.row[1],m.row[2]),cross(m.row[2],m.row[0]),cross(m.row[0],m.row[1])},{0,0,0}};
    double det=dot(m.row[0],n.row[0]);
    return mul(n,v)*(det>0?1:det<0?-1:0);
}
float3 interpolate(float3 a,float3 b,float3 c,float2 uv){return a*(1-uv.x-uv.y)+b*uv.x+c*uv.y;}
struct Triangle {float3 v0,v1,v2,n0,n1,n2;};
struct Visibility {float2 barycentrics; bool is_front_face;};
struct Result {float3 normal, shading;};
"""

functions = []
for name, block in blocks.items():
    tail = "normal, shadingNormal" if name == "PopulateCells" else "normal, normal"
    functions.append(
        f"Result {name}(Triangle vertices, float3x4 transform, Visibility visibility){{\n{block}\nreturn {{{tail}}};\n}}"
    )

main = r"""
int main(){
    const float3x4 identity{{float3{1,0,0},float3{0,1,0},float3{0,0,1}},{0,0,0}};
    Triangle local{{0,0,0},{0,1,0},{0,0,1},{1,0,0},{1,0,0},{1,0,0}};
    Visibility visibility{{.25,.25},true};
    const char* names[] = {"GenerateReservoirs", "GenerateMultibounceReservoirs", "PopulateCells"};
    using F=Result(*)(Triangle,float3x4,Visibility);
    F funcs[]={GenerateReservoirs,GenerateMultibounceReservoirs,PopulateCells};
    std::cout<<"rotation,nonuniform_scale,path,instance_NdotL,baked_NdotL,instance_shading_NdotL\n";
    for(int scale=0;scale<2;scale++) for(double degrees : {0.,30.,60.,90.}){
        double angle=degrees*std::acos(-1.)/180, c=std::cos(angle),s=std::sin(angle);
        double x=scale?2:1,y=scale?3:1,z=scale?4:1;
        float3x4 transform{{float3{c*x,-s*y,0},float3{s*x,c*y,0},float3{0,0,z}},{2,3,4}};
        Triangle baked=local;
        baked.v0=transformPoint(local.v0,transform);baked.v1=transformPoint(local.v1,transform);baked.v2=transformPoint(local.v2,transform);
        baked.n0=normalize(transformNormal(local.n0,transform));baked.n1=baked.n0;baked.n2=baked.n0;
        float3 light=normalize(cross(baked.v1-baked.v0,baked.v2-baked.v0));
        assert(dot(light,baked.n0)>1-1e-12);
        for(int path=0;path<3;path++){
            Result a=funcs[path](local,transform,visibility), b=funcs[path](baked,identity,visibility);
            double av=dot(a.normal,light),bv=dot(b.normal,light),sv=dot(a.shading,light);
            assert(std::abs(bv-1)<1e-12);
            if(path==0 || degrees==0) assert(std::abs(av-1)<1e-12);
            if(path!=0 && degrees==90) assert(std::abs(av)<1e-12);
            std::cout<<degrees<<','<<scale<<','<<names[path]<<','<<std::setprecision(12)<<av<<','<<bv<<','<<sv<<'\n';
        }
    }
}
"""

cpp = out / "extracted_normal_spaces.cpp"
cpp.write_text(header + "\n".join(functions) + main)
subprocess.run(["c++", "-std=c++17", "-O2", str(cpp), "-o", str(out / "check")], check=True)
result = subprocess.run([str(out / "check")], check=True, capture_output=True, text=True)
(out / "results.csv").write_text(result.stdout)
print(result.stdout, end="")
print("PASS: 24 path/input cases; same world triangle, baked vs instanced. CPU algebra only.")
