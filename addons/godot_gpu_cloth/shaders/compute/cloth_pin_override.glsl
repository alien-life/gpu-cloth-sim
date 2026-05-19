#[compute]
#version 450

// Marker3D pin override pass: overwrites skinned_targets[] for particles that
// are anchored by an explicit Marker3D, NOT a bone. Runs after SKIN inside the
// per-frame compute list so PREDICT's "snap anchored particles to skinned_target"
// path naturally honors marker-pinned positions. Hazard 4 — markers and
// cloth_weights are orthogonal authoring tools; the skin pass alone can't
// produce marker positions because the marker isn't a bone.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer SkinnedTargets {
    vec4 skinned_targets[];
};
// One entry per pin:
//   .x = uintBitsToFloat(particle_idx)
//   .yzw = pin position in skeleton-local space
layout(set = 0, binding = 1, std430) restrict readonly buffer PinOverrides {
    vec4 pin_overrides[];
};

layout(push_constant, std430) uniform Params {
    uint pin_count;
    uint pad0;
    uint pad1;
    uint pad2;
};

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= pin_count) return;

    vec4 entry = pin_overrides[i];
    uint particle_idx = floatBitsToUint(entry.x);
    skinned_targets[particle_idx] = vec4(entry.yzw, 1.0);
}
