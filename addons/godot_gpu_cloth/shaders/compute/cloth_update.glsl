#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer    Positions      { vec4 positions[];      };
layout(set = 0, binding = 1, std430) restrict buffer    Predicted      { vec4 predicted[];      };
layout(set = 0, binding = 2, std430) restrict buffer    Velocities     { vec4 velocities[];     };
// x = cloth influence weight [0..1]: 0 = fully skeleton-driven, 1 = fully simulated
layout(set = 0, binding = 5, std430) restrict readonly buffer ClothWeights   { vec4 cloth_weights[];   };
layout(set = 0, binding = 6, std430) restrict readonly buffer SkinnedTargets { vec4 skinned_targets[]; };

layout(push_constant, std430) uniform Params {
    float dt;
    float gravity;
    uint  particle_count;
    uint  constraint_count;
    float damping;
    float max_speed;
    float pad1, pad2;
    float pad3, pad4, pad5, max_travel;
    float pad7, pad8, pad9;
    float inv_substeps;
    // Rotational counter-rotation quaternion — only consumed by predict.
    float pad_qx, pad_qy, pad_qz, pad_qw;
    // Gravity Y, Z, pads — only consumed by predict.
    float pad_gy, pad_gz, pad_g1, pad_g2;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    vec3  old_pos = positions[idx].xyz;
    vec3  new_pos = predicted[idx].xyz;
    float w       = positions[idx].w;
    float cloth_w = cloth_weights[idx].x;

    // Anchored particles (w == 0) are already snapped to skinned_targets in the
    // predict pass, so skip velocity recovery for them.
    if (w < 0.001) {
        return;
    }

    // Max travel: hard limit on how far each particle can stray from its
    // animated skin position. Fully simulated particles get the full budget;
    // blend-zone particles get a proportionally tighter limit.
    if (max_travel > 0.0) {
        vec3  diff = new_pos - skinned_targets[idx].xyz;
        float dist = length(diff);
        float lim  = cloth_w * max_travel;
        if (lim > 1e-7 && dist > lim) {
            new_pos = skinned_targets[idx].xyz + (diff / dist) * lim;
        }
    }

    // Recover velocity from position delta.
    vec3 vel = (new_pos - old_pos) / max(dt, 1e-7);
    vel *= damping;

    // Blend-zone: lerp simulated position toward skeleton-driven position.
    // cloth_weight == 1.0  -> fully simulated (no lerp)
    // cloth_weight in (0,1) -> partial skeleton influence
    // The pow(cloth_w, inv_substeps) makes the per-substep lerp converge to
    // a per-frame lerp of cloth_w regardless of substep count.
    if (cloth_w < 0.999) {
        float sub_w = pow(cloth_w, inv_substeps);
        new_pos = mix(skinned_targets[idx].xyz, new_pos, sub_w);
        vel *= sub_w;
    }

    positions[idx]  = vec4(new_pos, w);
    velocities[idx] = vec4(vel, 0.0);
}
