#[compute]
#version 450

// "Fishing-line" anchor constraint -- borrowed from Ghost of Tsushima's cloth pipeline.
//
// Tension propagates one constraint-link per solve iteration. For a tall cape with
// `solver_iterations x substeps` budget, the bottom row still trails behind the top
// pin by several frames before it stops falling, producing a rubbery look.
//
// Fix: precompute the nearest pin per particle and the rest-distance to it. Each
// substep, after the spring solve, hard-clamp every free particle to within
// `stretch_factor x rest_distance` of its anchor's CURRENT position. Tension
// propagates from any pin to any particle in O(1) instead of O(grid_radius).

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Predicted { vec4 predicted[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Anchors { vec2 anchors[]; };
// anchors[i].x = uintBitsToFloat(anchor_particle_idx)
// anchors[i].y = rest distance from particle i to its anchor

layout(push_constant, std430) uniform Params {
    uint particle_count;
    float stretch_factor;
    float pad_a;
    float pad_b;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    vec4 p = predicted[idx];
    if (p.w == 0.0) return;  // pinned particle -- already at its target, never clamp

    vec2 anchor_data = anchors[idx];
    uint anchor_idx = floatBitsToUint(anchor_data.x);
    if (anchor_idx == idx) return;  // self-anchor sentinel: no real pin assigned

    float max_dist = anchor_data.y * stretch_factor;
    vec3 anchor_pos = predicted[anchor_idx].xyz;
    vec3 delta = p.xyz - anchor_pos;
    float d = length(delta);

    if (d > max_dist && d > 1e-6) {
        predicted[idx].xyz = anchor_pos + (delta / d) * max_dist;
    }
}
