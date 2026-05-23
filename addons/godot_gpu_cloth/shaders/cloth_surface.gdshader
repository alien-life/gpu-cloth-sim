shader_type spatial;
render_mode cull_disabled;

// -- v3 substrate (compute-driven positions/normals via Texture2DRD lookup) --
// The solver writes simulated skeleton-local positions/normals into two
// storage textures sized to the WELDED particle count. The render mesh's
// VERTEX_ID indexes its un-welded vertex slots, so we go through a small
// welded_index_tex (sized to render-vert count) before sampling the position
// texture. skel_to_mesh_transform converts the simulated skeleton-local
// position back into the mesh-local space the renderer's model_matrix expects.
group_uniforms substrate;
uniform bool      gpu_driven           = false;
uniform sampler2D positions_tex       : filter_nearest;
uniform sampler2D normals_tex         : filter_nearest;
uniform sampler2D welded_index_tex    : filter_nearest;
uniform int       tex_width           = 4096;
uniform int       render_tex_width    = 4096;
uniform mat4      skel_to_mesh_transform;
// Visual-only outward extrusion along the per-vertex normal, in mesh-local
// units. Hides body-poke-through when fast animation outruns the cloth solver.
// Does not affect physics — particles still simulate at their true positions.
uniform float     render_offset        = 0.0;

// -- Fabric --
group_uniforms fabric;
uniform int fabric_type : hint_range(0, 2) = 1; // 0=Lava, 1=Silk, 2=Linen
uniform float fabric_scale : hint_range(1.0, 100.0) = 30.0;
uniform float fabric_normal_intensity : hint_range(0.0, 2.0) = 0.5;

// -- Colors --
group_uniforms colors;
uniform vec4 primary_color : source_color = vec4(0.05, 0.02, 0.08, 1.0);
uniform vec4 secondary_color : source_color = vec4(0.25, 0.05, 0.35, 1.0);

// -- PBR --
group_uniforms pbr;
uniform float base_roughness : hint_range(0.0, 1.0) = 0.75;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.3;

// -- Border --
group_uniforms border;
uniform float border_width : hint_range(0.0, 0.15) = 0.04;
uniform vec4 border_color : source_color = vec4(0.7, 0.5, 0.1, 1.0);
uniform float border_sharpness : hint_range(0.0, 1.0) = 0.7;
uniform float border_glow : hint_range(0.0, 2.0) = 0.3;
uniform int border_edge_mask : hint_range(0, 15) = 7; // 1=left 2=right 4=bottom 8=top

// -- Emblem --
group_uniforms emblem;
uniform sampler2D emblem_texture : source_color, filter_linear_mipmap;
uniform vec2 emblem_center = vec2(0.5, 0.45);
uniform vec2 emblem_scale = vec2(0.3, 0.3);
uniform vec4 emblem_tint : source_color = vec4(0.8, 0.6, 0.1, 1.0);
uniform float emblem_opacity : hint_range(0.0, 1.0) = 1.0;
uniform int emblem_blend_mode : hint_range(0, 2) = 0; // 0=replace 1=overlay 2=additive

// -- Grunge --
group_uniforms grunge;
uniform float dirt_amount : hint_range(0.0, 1.0) = 0.3;
uniform vec4 dirt_color : source_color = vec4(0.12, 0.08, 0.05, 1.0);
uniform float dirt_gradient_power : hint_range(0.5, 5.0) = 2.0;
uniform float dirt_edge_width : hint_range(0.0, 0.2) = 0.08;
uniform float dirt_noise_scale : hint_range(1.0, 20.0) = 5.0;
uniform float dirt_noise_intensity : hint_range(0.0, 1.0) = 0.4;
uniform float dirt_roughness_boost : hint_range(0.0, 0.5) = 0.15;

// -- Wear --
group_uniforms wear;
uniform float wear_amount : hint_range(0.0, 1.0) = 0.15;
uniform float wear_noise_scale : hint_range(1.0, 30.0) = 12.0;
uniform float wear_edge_width : hint_range(0.0, 0.15) = 0.06;

