#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Vertex rest positions in mesh-local space (xyz = position, w = 1.0 homogeneous)
layout(set = 0, binding = 0, std430) restrict readonly buffer RestPositions {
    vec4 rest_pos[];
};

// 4 bone indices per vertex packed as 2x uint32:
//   x: bits 0-15 = bone0, bits 16-31 = bone1
//   y: bits 0-15 = bone2, bits 16-31 = bone3
layout(set = 0, binding = 1, std430) restrict readonly buffer BoneIndices {
    uvec2 bone_idx[];
};

// 4 normalized blend weights per vertex (sum <= 1.0)
layout(set = 0, binding = 2, std430) restrict readonly buffer BoneWeightsSkin {
    vec4 bone_w[];
};

// Per-bone skinning matrices: 3 vec4s per bone (row-major 3x4)
//   slot [i*3+0] = row0: (m00, m01, m02, tx)
//   slot [i*3+1] = row1: (m10, m11, m12, ty)
//   slot [i*3+2] = row2: (m20, m21, m22, tz)
// Each bone matrix already encodes: bone_global_pose * bind_pose
// so the output is directly in cloth-solver local (skeleton-local) space.
layout(set = 0, binding = 3, std430) restrict readonly buffer BoneTransforms {
    vec4 bone_mats[];
};

// Output: skinned positions in cloth-solver local space (w unused, set to 1.0)
layout(set = 0, binding = 4, std430) restrict writeonly buffer SkinnedTargets {
    vec4 skinned[];
};

layout(push_constant, std430) uniform Params {
    uint particle_count;
    uint bone_count;      // number of skin bind slots (= skin.get_bind_count())
    uint pad0; uint pad1;
    uint pad2; uint pad3; uint pad4; uint pad5;
    uint pad6; uint pad7; uint pad8; uint pad9;
    uint pad10; uint pad11; uint pad12; uint pad13;
};

// Reconstruct a column-major mat4 from the row-major 3x4 stored in the buffer.
// The fourth row is implicitly (0, 0, 0, 1).
mat4 fetch_bone_matrix(uint bone_id) {
    uint o = bone_id * 3u;
    vec4 r0 = bone_mats[o + 0u]; // (m00, m01, m02, tx)
    vec4 r1 = bone_mats[o + 1u]; // (m10, m11, m12, ty)
    vec4 r2 = bone_mats[o + 2u]; // (m20, m21, m22, tz)
    return mat4(
        vec4(r0.x, r1.x, r2.x, 0.0),  // col 0
        vec4(r0.y, r1.y, r2.y, 0.0),  // col 1
        vec4(r0.z, r1.z, r2.z, 0.0),  // col 2
        vec4(r0.w, r1.w, r2.w, 1.0)   // col 3 (translation)
    );
}

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= particle_count) return;

    uvec2 packed = bone_idx[i];
    uint b0 = (packed.x >>  0u) & 0xFFFFu;
    uint b1 = (packed.x >> 16u) & 0xFFFFu;
    uint b2 = (packed.y >>  0u) & 0xFFFFu;
    uint b3 = (packed.y >> 16u) & 0xFFFFu;

    vec4 w    = bone_w[i];
    vec4 rp   = vec4(rest_pos[i].xyz, 1.0);
    vec3 pos  = vec3(0.0);

    // Linear Blend Skinning: weighted sum of bone transforms applied to rest position.
    // Guard against invalid bone indices (out-of-range = no contribution).
    if (w.x > 0.0001 && b0 < bone_count) pos += (fetch_bone_matrix(b0) * rp).xyz * w.x;
    if (w.y > 0.0001 && b1 < bone_count) pos += (fetch_bone_matrix(b1) * rp).xyz * w.y;
    if (w.z > 0.0001 && b2 < bone_count) pos += (fetch_bone_matrix(b2) * rp).xyz * w.z;
    if (w.w > 0.0001 && b3 < bone_count) pos += (fetch_bone_matrix(b3) * rp).xyz * w.w;

    skinned[i] = vec4(pos, 1.0);
}
