#[compute]
#version 450

// Triangle-collider sanitizer: pushes every particle's skinned_target out of
// the body's decimated triangle proxy. Companion to cloth_skin_collide.glsl
// (which handles capsule/box colliders); both run once per frame after the
// skin pass + pin_override, before the substep loop.
//
// Same rationale as the capsule sanitizer: skinned_targets is the position
// each cloth particle is pulled toward (PREDICT snaps pinned particles to it,
// UPDATE soft-lerps blend-zone particles toward it). If skinned_targets sits
// inside the body's triangle volume — which it does by default, because the
// bone-skinned position of a cloth vert that was modeled draped on the body
// IS the body surface — every per-frame collide push gets undone by the next
// pull-toward-target, producing visible rest-jitter. Projecting
// skinned_targets out by the same thickness used in cloth_collide_triangles
// breaks the cycle.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer SkinnedTargets {
    vec4 skinned_targets[];
};
// Same buffer layout as cloth_collide_triangles: 3 contiguous vec4 per triangle.
layout(set = 0, binding = 1, std430) restrict readonly buffer SkinnedTris {
    vec4 tri_verts[];
};

layout(push_constant, std430) uniform Params {
    uint  particle_count;
    uint  tri_count;
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

    // No pinned-skip: pinned particles especially need their anchor positions
    // sanitized — they get snapped to skinned_targets directly in predict.
    for (uint t = 0u; t < tri_count; t++) {
        vec3 a = tri_verts[t * 3u + 0u].xyz;
        vec3 b = tri_verts[t * 3u + 1u].xyz;
        vec3 c = tri_verts[t * 3u + 2u].xyz;

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
