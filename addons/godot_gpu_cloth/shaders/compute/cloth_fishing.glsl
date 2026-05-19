#[compute]
#version 450

// Fishing-line constraint v3.0 — K-nearest weighted blending on predicted[].
//
// Each free particle is bound to its K nearest anchors (inv_mass==0 particles).
// Anchors include both cloth_weight=0 skin-anchored particles and Marker3D-pinned
// particles. Weights are inverse-square distance, normalized to sum to 1 across
// used slots. The constraint clamps the particle to within a weighted blend of
// per-binding max distances (stretch * rest_distance) of the weighted blend of
// anchor positions.
//
// Operates on predicted[] mid-substep, between SOLVE and COLLIDE. The fork's
// per-substep soft-lerp in cloth_update.glsl structurally eliminates the
// boundary-buzz the v2.x velocity-damp branch was working around — Hazard 5.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 1, std430) restrict buffer Predicted        { vec4 predicted[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer Bindings { vec4 bindings[]; };

// bindings[particle_idx * K + slot] = vec4(
//     uintBitsToFloat(anchor_idx),  // .x  (== particle_idx is the "unused slot" sentinel)
//     max_dist_for_this_binding,    // .y  (== rest_distance * stretch)
//     weight,                       // .z  (sums to 1.0 across used slots)
//     _pad                          // .w
// )

layout(push_constant, std430) uniform Params {
    uint particle_count;
    uint bindings_per_particle;
    float pad_a;
    float pad_b;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    vec4 p = predicted[idx];
    if (p.w == 0.0) return;  // anchor — nothing to clamp

    vec3 target = vec3(0.0);
    float max_dist = 0.0;
    float total_weight = 0.0;

    for (uint i = 0u; i < bindings_per_particle; i++) {
        vec4 binding = bindings[idx * bindings_per_particle + i];
        uint anchor_idx = floatBitsToUint(binding.x);
        if (anchor_idx == idx) continue;  // unused slot sentinel

        float bind_max_dist = binding.y;
        float weight = binding.z;

        target += predicted[anchor_idx].xyz * weight;
        max_dist += bind_max_dist * weight;
        total_weight += weight;
    }

    if (total_weight < 1e-6) return;  // no valid anchors

    vec3 delta = p.xyz - target;
    float d = length(delta);

    if (d > max_dist && d > 1e-6) {
        vec3 normal = delta / d;
        predicted[idx].xyz = target + normal * max_dist;
    }
}
