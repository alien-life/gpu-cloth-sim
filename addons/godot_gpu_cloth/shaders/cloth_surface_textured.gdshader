shader_type spatial;
render_mode cull_disabled;

// Minimal "passthrough" shader for the v3.0 substrate. Compute writes the
// simulated positions and normals into two storage textures sized to the
// WELDED particle count. The render mesh's vertex_id indexes its un-welded
// vertex slots, so we go through a welded_index_tex lookup first, then
// texelFetch the welded particle's pos/normal. Hazard 1 — welding implies
// render-vert count ≠ particle count, so the adjacency AND the vertex shader
// lookup both have to be welded-aware.

uniform bool      gpu_driven           = false;
uniform sampler2D positions_tex       : filter_nearest;
uniform sampler2D normals_tex         : filter_nearest;
uniform sampler2D welded_index_tex    : filter_nearest;
uniform int       tex_width           = 4096;
uniform int       render_tex_width    = 4096;
uniform mat4      skel_to_mesh_transform;
// Visual-only outward extrusion along the per-vertex normal, in mesh-local
// units. Hides body-poke-through when fast animation outruns the cloth solver.
// Does not affect physics.
uniform float     render_offset        = 0.0;

// PBR scalars
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;
uniform vec4  color_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float roughness  : hint_range(0.0, 1.0) = 0.9;
uniform float metallic   : hint_range(0.0, 1.0) = 0.0;
uniform float specular   : hint_range(0.0, 1.0) = 0.5;

// PBR maps (auto-ported from StandardMaterial3D when cloth_material is null).
// Each defaults to its no-op placeholder so the uniform is inert when unused:
//   metallic / roughness / ao → 1×1 white (multiplied into the scalar, so the
//                                scalar wins when no texture is assigned);
//   normal → flat tangent-space normal (no perturbation).
// Channel selects which of (R, G, B, A) of the sampled texture to use.
uniform sampler2D metallic_texture     : hint_default_white, filter_linear_mipmap;
uniform int       metallic_channel     : hint_range(0, 3) = 0;
uniform sampler2D roughness_texture    : hint_default_white, filter_linear_mipmap;
uniform int       roughness_channel    : hint_range(0, 3) = 0;
uniform sampler2D normal_texture       : hint_normal, filter_linear_mipmap;
uniform float     normal_scale         : hint_range(-2.0, 2.0) = 1.0;
uniform sampler2D ao_texture           : hint_default_white, filter_linear_mipmap;
uniform int       ao_channel           : hint_range(0, 3) = 0;
uniform float     ao_light_affect      : hint_range(0.0, 1.0) = 0.0;

void vertex() {
	if (gpu_driven) {
		ivec2 r_coord  = ivec2(int(VERTEX_ID) % render_tex_width,
		                       int(VERTEX_ID) / render_tex_width);
		int welded_idx = int(texelFetch(welded_index_tex, r_coord, 0).r);
		ivec2 p_coord  = ivec2(welded_idx % tex_width,
		                       welded_idx / tex_width);
		vec3 skel_pos = texelFetch(positions_tex, p_coord, 0).xyz;
		vec3 skel_nrm = texelFetch(normals_tex,   p_coord, 0).xyz;
		VERTEX = (skel_to_mesh_transform * vec4(skel_pos, 1.0)).xyz;
		NORMAL = normalize(mat3(skel_to_mesh_transform) * skel_nrm);
		// Outward shell expansion. Pure visual; physics is untouched.
		VERTEX += NORMAL * render_offset;
	}
}

void fragment() {
	// Albedo (texture × tint)
	vec4 tex         = texture(albedo_texture, UV);
	vec4 final_color = tex * color_tint;
	ALBEDO    = final_color.rgb;

	// PBR maps: sample, pick channel, multiply scalar.
	vec4 m_sample = texture(metallic_texture, UV);
	METALLIC  = metallic * m_sample[metallic_channel];

	vec4 r_sample = texture(roughness_texture, UV);
	ROUGHNESS = clamp(roughness * r_sample[roughness_channel], 0.0, 1.0);

	SPECULAR  = specular;

	// Normal map (flat normal by default, no perturbation when not assigned).
	NORMAL_MAP       = texture(normal_texture, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;

	// Ambient occlusion.
	vec4 ao_sample = texture(ao_texture, UV);
	AO               = ao_sample[ao_channel];
	AO_LIGHT_AFFECT  = ao_light_affect;

	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
		DEPTH  = FRAGCOORD.z + 0.0001;
	}
}
