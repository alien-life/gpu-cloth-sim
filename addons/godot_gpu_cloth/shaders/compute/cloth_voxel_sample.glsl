#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Positions { vec4 positions[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Voxels { uint voxels[]; };
layout(set = 0, binding = 2, std430) restrict buffer AO { float ao_values[]; };

layout(push_constant, std430) uniform Params {
    vec3 aabb_min;
    float cell_size;
    uvec3 grid_dim;
    uint particle_count;
    int sample_radius;
    float strength;
    int pad0;
    int pad1;
};

bool is_occupied(ivec3 cell) {
    if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(grid_dim))))
        return false;
    uint flat_idx = uint(cell.x)
        + uint(cell.y) * grid_dim.x
        + uint(cell.z) * grid_dim.x * grid_dim.y;
    uint word_idx = flat_idx / 32u;
    uint bit_mask = 1u << (flat_idx % 32u);
    return (voxels[word_idx] & bit_mask) != 0u;
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    vec3 pos = positions[idx].xyz;
    ivec3 own_cell = ivec3(floor((pos - aabb_min) / cell_size));

    int occluded = 0;
    int total = 0;

    for (int dz = -sample_radius; dz <= sample_radius; dz++) {
        for (int dy = -sample_radius; dy <= sample_radius; dy++) {
            for (int dx = -sample_radius; dx <= sample_radius; dx++) {
                if (dx == 0 && dy == 0 && dz == 0) continue;
                ivec3 sample_cell = own_cell + ivec3(dx, dy, dz);
                total++;
                if (is_occupied(sample_cell)) occluded++;
            }
        }
    }

    float raw = total > 0 ? float(occluded) / float(total) : 0.0;
    ao_values[idx] = clamp(raw * strength, 0.0, 1.0);
}
