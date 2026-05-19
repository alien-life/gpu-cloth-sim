#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer    Positions      { vec4 positions[];      };
layout(set = 0, binding = 1, std430) restrict buffer    Predicted      { vec4 predicted[];      };
layout(set = 0, binding = 2, std430) restrict buffer    Velocities     { vec4 velocities[];     };
layout(set = 0, binding = 5, std430) restrict readonly buffer SkinnedTargets { vec4 skinned_targets[]; };

layout(push_constant, std430) uniform Params {
    float dt;
    float gravity_x;
    uint  particle_count;
    uint  constraint_count;
    float damping;
    float max_speed;
    float pad1, pad2;
    float inertia_x, inertia_y, inertia_z;
    float pad3;
    float wind_x, wind_y, wind_z;
    float pad4;
    // Per-substep COUNTER-rotation quaternion in skeleton-local space.
    // The skeleton rotation moves the local frame; applying its inverse to
    // free-particle positions makes them lag behind, producing rotational
    // inertia. Identity (0,0,0,1) = no rotation this frame → no displacement.
    float counter_qx, counter_qy, counter_qz, counter_qw;
    // Gravity Y, Z (X is in the first slot). World-space gravity is converted
    // to ref-local on the CPU each frame, so direction stays world-fixed even
    // when the solver / skeleton rotates.
    float gravity_y, gravity_z;
    float pad_g1, pad_g2;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    float w = positions[idx].w;

    // Anchored particle (inverse_mass == 0): track the skeleton-driven position
    // from the skin compute pass. Zero velocity so constraints don't pull it.
    if (w < 0.001) {
        vec3 target = skinned_targets[idx].xyz;
        positions[idx]  = vec4(target, 0.0);
        predicted[idx]  = vec4(target, 0.0);
        velocities[idx] = vec4(0.0);
        return;
    }

    vec3 pos = positions[idx].xyz;

    // Rotational inertia: rotate position by the per-substep counter-rotation
    // (Rodrigues formula). Identity quaternion → zero displacement.
    vec4 q = vec4(counter_qx, counter_qy, counter_qz, counter_qw);
    pos = pos + 2.0 * cross(q.xyz, cross(q.xyz, pos) + q.w * pos);

    // Translation inertia: compensate for parent node translation in
    // skeleton-local space so free particles feel inertia rather than
    // teleporting with the solver node.
    pos -= vec3(inertia_x, inertia_y, inertia_z);

    vec3 vel = velocities[idx].xyz;

    vel += vec3(gravity_x, gravity_y, gravity_z) * dt;
    vel += vec3(wind_x, wind_y, wind_z) * dt;

    float speed = length(vel);
    if (speed > max_speed) vel *= max_speed / speed;

    vec3 p = pos + vel * dt;

    predicted[idx]  = vec4(p, w);
    velocities[idx] = vec4(vel, 0.0);
}
