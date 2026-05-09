#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Positions  { vec4 positions[];  };
layout(set = 0, binding = 1, std430) restrict buffer Predicted   { vec4 predicted[];  };
layout(set = 0, binding = 2, std430) restrict buffer Velocities  { vec4 velocities[]; };

layout(push_constant, std430) uniform Params {
    float dt;
    float pad_gravity_legacy;  // was scalar gravity before world-space gravity vec3 was added
    uint  particle_count;
    uint  constraint_count;
    float damping;
    float max_speed;
    float pad1, pad2;
    float inertia_x, inertia_y, inertia_z;
    float pad3;
    float wind_x, wind_y, wind_z;
    float pad4;
    float gravity_x, gravity_y, gravity_z;
    float pad11;
    // Per-substep rotational-inertia quaternion in solver-local space. Identity
    // (0,0,0,1) = parent did not rotate this frame -> rotation displacement is zero.
    float inertia_qx, inertia_qy, inertia_qz, inertia_qw;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    float w = positions[idx].w;
    if (w < 0.001) {
        predicted[idx] = positions[idx];
        velocities[idx] = vec4(0.0);
        return;
    }
    vec3 pos = positions[idx].xyz;

    // Reference frame correction — compensate for parent movement so free particles have inertia.
    // Translation: inertia_xyz is the per-substep solver-local translation delta.
    // Rotation:    inertia_q is a per-substep quaternion in solver-local space; rotating this
    //              particle's position by it gives the position the cloth would reach if it
    //              rotated WITH the parent, so (pos - rotated) is the lag displacement we want
    //              to add. Identity quaternion -> zero displacement.
    vec3 inertia = vec3(inertia_x, inertia_y, inertia_z);
    vec4 q = vec4(inertia_qx, inertia_qy, inertia_qz, inertia_qw);
    vec3 rotated = pos + 2.0 * cross(q.xyz, cross(q.xyz, pos) + q.w * pos);
    inertia += pos - rotated;
    // Clamp combined translation+rotation inertia per substep to prevent cloth collapse during fast movement.
    float inertia_len = length(inertia);
    float max_inertia = max_speed * dt * 0.5;
    if (inertia_len > max_inertia) {
        inertia *= max_inertia / inertia_len;
    }
    pos -= inertia;

    vec3 vel = velocities[idx].xyz;

    // Semi-implicit Euler. Gravity is supplied in solver-LOCAL space by the CPU
    // (CPU computes local = basis_inv * world_gravity), so rotating the solver
    // node leaves world-space gravity direction unchanged. step() zeros gravity
    // for pinned particles (w == 0).
    vel += vec3(gravity_x, gravity_y, gravity_z) * dt * step(0.001, w);
    vel += vec3(wind_x, wind_y, wind_z) * dt * step(0.001, w);

    // Clamp velocity to prevent runaway
    float speed = length(vel);
    if (speed > max_speed) vel *= max_speed / speed;

    vec3 p = pos + vel * dt;

    predicted[idx] = vec4(p, w);
    velocities[idx] = vec4(vel, 0.0);
}
