#[compute]
#version 450

// Pass 1 of normal computation: one thread per triangle.
// Reads simulated positions, writes an unnormalised face normal per triangle.
// Pass 2 (cloth_output.glsl) accumulates these per vertex via the adjacency list.
//
// In v3.0 with welding, `indices[]` holds welded particle indices, and
// `positions[]` is welded-indexed too — the normal is computed on the
// simulation mesh, not the render mesh.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly  buffer Positions   { vec4 positions[];    };
layout(set = 0, binding = 1, std430) restrict readonly  buffer Indices     { uint indices[];      };
layout(set = 0, binding = 2, std430) restrict writeonly buffer FaceNormals { vec4 face_normals[]; };

layout(push_constant, std430) uniform Params {
	uint  tri_count;
	float flip;      // +1.0 or -1.0 from flip_normals export
	float pad1; float pad2;
};

void main() {
	uint t = gl_GlobalInvocationID.x;
	if (t >= tri_count) return;

	uint i0 = indices[t * 3u + 0u];
	uint i1 = indices[t * 3u + 1u];
	uint i2 = indices[t * 3u + 2u];

	vec3 v0 = positions[i0].xyz;
	vec3 n  = cross(positions[i1].xyz - v0, positions[i2].xyz - v0) * flip;
	face_normals[t] = vec4(n, 0.0);
}
