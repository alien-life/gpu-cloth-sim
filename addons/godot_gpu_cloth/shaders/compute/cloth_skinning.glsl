#[compute]
#version 450

// Cloth skinning v2.1 -- per-particle bone-driven attachment with mask-controlled stiffness.
//
// Each particle has K=4 bone bindings. Per substep:
//     target = sum_i(bones[bone_idx[i]] * vec4(rest_offset[i], 1)) * weight[i]
// If the particle's predicted position is farther than effective_max_dist from
// target, project it onto the attachment-sphere boundary and zero outward radial
// velocity (the velocity-aware projection trick from cloth_fishing.glsl).
//
// For mask=0 particles (inverse_mass=0, effective_max_dist=0): predicted is
// overwritten unconditionally so the rigid attachment holds even though the
// predict pass skipped them. For all-zero-weight particles (e.g. those owned
// by an explicit Marker3D pin in _pin_map): early-out, fishing-line owns them.
//
// Bone slot 0 is reserved as the identity matrix on the CPU side -- the
// no-skeleton fallback path emits a single binding with bone_idx=0, weight=1,
// rest_offset=init_local_pos, so the same shader handles both regimes.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct SkinBinding {
    uint  bone_idx[4];      //  0..15
    float weight[4];        // 16..31
    vec4  rest_offset[4];   // 32..95   (.xyz used, .w padding)
    float effective_max_dist; // 96..99
    float pad0;             // 100..103
    float pad1;             // 104..107
    float pad2;             // 108..111
};

layout(set = 0, binding = 0, std430) restrict buffer Predicted    { vec4 predicted[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Bindings { SkinBinding bindings[]; };
layout(set = 0, binding = 2, std430) restrict buffer Velocities   { vec4 velocities[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer Bones { mat4 bones[]; };

layout(push_constant, std430) uniform Params {
    uint particle_count;
    uint velocity_damp;  // nonzero = zero outward radial velocity at boundary
    uint pad_a;
    uint pad_b;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= particle_count) return;

    SkinBinding b = bindings[idx];

    // Compute weighted-blend skinned target. Slots with zero weight skipped.
    vec3 target = vec3(0.0);
    float total_weight = 0.0;
    for (int i = 0; i < 4; i++) {
        float w = b.weight[i];
        if (w <= 0.0) continue;
        uint bi = b.bone_idx[i];
        vec3 contrib = (bones[bi] * vec4(b.rest_offset[i].xyz, 1.0)).xyz;
        target += contrib * w;
        total_weight += w;
    }
    if (total_weight < 1e-6) return;  // particle has no skin bindings (Marker3D-pinned)

    vec4 p = predicted[idx];
    float max_dist = b.effective_max_dist;

    // Rigid attachment: mask=0 particles get inverse_mass=0 from the CPU side, so
    // predict pass skipped them. Overwrite predicted with target unconditionally
    // -- otherwise they'd hold a stale position from before the bone moved.
    if (max_dist <= 0.0) {
        predicted[idx] = vec4(target, p.w);
        return;
    }

    vec3 delta = p.xyz - target;
    float d = length(delta);
    if (d > max_dist && d > 1e-6) {
        vec3 normal = delta / d;
        predicted[idx].xyz = target + normal * max_dist;
        if (velocity_damp != 0u) {
            vec3 vel = velocities[idx].xyz;
            float v_radial = dot(vel, normal);
            if (v_radial > 0.0) {
                velocities[idx].xyz = vel - normal * v_radial;
            }
        }
    }
}
