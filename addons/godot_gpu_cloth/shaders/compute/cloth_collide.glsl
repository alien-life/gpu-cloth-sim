#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Substep-start positions, read-only — used as the friction tangent reference
// (motion since substep start). predicted[] at binding 1 is the write target.
layout(set = 0, binding = 0, std430) restrict readonly buffer Positions     { vec4 positions[];      };
layout(set = 0, binding = 1, std430) restrict buffer Predicted              { vec4 predicted[];      };
layout(set = 0, binding = 4, std430) restrict readonly buffer Colliders     { vec4 colliders[];      };
layout(set = 0, binding = 5, std430) restrict readonly buffer SkinnedTargets { vec4 skinned_targets[]; };

layout(push_constant, std430) uniform Params {
    float dt;
    float gravity;
    uint  particle_count;
    uint  constraint_count;
    float damping;
    float max_speed;
    uint  collider_count;
    // Reuses the byte slot that the solve shader interprets as
    // constraint_offset_packed and the update shader leaves as padding. The
    // GDScript dispatcher rewrites these 4 bytes between solve and collide
    // (encode_float(28, collider_friction) just before collide dispatches).
    float friction;
    float pad3, pad4, pad5, pad6;
    float pad7, pad8, pad9, pad10;
    // Rotational counter-rotation quaternion — only consumed by predict.
    float pad_qx, pad_qy, pad_qz, pad_qw;
    // Gravity Y, Z, pads — only consumed by predict.
    float pad_gy, pad_gz, pad_g1, pad_g2;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    float w = predicted[idx].w;
    if (w < 0.001) return;

    vec3 pos           = predicted[idx].xyz;
    vec3 skin_pos      = skinned_targets[idx].xyz;
    vec3 substep_start = positions[idx].xyz;

    for (uint c = 0; c < collider_count; c++) {
        float shape_type = colliders[c * 4 + 1].w;
        // Snapshot pos at the start of this collider so the friction step can
        // recover the cumulative push direction (hemisphere step + surface
        // push combine into one effective normal per collider).
        vec3 pos_pre = pos;

        if (shape_type < 0.5) {
            // Capsule / Sphere
            vec3  a   = colliders[c * 4].xyz;
            vec3  b   = colliders[c * 4 + 1].xyz;
            float r   = colliders[c * 4].w;
            vec3  ab  = b - a;
            float ab2 = dot(ab, ab);

            float t_sk       = (ab2 > 1e-12) ? clamp(dot(skin_pos - a, ab) / ab2, 0.0, 1.0) : 0.0;
            vec3  closest_sk = a + ab * t_sk;
            vec3  skin_diff  = skin_pos - closest_sk;
            float skin_dist  = length(skin_diff);

            // Step 1 - hemisphere plane: ALWAYS run, regardless of whether pos
            // is inside or outside the collider.  The plane sits at r*0.5 from
            // the axis (halfway inside the surface) so it never crosses the
            // symmetry axis even when skin_pos clips slightly inside at a joint.
            // This establishes the correct side BEFORE the surface push, which
            // would otherwise blindly push toward the nearest surface.
            if (skin_dist > 1e-7) {
                vec3  skin_normal = skin_diff / skin_dist;
                float proj        = dot(pos - closest_sk, skin_normal);
                if (proj < r * 0.5) {
                    pos += skin_normal * (r * 0.5 - proj);
                }
            }

            // Step 2 - surface push: pos is now on the correct hemisphere.
            // Push it outside the collider surface if it is still inside.
            float t       = (ab2 > 1e-12) ? clamp(dot(pos - a, ab) / ab2, 0.0, 1.0) : 0.0;
            vec3  closest = a + ab * t;
            vec3  diff    = pos - closest;
            float dist    = length(diff);
            if (dist < r && dist > 1e-7) {
                pos = closest + (diff / dist) * r;
            }

        } else {
            // Box (OBB)
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

        // Bridson Coulomb friction — damp tangential motion since substep start
        // by μ × push_magnitude. push_dir is the cumulative normal for *this*
        // collider; no friction when this collider didn't actually move pos.
        // Same formulation as cloth_collide_triangles.glsl / cloth_collide_peer.glsl
        // so behavior stays consistent across primitive / triangle-mesh / peer paths.
        if (friction > 0.0) {
            vec3  push     = pos - pos_pre;
            float push_mag = length(push);
            if (push_mag > 1e-6) {
                vec3 push_dir = push / push_mag;
                vec3 motion  = pos - substep_start;
                vec3 tangent = motion - push_dir * dot(motion, push_dir);
                float tan_len = length(tangent);
                if (tan_len > 1e-6) {
                    float max_damp = push_mag * friction;
                    float k        = min(max_damp / tan_len, 1.0);
                    pos -= tangent * k;
                }
            }
        }
    }

    predicted[idx] = vec4(pos, w);
}
