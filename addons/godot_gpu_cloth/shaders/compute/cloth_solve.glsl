#[compute]
#version 450

// XPBD distance constraint solve (Macklin 2016). Per-constraint Lagrange
// multipliers λ accumulate across solver_iterations within a substep, then
// reset on iter 0 of the next substep via the high bit of constraint_offset.
//
// Compliance α replaces PBD's 0–1 stiffness:
//   α̃ = α / dt²      (time-scaled compliance)
//   Δλ = (-C - α̃·λ) / (Σ wᵢ |∇ᵢC|² + α̃)
//   λ ← λ + Δλ
//   Δpᵢ = wᵢ · ∇ᵢC · Δλ
//
// For a distance constraint C = |pb - pa| - rest, |∇C|² = 1 per endpoint, so
// the denominator collapses to (w_a + w_b + α̃). α = 0 ⇒ ideal-rigid PBD-
// equivalent correction with no λ drift.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 1, std430) restrict buffer Predicted          { vec4 predicted[];   };
layout(set = 0, binding = 3, std430) restrict readonly buffer Constraints { vec4 constraints[]; };
// Per-constraint λ. Written every iter; effectively cleared on iter 0 by the
// reset bit in constraint_offset_packed (avoids a separate clear pass).
layout(set = 0, binding = 8, std430) restrict buffer Lambdas            { float lambdas[];    };

layout(push_constant, std430) uniform Params {
    float dt;
    float gravity;
    uint  particle_count;
    uint  constraint_count;
    float damping;
    float max_speed;
    uint  collider_count;
    // High bit (0x80000000u) flags "iter == 0 — ignore stored λ, start fresh".
    // Low 31 bits hold the offset into the constraints array for this group.
    uint  constraint_offset_packed;
    float pad3, pad4, pad5, pad6;
    float pad7, pad8, pad9, pad10;
    // Rotational counter-rotation quaternion — only consumed by predict.
    float pad_qx, pad_qy, pad_qz, pad_qw;
    // Gravity Y, Z, pads — only consumed by predict.
    float pad_gy, pad_gz, pad_g1, pad_g2;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= constraint_count) return;

    uint reset_lambda = constraint_offset_packed >> 31u;
    uint cidx         = (constraint_offset_packed & 0x7FFFFFFFu) + idx;

    uint  a          = uint(constraints[cidx].x);
    uint  b          = uint(constraints[cidx].y);
    float rest       = constraints[cidx].z;
    float compliance = constraints[cidx].w;

    vec3  pa = predicted[a].xyz;
    vec3  pb = predicted[b].xyz;
    float wa = predicted[a].w;
    float wb = predicted[b].w;

    vec3  delta = pb - pa;
    float dist  = length(delta);
    if (dist < 1e-7) return;

    float w_sum = wa + wb;
    if (w_sum < 1e-7) return;

    float C           = dist - rest;
    float alpha_tilde = compliance / (dt * dt);
    float lam         = (reset_lambda == 0u) ? lambdas[cidx] : 0.0;
    float dlambda     = (-C - alpha_tilde * lam) / (w_sum + alpha_tilde);
    lambdas[cidx]     = lam + dlambda;

    vec3 n    = delta / dist;
    vec3 corr = n * dlambda;
    predicted[a] = vec4(pa - corr * wa, wa);
    predicted[b] = vec4(pb + corr * wb, wb);
}
