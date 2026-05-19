#[compute]
#version 450

// Peer-cloth sanitizer: pushes every particle's skinned_target out of a peer
// cloth solver's CURRENT animated geometry. Companion to
// cloth_skin_collide_triangles.glsl (body sanitizer) — runs once per frame
// per peer, after the body sanitizer, before the substep loop.
//
// Without this: the shirt's skinned_targets sit ON the body surface (where
// the bone places them); the pants drape over the same body surface; so
// shirt skinned_targets overlap pants cloth volume. Every substep predict
// snaps pinned shirt verts to skinned_targets (inside pants) and update
// lerps blend-zone shirt verts toward skinned_targets (inside pants); peer
// collide pushes them back out, recovering velocity = push/sub_dt. That
// velocity propagates structurally → visible jitter. Sanitizing
// skinned_targets out of peer cloth breaks the cycle.
//
// Same SDF as cloth_collide_peer (closest-point-on-triangle, push along
// surface normal) but operates on skinned_targets[] instead of predicted[]
// and doesn't skip pinned particles — they especially need their snap-target
// outside the peer.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer SkinnedTargets {
    vec4 skinned_targets[];
};
layout(set = 0, binding = 2, std430) restrict readonly buffer PeerPositions {
    vec4 peer_pos[];
};
layout(set = 0, binding = 3, std430) restrict readonly buffer PeerIndices {
    uint peer_idx[];
};

layout(push_constant, std430) uniform Params {
    uint  particle_count;
    uint  peer_tri_count;
    float thickness;
    float pad0;
};

vec3 closest_point_on_triangle(vec3 p, vec3 a, vec3 b, vec3 c) {
    vec3 ab = b - a;
    vec3 ac = c - a;
    vec3 ap = p - a;
    float d1 = dot(ab, ap);
    float d2 = dot(ac, ap);
    if (d1 <= 0.0 && d2 <= 0.0) return a;

    vec3 bp = p - b;
    float d3 = dot(ab, bp);
    float d4 = dot(ac, bp);
    if (d3 >= 0.0 && d4 <= d3) return b;

    float vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
        float v = d1 / (d1 - d3);
        return a + v * ab;
    }

    vec3 cp = p - c;
    float d5 = dot(ab, cp);
    float d6 = dot(ac, cp);
    if (d6 >= 0.0 && d5 <= d6) return c;

    float vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
        float w = d2 / (d2 - d6);
        return a + w * ac;
    }

    float va = d3 * d6 - d5 * d4;
    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
        float w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return b + w * (c - b);
    }

    float denom = 1.0 / (va + vb + vc);
    float v = vb * denom;
    float w = vc * denom;
    return a + ab * v + ac * w;
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    vec3 pos = skinned_targets[idx].xyz;
    float w  = skinned_targets[idx].w;

    for (uint t = 0u; t < peer_tri_count; t++) {
        uint i0 = peer_idx[t * 3u + 0u];
        uint i1 = peer_idx[t * 3u + 1u];
        uint i2 = peer_idx[t * 3u + 2u];
        vec3 a = peer_pos[i0].xyz;
        vec3 b = peer_pos[i1].xyz;
        vec3 c = peer_pos[i2].xyz;

        vec3 closest = closest_point_on_triangle(pos, a, b, c);
        vec3 diff = pos - closest;
        float dist = length(diff);
        if (dist < thickness) {
            if (dist > 1e-6) {
                pos = closest + (diff / dist) * thickness;
            } else {
                vec3 n = normalize(cross(b - a, c - a));
                pos = closest + n * thickness;
            }
        }
    }

    skinned_targets[idx] = vec4(pos, w);
}
