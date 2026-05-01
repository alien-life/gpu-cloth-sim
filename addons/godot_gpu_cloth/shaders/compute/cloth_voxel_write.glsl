#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Positions { vec4 positions[]; };
layout(set = 0, binding = 1, std430) restrict buffer Voxels { uint voxels[]; };

layout(push_constant, std430) uniform Params {
    vec3 aabb_min;
    float cell_size;
    uvec3 grid_dim;
    uint particle_count;
    int pad_a;
    float pad_b;
    int pad_c;
    int pad_d;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    vec3 pos = positions[idx].xyz;
    vec3 cell_f = (pos - aabb_min) / cell_size;
    ivec3 cell = ivec3(floor(cell_f));

    if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(grid_dim))))
        return;

    uint flat_idx = uint(cell.x)
        + uint(cell.y) * grid_dim.x
        + uint(cell.z) * grid_dim.x * grid_dim.y;
    uint word_idx = flat_idx / 32u;
    uint bit_mask = 1u << (flat_idx % 32u);
    atomicOr(voxels[word_idx], bit_mask);
}
