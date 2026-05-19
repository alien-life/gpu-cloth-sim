#[compute]
#version 450

// Sanitizer pass: push each particle's skinned_target out of any collider it's
// inside. Dispatched once per frame after SKIN + PIN_OVERRIDE writes the
// per-particle bone-driven (or marker-driven) anchor position.
//
// Why this exists: every cloth-anchoring mechanism downstream reads
// skinned_targets — PREDICT snaps pinned particles to it (cw=0), UPDATE
// lerps blend-zone particles toward it (0<cw<1), max_travel uses it as
// the anchor center for the leash clamp. If skinned_targets sits inside
// a collider volume (typical: a capsule sized to enclose a body bone
// always engulfs the underlying skinned mesh surface), the cloth gets
// pulled INTO the collider each substep, then PBD's COLLIDE pass shoves
// it back out, then UPDATE pulls it back in next substep. Visible as
// rest-jitter and rest-clipping that no amount of solver_iterations
// fixes. Projecting skinned_targets outward up-front breaks the cycle.
//
// SDF logic mirrors cloth_collide.glsl (capsule/sphere/box) minus the
// hemisphere disambiguation — skinned_targets are inherently on the
// "natural" side of the body (they're the bone-driven mesh surface)
// so we only need the surface push, not the inside/outside detection.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer SkinnedTargets {
    vec4 skinned_targets[];
};
layout(set = 0, binding = 1, std430) restrict readonly buffer Colliders {
    vec4 colliders[];
};

layout(push_constant, std430) uniform Params {
    uint particle_count;
    uint collider_count;
    uint pad0;
    uint pad1;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    vec3 pos = skinned_targets[idx].xyz;
    float w  = skinned_targets[idx].w;

    for (uint c = 0; c < collider_count; c++) {
        float shape_type = colliders[c * 4 + 1].w;

        if (shape_type < 0.5) {
            // Capsule / Sphere — push to surface along the radial direction.
            vec3  a   = colliders[c * 4].xyz;
            vec3  b   = colliders[c * 4 + 1].xyz;
            float r   = colliders[c * 4].w;
            vec3  ab  = b - a;
            float ab2 = dot(ab, ab);
            float t   = (ab2 > 1e-12) ? clamp(dot(pos - a, ab) / ab2, 0.0, 1.0) : 0.0;
            vec3  closest = a + ab * t;
            vec3  diff    = pos - closest;
            float dist    = length(diff);
            if (dist < r && dist > 1e-7) {
                pos = closest + (diff / dist) * r;
            }
        } else {
            // Box (OBB) — push to the nearest face.
            vec3 center   = colliders[c * 4].xyz;
            vec3 half_ext = colliders[c * 4 + 1].xyz;
            vec3 right    = colliders[c * 4 + 2].xyz;
            vec3 up_dir   = colliders[c * 4 + 3].xyz;
            vec3 fwd      = cross(right, up_dir);

            vec3 d         = pos - center;
            vec3 local_pos = vec3(dot(d, right), dot(d, up_dir), dot(d, fwd));

            if (all(lessThan(abs(local_pos), half_ext))) {
                vec3 dist_to_face = half_ext - abs(local_pos);
                if (dist_to_face.x <= dist_to_face.y && dist_to_face.x <= dist_to_face.z)
                    local_pos.x = sign(local_pos.x) * half_ext.x;
                else if (dist_to_face.y <= dist_to_face.z)
                    local_pos.y = sign(local_pos.y) * half_ext.y;
                else
                    local_pos.z = sign(local_pos.z) * half_ext.z;
                pos = center + right * local_pos.x + up_dir * local_pos.y + fwd * local_pos.z;
            }
        }
    }

    skinned_targets[idx] = vec4(pos, w);
}
