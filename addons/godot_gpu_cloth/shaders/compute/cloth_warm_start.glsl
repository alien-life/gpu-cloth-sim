#[compute]
#version 450

// One-shot first-frame sync: copy the skin pass output into positions/predicted
// and zero velocities so the cloth renders correctly from frame 1 with the
// skeleton's authored pose, not the rest-mesh pose.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer    Positions     { vec4 positions[];     };
layout(set = 0, binding = 1, std430) restrict buffer    Predicted     { vec4 predicted[];     };
layout(set = 0, binding = 2, std430) restrict buffer    Velocities    { vec4 velocities[];    };
layout(set = 0, binding = 4, std430) restrict readonly buffer SkinnedTargets { vec4 skinned_targets[]; };

layout(push_constant, std430) uniform Params {
	uint  particle_count;
	float pad1; float pad2; float pad3;
};

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= particle_count) return;

	float w        = positions[idx].w;   // preserve inv_mass
	vec3  sk       = skinned_targets[idx].xyz;
	positions[idx]  = vec4(sk, w);
	predicted[idx]  = vec4(sk, w);
	velocities[idx] = vec4(0.0);
}
