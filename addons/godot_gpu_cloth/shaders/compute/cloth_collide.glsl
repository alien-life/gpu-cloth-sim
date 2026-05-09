#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 1, std430) restrict buffer Predicted  { vec4 predicted[];  };
layout(set = 0, binding = 4, std430) restrict readonly buffer Colliders { vec4 colliders[]; };

layout(push_constant, std430) uniform Params {
    float dt;
    float gravity;
    uint  particle_count;
    uint  constraint_count;
    float damping;
    float max_speed;
    uint  collider_count;
    float pad2;
    float pad3, pad4, pad5, pad6;
    float pad7, pad8, pad9, pad10;
    float gravity_x, gravity_y, gravity_z, pad11;
    // Rotational inertia quaternion — only consumed by the predict shader; kept
    // here as padding so the shared push constant range matches across pipelines.
    float pad_qx, pad_qy, pad_qz, pad_qw;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    float w = predicted[idx].w;
    if (w < 0.001) return;

    vec3 pos = predicted[idx].xyz;

    for (uint c = 0; c < collider_count; c++) {
        float shape_type = colliders[c * 4 + 1].w;

        if (shape_type < 0.5) {
            // Capsule / Sphere
            vec3 a = colliders[c * 4].xyz;
            vec3 b = colliders[c * 4 + 1].xyz;
            float r = colliders[c * 4].w;

            vec3 ab = b - a;
            float ab2 = dot(ab, ab);
            float t = (ab2 > 1e-12) ? clamp(dot(pos - a, ab) / ab2, 0.0, 1.0) : 0.0;
            vec3 closest = a + ab * t;

            vec3 diff = pos - closest;
            float dist = length(diff);

            if (dist < r && dist > 1e-7) {
                pos = closest + (diff / dist) * r;
            }
        } else {
            // Box (OBB)
            vec3 center = colliders[c * 4].xyz;
            vec3 half_ext = colliders[c * 4 + 1].xyz;
            vec3 right = colliders[c * 4 + 2].xyz;
            vec3 up_dir = colliders[c * 4 + 3].xyz;
            vec3 fwd = cross(right, up_dir);

            vec3 d = pos - center;
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

    predicted[idx] = vec4(pos, w);
}