// -- Lava --
group_uniforms lava;
uniform float lava_speed : hint_range(0.0, 2.0) = 0.3;
uniform float lava_crack_scale : hint_range(1.0, 20.0) = 6.0;
uniform int lava_noise_octaves : hint_range(2, 5) = 3;
uniform float lava_emission : hint_range(0.0, 5.0) = 2.0;

// -- Shape --
group_uniforms shape;
uniform sampler2D shape_mask : filter_linear_mipmap;
uniform float shape_mask_threshold : hint_range(0.0, 1.0) = 0.5;
uniform vec2 shape_mask_uv_scale = vec2(1.0, 1.0);
uniform vec2 shape_mask_uv_offset = vec2(0.0, 0.0);

// -- Occlusion uniforms removed in v3.0 (voxel AO scope-cut); the inspector's
//    ao_strength / ao_roughness_boost knobs are gone. v3.1 may bring SSAO back. --


// ==========================================================
// Noise
// ==========================================================

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

vec3 quintic(vec3 t) {
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = quintic(f);
	return mix(
		mix(mix(hash(i), hash(i + vec3(1, 0, 0)), u.x),
			mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), u.x), u.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), u.x),
			mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), u.x), u.y),
		u.z
	);
}

float fbm3(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * value_noise(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}

float fbm_n(vec3 p, int octaves) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < octaves; i++) {
		v += a * value_noise(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}

float hash12(vec2 pos) {
	vec3 p3 = fract(vec3(pos.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise2d(vec2 n) {
	vec4 b = vec4(floor(n), ceil(n));
	vec2 f = smoothstep(vec2(0.0), vec2(1.0), fract(n));
	return mix(mix(hash12(b.xy), hash12(b.zy), f.x),
	           mix(hash12(b.xw), hash12(b.zw), f.x), f.y);
}


// ==========================================================
// Fabric types
// ==========================================================

// -- Lava (OSRS infernal cape style) --
vec3 fabric_lava(vec2 uv, out float rough_mod, out vec3 emiss) {
	vec3 p = vec3(uv * lava_crack_scale, TIME * lava_speed);

	// Domain-warped FBM for organic, non-blocky cracks
	float warp = fbm3(p + vec3(5.2, 1.3, TIME * lava_speed * 0.3));
	float n = fbm_n(p + vec3(warp * 0.8), lava_noise_octaves);

	// Crack pattern: threshold warped noise for veins
	float cracks = smoothstep(0.42, 0.55, n);
	float flow = fbm3(p + vec3(3.7, 1.2, TIME * lava_speed * 0.6));
	float glow = cracks * smoothstep(0.3, 0.6, flow);

	// Primary = dark stone, secondary = glow/crack color
	vec3 albedo = mix(primary_color.rgb, secondary_color.rgb, n);

	emiss = secondary_color.rgb * glow * lava_emission;
	rough_mod = mix(0.15, -0.3, glow); // cracks are glossy, stone is rough
	return albedo;
}

// -- Silk (smooth, sheeny) --
vec3 fabric_silk(vec2 uv, out float rough_mod) {
	// Directional streaks along V for anisotropic sheen look
	float streak = sin(uv.y * fabric_scale * 4.0) * 0.5 + 0.5;
	streak = pow(streak, 4.0);

	// Secondary finer streak layer
	float fine = sin(uv.y * fabric_scale * 12.0 + uv.x * fabric_scale * 0.5) * 0.5 + 0.5;
	fine = pow(fine, 6.0) * 0.3;

	// Subtle noise variation for natural irregularity
	float n = value_noise(vec3(uv * fabric_scale, 0.0));

	vec3 albedo = mix(primary_color.rgb, secondary_color.rgb, streak * 0.15 + fine + n * 0.05);
	rough_mod = -0.2 * (streak + fine * 0.5); // sheen streaks are glossier
	return albedo;
}

// -- Linen (visible weave) --
vec3 fabric_linen(vec2 uv, out float rough_mod) {
	float s = fabric_scale;
	// Warp and weft threads
	float warp = sin(uv.x * s * TAU);
	float weft = sin(uv.y * s * TAU);

	// Basket weave: which thread is on top alternates per cell
	float cell = step(0.0, sin(uv.x * s * PI) * sin(uv.y * s * PI));
	float thread = mix(warp, weft, cell) * 0.5 + 0.5;

	// Thread color variation
	float variation = sin(uv.x * s * 3.7 + uv.y * s * 2.3) * 0.04;

	vec3 albedo = mix(primary_color.rgb, secondary_color.rgb, thread * 0.12 + variation);
	rough_mod = 0.1 * thread; // raised threads rougher
	return albedo;
}


// ==========================================================
// Procedural normals
// ==========================================================

vec3 fabric_normal(vec2 uv) {
	float h = 0.0;

	if (fabric_type == 0) {
		// Lava: cracked surface bumps (warped FBM matches fabric_lava)
		vec3 np = vec3(uv * lava_crack_scale, 0.0);
		float nw = fbm3(np + vec3(5.2, 1.3, 0.0));
		h = fbm_n(np + vec3(nw * 0.8), lava_noise_octaves);
	} else if (fabric_type == 1) {
		// Silk: smooth ripple undulations
		float streak = sin(uv.y * fabric_scale * 4.0) * 0.5 + 0.5;
		float fine = sin(uv.y * fabric_scale * 12.0 + uv.x * fabric_scale * 0.5) * 0.5 + 0.5;
		h = streak * 0.7 + fine * 0.3;
	} else {
		// Linen: weave bumps
		float warp = sin(uv.x * fabric_scale * TAU);
		float weft = sin(uv.y * fabric_scale * TAU);
		float cell = step(0.0, sin(uv.x * fabric_scale * PI) * sin(uv.y * fabric_scale * PI));
		h = mix(warp, weft, cell) * 0.5 + 0.5;
	}

	// Derive tangent-space normal from screen-space derivatives
	float dx = dFdx(h);
	float dy = dFdy(h);
	vec3 n = normalize(vec3(-dx, -dy, 1.0));
	return n * 0.5 + 0.5; // pack for NORMAL_MAP
}


// ==========================================================
// Border
// ==========================================================

float border_sdf(vec2 uv) {
	float d = 999.0;
	if ((border_edge_mask & 1) != 0) d = min(d, uv.x);         // left
	if ((border_edge_mask & 2) != 0) d = min(d, 1.0 - uv.x);   // right
	if ((border_edge_mask & 4) != 0) d = min(d, 1.0 - uv.y);   // bottom (V=1 is hem)
	if ((border_edge_mask & 8) != 0) d = min(d, uv.y);          // top (V=0 is shoulders)
	return d;
}


// ==========================================================
// Emblem
// ==========================================================

vec4 sample_emblem(vec2 uv) {
	// Detect unassigned texture (Godot placeholder is tiny)
	ivec2 tex_size = textureSize(emblem_texture, 0);
	if (tex_size.x <= 4) return vec4(0.0);

	vec2 emb_uv = (uv - emblem_center) / emblem_scale + 0.5;

	// Bounds check
	if (emb_uv.x < 0.0 || emb_uv.x > 1.0 || emb_uv.y < 0.0 || emb_uv.y > 1.0)
		return vec4(0.0);

	vec4 tex = texture(emblem_texture, emb_uv);
	return vec4(tex.rgb * emblem_tint.rgb, tex.a * emblem_tint.a);
}


// ==========================================================
// Grunge / dirt
// ==========================================================

float dirt_composite(vec2 uv) {
	// Gradient dirt: heavier at bottom hem
	float gradient = pow(uv.y, dirt_gradient_power);

	// Edge dirt: accumulates near all edges
	float edge_dist = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	float edge = 1.0 - smoothstep(0.0, dirt_edge_width, edge_dist);

	// Noise dirt: procedural grime patches
	float noise = fbm3(vec3(uv * dirt_noise_scale, 3.7)) * dirt_noise_intensity;

	return clamp(gradient * 0.6 + edge * 0.3 + noise, 0.0, 1.0) * dirt_amount;
}


// ==========================================================
// Wear
// ==========================================================

float wear_mask(vec2 uv) {
	float edge_dist = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	float noise = fbm3(vec3(uv * wear_noise_scale, 7.3));
	float raw = 1.0 - smoothstep(0.0, wear_edge_width, edge_dist);
	return raw * noise * wear_amount;
}


// ==========================================================
// Vertex
// ==========================================================

void vertex() {
	// v3 substrate: VERTEX_ID indexes the render mesh's un-welded vertex slots.
	// Two-step lookup: welded_index_tex maps render-vert → welded particle,
	// then positions_tex / normals_tex give the simulated skeleton-local pose.
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


// ==========================================================
// Fragment
// ==========================================================

void fragment() {
	vec2 uv = UV;

	// Shape mask cutout (early discard)
	ivec2 mask_size = textureSize(shape_mask, 0);
	if (mask_size.x > 4) {
		vec2 mask_uv = (uv - 0.5) * shape_mask_uv_scale + 0.5 + shape_mask_uv_offset;
		float mask_val = texture(shape_mask, mask_uv).r;
		if (mask_val < shape_mask_threshold) discard;
	}

	// -- Procedural normals (computed first so back-face flip can adjust them) --
	vec3 fnorm = fabric_normal(uv);

	// Back-face normal flip — also flip tangent-space z so NORMAL_MAP processes
	// the back face's tangent space correctly (otherwise the procedural normal
	// points the wrong way and back-face lighting reads as flat / wrong).
	// Do NOT bias DEPTH here: with cull_disabled on thin cloth, a manual depth
	// nudge disables early-Z and produces ordering flicker under 4.6's depth-
	// prepass / TAA path when the sheet folds or self-overlaps.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
		fnorm.z = 1.0 - fnorm.z;
	}

	// -- Fabric base --
	vec3 fabric_albedo = vec3(0.0);
	float rough_mod = 0.0;
	vec3 emission = vec3(0.0);

	if (fabric_type == 0) {
		fabric_albedo = fabric_lava(uv, rough_mod, emission);
	} else if (fabric_type == 1) {
		fabric_albedo = fabric_silk(uv, rough_mod);
	} else {
		fabric_albedo = fabric_linen(uv, rough_mod);
	}

	// -- Border trim --
	float bdist = border_sdf(uv);
	float inner = border_width * (1.0 - border_sharpness * 0.5);
	float bmask = 1.0 - smoothstep(inner, border_width, bdist);
	fabric_albedo = mix(fabric_albedo, border_color.rgb, bmask);
	emission *= (1.0 - bmask); // suppress fabric emission under border
	emission += border_color.rgb * bmask * border_glow;

	// -- Emblem --
	vec4 emb = sample_emblem(uv);
	float blend_str = emb.a * emblem_opacity;
	if (blend_str > 0.001) {
		emission *= (1.0 - blend_str); // suppress fabric emission under emblem
		if (emblem_blend_mode == 0) {
			// Replace — emblem color over fabric
			fabric_albedo = mix(fabric_albedo, emb.rgb, blend_str);
		} else if (emblem_blend_mode == 1) {
			// Overlay
			vec3 ov = mix(
				2.0 * fabric_albedo * emb.rgb,
				1.0 - 2.0 * (1.0 - fabric_albedo) * (1.0 - emb.rgb),
				step(0.5, fabric_albedo)
			);
			fabric_albedo = mix(fabric_albedo, ov, blend_str);
		} else {
			// Additive
			fabric_albedo += emb.rgb * blend_str;
		}
	}

	// -- Grunge / dirt --
	float dirt = dirt_composite(uv);
	fabric_albedo = mix(fabric_albedo, dirt_color.rgb, dirt * 0.7);
	fabric_albedo *= 1.0 - dirt * 0.3;
	rough_mod += dirt * dirt_roughness_boost;

	// -- Wear --
	float wear = wear_mask(uv);
	fabric_albedo = mix(fabric_albedo, fabric_albedo * 1.5 + vec3(0.05), wear);
	rough_mod += wear * 0.2;

	// -- Output --
	// AO output is omitted in v3.0 (voxel AO scope-cut); the renderer's default
	// (1.0 = unoccluded) applies. v3.1 may restore via screen-space AO.
	ALBEDO = fabric_albedo;
	ROUGHNESS = clamp(base_roughness + rough_mod, 0.0, 1.0);
	METALLIC = metallic;
	SPECULAR = specular;
	NORMAL_MAP = fnorm;
	NORMAL_MAP_DEPTH = fabric_normal_intensity;

	if (length(emission) > 0.001) {
		EMISSION = emission;
	}
}
