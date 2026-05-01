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
    float inertia_x, inertia_y, inertia_z;
    float pad3;
    float wind_x, wind_y, wind_z;
    float pad4;
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

    // Reference frame correction — compensate for parent movement so free particles have inertia
    // Clamp inertia to prevent cloth collapse during fast movement
    vec3 inertia = vec3(inertia_x, inertia_y, inertia_z);
    float inertia_len = length(inertia);
    float max_inertia = max_speed * dt * 0.5;
    if (inertia_len > max_inertia) {
        inertia *= max_inertia / inertia_len;
    }
    pos -= inertia;

    vec3 vel = velocities[idx].xyz;

    // Semi-implicit Euler — step() zeros gravity for pinned particles (w == 0)
    vel += vec3(0.0, gravity, 0.0) * dt * step(0.001, w);
    vel += vec3(wind_x, wind_y, wind_z) * dt * step(0.001, w);

    // Clamp velocity to prevent runaway
    float speed = length(vel);
    if (speed > max_speed) vel *= max_speed / speed;

    vec3 p = pos + vel * dt;

    predicted[idx] = vec4(p, w);
    velocities[idx] = vec4(vel, 0.0);
}
