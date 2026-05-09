#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Positions  { vec4 positions[];  };
layout(set = 0, binding = 1, std430) restrict buffer Predicted   { vec4 predicted[];  };
layout(set = 0, binding = 2, std430) restrict buffer Velocities  { vec4 velocities[]; };

layout(push_constant, std430) uniform Params {
    float dt;
    float gravity;
    uint  particle_count;
    uint  constraint_count;
    float damping;
    float max_speed;
    float pad1, pad2;
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

    vec3 old_pos = positions[idx].xyz;
    vec3 new_pos = predicted[idx].xyz;
    float w = positions[idx].w;

    vec3 vel = (new_pos - old_pos) / max(dt, 1e-7);
    vel *= damping;

    positions[idx] = vec4(new_pos, w);
    velocities[idx] = vec4(vel, 0.0);
}
