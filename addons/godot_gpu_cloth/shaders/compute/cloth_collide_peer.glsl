#[compute]
#version 450

// Cloth-cloth collision: pushes our particles out of a peer cloth solver's
// current animated geometry. The peer's positions buffer and welded-index
// buffer are bound directly via their RIDs (shared RenderingDevice, no copy
// or readback). One dispatch per peer per iter — coordinator in
// gpu_cloth_solver.gd:_gpu_do_simulate iterates _peer_collide_uniform_sets.
//
// Both solvers must use the same reference frame (typically: same Skeleton3D).
// Validated at init in _build_peers; mismatched ref frames skip the peer.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// OUR substep-start positions for the friction tangent calculation.
layout(set = 0, binding = 0, std430) restrict readonly buffer Positions {
    vec4 positions[];
};
layout(set = 0, binding = 1, std430) restrict buffer Predicted {
    vec4 predicted[];        // OUR cloth's predicted positions (RW)
};
layout(set = 0, binding = 2, std430) restrict readonly buffer PeerPositions {
    vec4 peer_pos[];         // peer cloth's current positions (RO)
};
layout(set = 0, binding = 3, std430) restrict readonly buffer PeerIndices {
    uint peer_idx[];         // peer's welded-space triangle indices (3 per tri)
};
// Per-particle thickness multiplier (cw=0..1). Reuses the cloth_weights buffer
// already used by update/collide; pinned particles are skipped via the w-check,
// so this naturally degrades to "thick where free, thin where anchored".
layout(set = 0, binding = 5, std430) restrict readonly buffer ClothWeights {
    vec4 cloth_weights[];
};

layout(push_constant, std430) uniform Params {
    uint  particle_count;    // ours
    uint  peer_tri_count;
    float thickness;         // base; multiplied by cloth_weights[idx].x per particle
    float friction;          // Coulomb μ at cloth-cloth contact
    uint  is_self;           // 1 when "peer" is THIS solver — skip tris containing idx as a vert
    uint  pad0; uint pad1; uint pad2;
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
    float w = predicted[idx].w;
    if (w < 0.001) return;  // pinned, can't be pushed

    vec3 pos = predicted[idx].xyz;
    float pthk = thickness * cloth_weights[idx].x;
    if (pthk < 1e-6) return;

    vec3 substep_start = positions[idx].xyz;

    for (uint t = 0u; t < peer_tri_count; t++) {
        uint i0 = peer_idx[t * 3u + 0u];
        uint i1 = peer_idx[t * 3u + 1u];
        uint i2 = peer_idx[t * 3u + 2u];
        // Self-collision: skip any triangle that includes me as one of its
        // verts. Distance to such a triangle is 0 by construction and would
        // produce an infinite-direction push. Topologically-adjacent particles
        // (sharing an edge with this tri but not BEING a vert of it) still
        // contribute SDF distance, kept in check by structural constraints +
        // the small self_collide_thickness. is_self == 0 for real peers: their
        // index space is independent from ours so a coincidental idx==i0 match
        // does NOT mean "same particle" and must not skip.
        if (is_self == 1u && (idx == i0 || idx == i1 || idx == i2)) continue;
        vec3 a = peer_pos[i0].xyz;
        vec3 b = peer_pos[i1].xyz;
        vec3 c = peer_pos[i2].xyz;

        vec3 closest = closest_point_on_triangle(pos, a, b, c);
        vec3 diff = pos - closest;
        float dist = length(diff);
        if (dist < pthk) {
            vec3 push_dir;
            if (dist > 1e-6) {
                push_dir = diff / dist;
            } else {
                push_dir = normalize(cross(b - a, c - a));
            }
            float push_mag = pthk - dist;
            pos = closest + push_dir * pthk;

            // Coulomb friction at cloth-cloth contact. Critical for the
            // shirt-on-pants case where peer collide pushes inject velocity
            // that propagates as jitter through structural constraints.
            if (friction > 0.0) {
                vec3 motion = pos - substep_start;
                vec3 tangent = motion - push_dir * dot(motion, push_dir);
                float tan_len = length(tangent);
                if (tan_len > 1e-6) {
                    float max_damp = push_mag * friction;
                    float k = min(max_damp / tan_len, 1.0);
                    pos -= tangent * k;
                }
            }
        }
    }

    predicted[idx] = vec4(pos, w);
}
