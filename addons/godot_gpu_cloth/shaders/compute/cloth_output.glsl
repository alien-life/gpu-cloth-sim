#[compute]
#version 450

// Pass 2 of the output pipeline: one thread per particle.
// Accumulates face normals from the adjacency list, normalises, and writes
// both the final position and normal into storage images for the vertex shader.
//
// Both images are sized to the welded particle count. The render mesh's
// vertex shader uses a separate welded_index_tex lookup to map VERTEX_ID
// (un-welded) → welded_idx before sampling these images. (Phase 2.)

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Positions      { vec4 positions[];       };
layout(set = 0, binding = 1, std430) restrict readonly buffer FaceNormals    { vec4 face_normals[];    };
layout(set = 0, binding = 2, std430) restrict readonly buffer VertTriCounts  { uint vert_tri_counts[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VertTriOffsets { uint vert_tri_offsets[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VertTriList    { uint vert_tri_list[];   };

layout(set = 0, binding = 5, rgba32f) uniform writeonly image2D positions_img;
layout(set = 0, binding = 6, rgba32f) uniform writeonly image2D normals_img;

layout(push_constant, std430) uniform Params {
	uint particle_count;
	uint tex_width;
	float pad1; float pad2;
};

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= particle_count) return;

	ivec2 coord = ivec2(int(idx % tex_width), int(idx / tex_width));

	imageStore(positions_img, coord, positions[idx]);

	uint count  = vert_tri_counts[idx];
	uint offset = vert_tri_offsets[idx];
	vec3 normal = vec3(0.0);
	for (uint t = 0u; t < count; t++) {
		normal += face_normals[vert_tri_list[offset + t]].xyz;
	}
	float nl = dot(normal, normal);
	normal = (nl > 1e-8) ? normal * inversesqrt(nl) : vec3(0.0, 1.0, 0.0);
	imageStore(normals_img, coord, vec4(normal, 0.0));
}
