#[compute]
#version 450

// Skinned mesh collider — pushes each free cloth particle outside the body's
// decimated triangle proxy. The CPU side (gpu_cloth_solver.gd:_build_collider_mesh)
// extracts and decimates the body mesh at init, then per-frame skins each
// triangle's verts via single-bone bind_pose * bone_global_pose and uploads to
// the SkinnedTris buffer below. This shader runs alongside cloth_collide.glsl
// in the substep iter loop; both push the same `predicted[]` buffer.
//
// Pinned particles (w < 0.001) are skipped — they're snapped to skinned_targets
// directly in predict and can't be displaced by collision.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Substep-start positions for the friction tangent calculation. Read-only
// here; the actual position write target is predicted[] at binding 1.
layout(set = 0, binding = 0, std430) restrict readonly buffer Positions {
    vec4 positions[];
};
layout(set = 0, binding = 1, std430) restrict buffer Predicted {
    vec4 predicted[];
};
// Each triangle: 3 contiguous vec4s holding the skinned vert positions
// (w = unused). Total stride 48 bytes per triangle.
layout(set = 0, binding = 4, std430) restrict readonly buffer SkinnedTris {
    vec4 tri_verts[];
};
// Per-particle cloth_weight (x = 0..1). Reused as a thickness multiplier:
// pinned particles (cw=0) are skipped via the w<0.001 check below, so their
// thickness doesn't matter; blend-zone particles (0<cw<1) get proportionally
// less thickness ("lightly attached" cloth shouldn't push hard against the
// body); fully-free particles (cw=1) get the full base thickness.
layout(set = 0, binding = 5, std430) restrict readonly buffer ClothWeights {
    vec4 cloth_weights[];
};

layout(push_constant, std430) uniform Params {
    uint  particle_count;
    uint  tri_count;
    float thickness;     // base thickness; multiplied by cloth_weights[idx].x per-particle
    float friction;      // Coulomb μ; 0 = frictionless
};

// Standard closest-point-on-triangle (Ericson, Real-Time Collision Detection).
// Returns the point on triangle (a, b, c) nearest to p — handles all 7 Voronoi
// regions (3 vertices, 3 edges, 1 face).
vec3 closest_point_on_triangle(vec3 p, vec3 a, vec3 b, vec3 c) {
    vec3 ab = b - a;
    vec3 ac = c - a;
    vec3 ap = p - a;
    float d1 = dot(ab, ap);
    float d2 = dot(ac, ap);
    if (d1 <= 0.0 && d2 <= 0.0) return a;  // vertex region A

    vec3 bp = p - b;
    float d3 = dot(ab, bp);
    float d4 = dot(ac, bp);
    if (d3 >= 0.0 && d4 <= d3) return b;   // vertex region B

    float vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
        float v = d1 / (d1 - d3);
        return a + v * ab;                 // edge AB
    }

    vec3 cp = p - c;
    float d5 = dot(ab, cp);
    float d6 = dot(ac, cp);
    if (d6 >= 0.0 && d5 <= d6) return c;   // vertex region C

    float vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
        float w = d2 / (d2 - d6);
        return a + w * ac;                 // edge AC
    }

    float va = d3 * d6 - d5 * d4;
    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
        float w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return b + w * (c - b);            // edge BC
    }

    // Inside face — interpolate via barycentric weights.
    float denom = 1.0 / (va + vb + vc);
    float v = vb * denom;
    float w = vc * denom;
    return a + ab * v + ac * w;
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    float w = predicted[idx].w;
    if (w < 0.001) return;  // pinned

    vec3 pos = predicted[idx].xyz;
    float pthk = thickness * cloth_weights[idx].x;
    if (pthk < 1e-6) return;  // cw=0 case; nothing to push (already handled by w<0.001 guard above for true pin)

    vec3 substep_start = positions[idx].xyz;

    for (uint t = 0u; t < tri_count; t++) {
        vec3 a = tri_verts[t * 3u + 0u].xyz;
        vec3 b = tri_verts[t * 3u + 1u].xyz;
        vec3 c = tri_verts[t * 3u + 2u].xyz;

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

            // Bridson Coulomb friction — damp tangential motion since the
            // start of this substep, clamped by μ × push_magnitude. Kills
            // the velocity injection that propagates as jitter through
            // structural constraints to neighbor particles.
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
