@tool
class_name GPUClothSolver
extends Node3D

# v3.0 substrate: shared main RenderingDevice + Texture2DRD output, render-thread
# callable submission. Compute writes per-frame positions/normals into storage
# images that the spatial vertex shader reads via texelFetch (two-step lookup
# through a welded_index_tex). No CPU readback, no ArrayMesh rebuild.
#
# Phase 2 adds on top of Phase 1:
#  - UV-seam welding (spatial-hash welder; render mesh keeps un-welded slots,
#    simulation runs on welded particles).
#  - Topology-driven structural + diagonal bending constraints.
#  - K-nearest fishing-line tension propagation, anchored to Marker3D pins.
#  - cloth_pin_override compute pass to plug marker positions into the predict
#    pipeline's "anchored particles snap to skinned_target" mechanism (Hazard 4).
#
# Hazards honored: 1 (welded-space adjacency), 2 (skeleton-local colliders),
# 3 (fork's 48 B bone-matrix encoding), 5 (fishing on predicted, mid-substep,
# no velocity-damp), 8 (RID cleanup via render-thread callable).

@export_group("Mesh Input")
## MeshInstance3D whose mesh and skeleton drive the simulation.
@export var target_mesh: NodePath:
	set(v): target_mesh = v; update_configuration_warnings(); update_gizmos()
## Skeleton3D that animates the mesh.
@export var skeleton: NodePath:
	set(v): skeleton = v; update_configuration_warnings(); update_gizmos()
## Vertices closer than this are merged into a single simulated particle.
## Imported meshes duplicate verts at UV seams and hard normals; without
## welding the cloth tears at every seam.
@export var weld_epsilon: float = 0.001:
	set(v): weld_epsilon = v; update_gizmos()
## Vertex-color channel containing the per-particle cloth weight (0 = R, 1 = G,
## 2 = B, 3 = A). 0 = anchored, 1 = free. v3.0's natural choice is R (matches
## the fork); this export exists so existing v2.x assets that painted into G or
## A don't need to be re-imported.
@export_range(0, 3) var cloth_weight_channel: int = 0:
	set(v): cloth_weight_channel = v; update_gizmos()

@export_group("Physics")
## Acceleration applied to free particles each substep, in **world** space (m/s²).
## The simulation transforms it to the solver/skeleton local frame each frame,
## so the direction stays world-fixed regardless of how the cloth is oriented.
## Defaults to Earth gravity along world -Y; set to zero for zero-G or to a
## horizontal vector for wind-tunnel / sci-fi effects.
@export var gravity: Vector3 = Vector3(0.0, -9.8, 0.0)
## Number of PBD constraint-relaxation passes per substep. More iterations =
## stiffer cloth and better constraint convergence at proportional GPU cost.
## Effective stiffness scales with this value (a stiffness of 0.5 over 8 iters
## feels much stiffer than over 2 iters).
@export_range(1, 32) var solver_iterations: int = 8
## Number of physics substeps per rendered frame. More substeps = more stable
## fast motion (cape catches up with sudden character turns) but linearly more
## GPU work. 8 is a typical garment value; drop to 4 for static drape, raise
## to 16 for fast-moving cinematics.
@export_range(1, 32) var substeps: int = 8
## Structural (edge-length) constraint stiffness. 0 = cloth tears trivially,
## 1 = ideal-rigid (inextensible). Internally mapped to XPBD compliance
## α = (1 - stiffness)² · 1e-5 at init; raising [member solver_iterations] now
## improves *accuracy* (convergence toward α) rather than compounding stiffness,
## so re-tuning is no longer required when you change iter count.
@export_range(0.0, 1.0) var stiffness: float = 0.5
## Bending constraint stiffness; same XPBD compliance mapping as
## [member stiffness] but with a larger base scale (1e-4) — bending forces are
## naturally weaker than stretch, and the documented "drape limply" feel at the
## 0.1 default depends on the per-substep λ accumulation being modest. Higher
## values resist folds and creases. Only takes effect when
## [member bending_from_topology] is on.
@export_range(0.0, 1.0) var bend_stiffness: float = 0.1
## Bending constraints from edge-shared triangle pairs. Off = only structural
## (edge-length) constraints; cloth will be very droopy.
@export var bending_from_topology: bool = true
## Velocity multiplier applied each substep. 1.0 = no damping (energy never
## dissipates, cloth oscillates forever), 0.0 = velocity zeroed every substep
## (effectively static). 0.99 is a typical garment value; lower for "wet" or
## heavy fabric, higher for silky/billowy.
@export_range(0.0, 1.0) var damping: float = 0.99
## Per-component velocity clamp in m/s, applied after damping. Prevents an
## explosive sub-step from launching particles to infinity when a collider
## intersects mid-substep or the skeleton teleports. Raise for fast cinematics.
@export var max_speed: float = 5.0
## Hard ceiling on how far a free particle can stray from its skinned target.
## Combined with the per-substep cloth_weight soft-lerp this replaces v2.x's
## skin_attach_radius + velocity-damp boundary clamp.
@export var max_travel_distance: float = 0.1

@export_group("Pinning")
## Marker3D nodes whose positions pin the nearest welded particle. Markers and
## cloth_weights are orthogonal authoring tools (Hazard 4) — markers are for
## sparse-anchor cases (banner on poles, fabric on a non-skeletal prop) layered
## on top of any cloth_weight gradient.
@export var pin_targets: Array[NodePath] = []:
	set(v): pin_targets = v; update_gizmos()
## Lerp speed for marker positions; prevents cloth snap when the marker teleports.
@export var pin_smooth_speed: float = 20.0

@export_group("Fishing Line")
## K-nearest weighted constraint that hard-clamps each free particle to within
## a stretch×rest-distance budget of the weighted blend of its K nearest
## Marker3D-pinned anchors' CURRENT positions. Eliminates the rubber-band droop
## from slow PBD tension propagation. Skin-anchored particles (cloth_weight=0)
## are intentionally NOT fishing-line anchors — including them welds free
## particles to the rest pose (v2.x lesson, preserved here).
@export var enable_fishing_line: bool = true
## How much each fishing constraint may stretch. 1.0 = inelastic, 1.02 = ~2 %
## stretch (default), 1.10+ = visibly slack.
@export var fishing_stretch: float = 1.02
## Optional per-particle stretch curve sampled by Y position in mesh-local
## bounds. When assigned and non-empty, overrides fishing_stretch per particle
## (e.g., "stiff at the pins, looser at the hem" in one Curve resource).
@export var stretch_curve: Curve
## Number of nearest pins each free particle binds to. K=1 reproduces the v1.3
## single-anchor behavior; K=2-4 smooths Voronoi seams between multiple pins.
@export_range(1, 8) var bindings_per_particle: int = 4

@export_group("Appearance")
## Optional ShaderMaterial. If omitted, falls back to the mesh's existing
## surface material; if that's also missing, instantiates one using
## cloth_surface_textured.gdshader. Always duplicated per-solver so multiple
## solvers don't clobber each other's per-particle texture wiring.
@export var cloth_material: Material
## When cloth_material is null and the mesh's intrinsic surface is a
## StandardMaterial3D, port its full PBR pipeline (metallic / roughness /
## specular scalars + the metallic / roughness / normal / AO textures
## with channel assignments). Off by default because StandardMaterials
## paired with PBR texture packs commonly hold metallic = 1.0 and
## roughness = 1.0 as the scalars (with the per-pixel modulation living in
## the textures) — without the textures, those scalars produce a fully-
## metal / fully-rough surface that renders very dim under most lighting.
## With this off the port stops at albedo_texture + color_tint, which is
## visually safe across asset variation. Flip on once you've verified the
## source material's channel assignments + IBL setup.
@export var port_standard_material_pbr_maps: bool = false
## Negate computed normals. Default true matches the winding convention every
## cloth mesh in this project has shipped with so far (Blender/glTF round-trips
## land here producing cross(p1-p0, p2-p0) pointing inward toward the body —
## without the flip, lighting is wrong AND cloth_skin_offset pushes particles
## INTO the body instead of out). Set false for meshes whose authored winding
## already yields outward right-hand-rule normals.
@export var flip_normals: bool = true
## Visual-only outward extrusion along the per-vertex normal, in mesh-local
## units. Hides body-poke-through when fast animation outruns the cloth solver —
## the rendered cloth shell sits slightly puffed away from where its particles
## physically simulate. Does NOT change physics or collisions, so cloth still
## drapes naturally; it just gives the body a clearance buffer at render time.
## Live-tweakable (changes apply immediately without re-init). Pairs with
## [member cloth_skin_offset] which moves the actual particles outward.
## Typical values: 0.005–0.02 m for tight garments, 0.02–0.05 m for capes on
## fast-moving characters. Set to 0 to disable.
@export var cloth_render_offset: float = 0.0:
	set(v):
		cloth_render_offset = v
		if _surf_mat:
			_surf_mat.set_shader_parameter("render_offset", v)
## Physics-side OUTWARD offset baked into the welded particle positions at
## init, along each particle's mesh-local face normal. Must be ≥ 0 — negative
## values push the cloth INTO the body and produce broken-looking sparse
## "pin hotspots" because only the verts the sanitizer catches stay visible.
## The cloth genuinely simulates with this clearance — pinned edges hang
## slightly off the body, free particles drape from those offset anchors via
## structural constraints, and the cloth equilibrium shape is the offset shape
## (no constraint warping). Pairs with [member cloth_render_offset]
## (visual-only). Use this for true clearance, the render variant for hiding
## fast-animation poke-through; you can combine them. Only takes effect at
## init — changing this at runtime won't update positions until reload. Set
## to 0 to disable.
@export_range(0.0, 0.1, 0.001) var cloth_skin_offset: float = 0.0

@export_group("Inertia")
## Per-axis multiplier on resistance to skeleton translation. 1 = full inertia
## (free particles lag fully behind translation, swooshy cape on a sprinting
## character); 0 = particles glued to the skeleton's translation (no swoosh).
## Useful asymmetrically — e.g., Vector3(1, 0.3, 1) keeps a cape from
## flapping wildly on jumps while preserving lateral swoosh on turns.
@export var inertia_scale: Vector3 = Vector3(1.0, 1.0, 1.0)
## Rotational counterpart. When the skeleton rotates, free particles lag behind
## the rotation by this fraction. 0 = particles ride along (rotate with the
## skeleton); 1 = particles fully stay where they were while the skeleton
## rotated. Anchored particles (cloth_weight=0 or marker-pinned) ignore this —
## their position is driven by skin/pin, not inertia.
@export_range(0.0, 1.0) var rotational_inertia_scale: float = 1.0

@export_group("Wind")
## Constant wind vector in world space, in m/s. Direction = wind direction,
## magnitude = baseline strength. Combined with turbulence at runtime to
## produce gusting; with turbulence = 0 this is the entire wind force.
@export var wind: Vector3 = Vector3.ZERO
## Gust amplitude as a fraction of [member wind]'s magnitude. 0 = perfectly
## steady wind, 1 = gusts can momentarily double or zero the wind strength.
## Has no effect when wind is zero.
@export_range(0.0, 2.0) var wind_turbulence: float = 0.3
## Gust oscillation rate in Hz. 1.0 ≈ one gust cycle per second; higher values
## produce faster, choppier gusts; lower values produce slow swells.
@export var wind_frequency: float = 1.0

@export_group("Colliders")
## Explicit collider override. When empty, the solver recursively scans the
## skeleton tree for GPUClothCollider nodes.
@export var collider_targets: Array[NodePath] = []
## Single skinned MeshInstance3D source for every body-derived collider this
## solver can build. Three independent techniques opt in via their own LOD
## knobs — they share this one mesh:
## [br]• [member auto_collider_lod] > 0 → bone-axis capsules.
## [br]• [member body_sphere_lod] > 0 → per-vert sphere cloud.
## [br]• [member body_collider_voxel_resolution] > 0 → decimated triangle
##   mesh collider (voxel-clustered, single-bone-skinned per frame; the
##   silhouette-accurate option, see [member body_collider_thickness]).
## [br]All three can be on simultaneously; they cost independently.
## Rigged-mode only; skeleton must be set.
@export var body_mesh: NodePath
## Bone-weight count threshold that filters which bones get auto-capsules.
## 0 = off (no auto-colliders). Each level lowers the qualifying threshold:
## 1 = low — only bones with > 50 weighted verts (major limbs / torso, ~6-10 capsules);
## 2 = medium — > 10 weighted verts (+ hands, feet, head, ~12-18 capsules);
## 3 = high — > 0 weighted verts (every weighted bone, ~25-40 capsules).
## Higher LOD = better silhouette fit at proportional per-frame collider cost
## (each capsule = one O(N) particle loop pass in the collide shader).
@export_range(0, 3) var auto_collider_lod: int = 0
## Percentile of bone-weighted vert distances used to set each capsule's radius.
## 1.0 = max (fits every vert but inflates around outliers — single clavicle
## vert weighted to a shoulder bone makes the upperarm capsule huge); 0.85 =
## 85th percentile (ignores the top 15% outliers, much tighter fit). Lower for
## skinnier capsules that may clip a few outlier verts, higher for safer cover.
@export_range(0.5, 1.0) var auto_collider_radius_percentile: float = 0.85
## Global multiplier on auto-collider radii after percentile fit. Useful for
## scenes where you want to dial the whole set thicker (e.g., 1.1 = 10 % more
## clearance) without re-authoring the body mesh weights. Pairs with
## [member cloth_render_offset] and [member cloth_skin_offset] as the three
## body-clearance knobs.
@export_range(0.5, 2.0) var auto_collider_radius_scale: float = 1.0
## Minimum bone-weight a vertex needs to be claimed by that bone for radius
## fitting. Verts in joint regions (knee, elbow, neck-to-shoulder) often have
## split weights between two bones (e.g., 0.55 / 0.45) — without a tight
## threshold, those border verts get assigned to whichever bone wins slightly,
## inflating that bone's capsule with off-axis verts. 0.7 means a vert needs to
## be at least 70 % weighted to a bone to count; joint border verts get skipped
## entirely (they're not really "anyone's verts"). Raise to 0.85 for very tight
## fit (may lose some legitimate verts on smooth-weighted regions); lower to
## 0.5 if too many bones come out with too few verts to qualify for the LOD
## threshold.
@export_range(0.3, 0.95) var auto_collider_dominance_threshold: float = 0.7
## Sphere-cloud density derived from the body mesh's verts. 0 = off. Each level
## subdivides denser:
## 1 = sparse (every 64th vert, ~50-100 spheres),
## 2 = medium (every 16th, ~200-400 spheres),
## 3 = dense (every 4th, ~800-1500 spheres).
## Sphere cloud is an additive layer on top of [member auto_collider_lod]
## capsules — capsules give cheap bulk coverage, spheres fill in irregular
## areas (neck, shoulders, hands) where capsules can't fit. Each sphere is
## skinned to its dominant bone and packed alongside capsules in the collider
## buffer (same shader code path: a sphere is a degenerate capsule with a == b).
@export_range(0, 3) var body_sphere_lod: int = 0
## Radius of every body-derived sphere collider, in metres (skel-internal).
## 3 cm is reasonable for human-scale characters; scale up for chunky models,
## down for slim characters.
@export_range(0.005, 0.1) var body_sphere_radius: float = 0.03
## Decimation grid resolution for the triangle mesh collider built from
## [member body_mesh]. Voxel-clusters body verts (cell centroid becomes the
## representative), remaps triangles, single-bone-skins each surviving vert
## per frame. Silhouette-accurate where capsules and sphere clouds approximate.
## [br]• 0 = OFF (no triangle collider built — recommended default).
## [br]• 8 = very coarse (~30 tris on a human, almost free).
## [br]• 16 = coarse (~80-150 tris, cheap; good starting point).
## [br]• 32 = medium (~200-500 tris).
## [br]• 64+ = fine; only needed for very detailed bodies.
## [br]Per-frame cost = O(particle_count × tri_count × iters × substeps), so
## doubling resolution ~quadruples cost. Pair with the LOD knobs on
## [member body_mesh] — typically pick ONE primary collider style per solver
## (triangle mesh for accuracy, capsules for cheap bulk).
@export_range(0, 128) var body_collider_voxel_resolution: int = 0
## Outward push distance from the body triangle collider's surface, in metres.
## Acts as the cloth's effective thickness against the body — the cloth
## particle sits at exactly this distance from any triangle face. Small
## (0.005–0.02) gives form-fitting cloth; larger (0.03+) gives floaty drape
## with a visible gap. Bump this when running with low
## [member body_collider_voxel_resolution] so the coarse proxy still covers
## the physical gaps between representative verts.
@export_range(0.001, 0.1) var body_collider_thickness: float = 0.01
## Coulomb friction coefficient at cloth-collider contacts (primitive
## capsule/sphere/box, body triangle mesh, AND peer cloth — all three paths
## share this value). After each per-collider push, the particle's tangential
## motion (motion since substep start, minus its component along the push
## direction) is clamped by μ × push_magnitude — directly attenuates the
## velocity injection that causes propagating jitter at contact regions.
## 0 = frictionless (slippery, fast settle to lowest position).
## 0.3 = light friction (default — kills most contact jitter).
## 0.7 = sticky (cloth grabs onto contact, slides slowly).
## 1.0 = full Coulomb cap (very sticky, useful for sash-on-shoulder).
@export_range(0.0, 1.0) var collider_friction: float = 0.3
## Other GPUClothSolver nodes whose current animated geometry this solver
## should collide against. Each peer's CURRENT cloth state is used as a
## triangle collider per frame — shirt verts get pushed out of pants, pants
## verts out of shirt, etc. Both solvers must share the same reference frame
## (skeleton); mismatched peers are skipped with a warning. Symmetric setup:
## name peers on BOTH sides for two-way interaction (Solver A → peers = [B],
## Solver B → peers = [A]). Per-frame cost = peer_tri_count × our_particle_count
## per peer per iter; see [member peer_collider_voxel_resolution] to decimate
## the peer-facing triangle count and recover FPS in cloth-on-cloth scenes.
@export var peer_cloth_solvers: Array[NodePath] = []
## Cloth-on-itself collision. When enabled, the solver dispatches a self-
## collide pass each substep that pushes its own particles out of its own
## decimated proxy mesh — the same proxy peers bind via
## [member peer_collider_voxel_resolution]. Targets fold-through artifacts:
## a flag flapping back over itself, a cape collapsing, dress hems crossing.
## Each particle's contact-direction motion gets damped by
## [member collider_friction], same as body / peer cloth collision.
## [br][b]Cost:[/b] one extra dispatch per substep = O(particle_count × proxy_tri_count).
## The proxy is small (200-500 tris typical), so this is cheap relative to a
## full body collider. Requires [member peer_collider_voxel_resolution] > 0.
@export var self_collide: bool = false
## Effective particle thickness for self-collision, in metres. Much smaller
## than [member body_collider_thickness] by design: at rest, every particle
## sits within a few mm of its own proxy mesh, so this value also acts as the
## "rest puff" — the height the cloth visually offsets from its own simulated
## surface. Keep small (3-8 mm typical) for a barely-visible inflation.
## Folded layers separate by this distance at minimum once collision kicks in.
@export_range(0.001, 0.05) var self_collide_thickness: float = 0.005
## Decimation grid resolution for the proxy mesh that PEERS collide against
## (this solver's own simulation still uses every welded triangle). Voxel-
## clusters welded particles in rest space, picks one representative per cell,
## and remaps the full welded triangle list onto that subset — peers bind our
## full positions buffer (no per-frame copy) plus this smaller index buffer.
##
## Math: a 6500-tri shirt at voxel_res=12 → ~150 reps → ~300 proxy tris,
## roughly 20× cheaper per peer per iter. Higher = silhouette-accurate but
## costly; lower = coarser drape contact but cheap enough for many peers.
## 0 = no decimation (proxy == full mesh; same cost as before this export).
## [member body_collider_thickness] doubles as the peer-collision thickness;
## bump it slightly when decimating hard so the coarse proxy still covers the
## physical gaps between representative particles.
@export_range(0, 64) var peer_collider_voxel_resolution: int = 12

@export_group("Debug")
## Draw a colored cross at every welded particle's simulated position.
## Red = anchored (cloth_weight near 0), green = free (cloth_weight near 1).
## Pulls positions back from the GPU each frame — toggle off for perf testing.
@export var debug_show_particles: bool = false
## Draw wireframes of every active collider at its current animated pose:
## cyan = auto-generated capsules, yellow = body sphere cloud, magenta =
## manually-authored GPUClothColliders, green = decimated body triangle mesh
## collider (driven by [member body_collider_voxel_resolution]).
## No GPU readback cost (uses CPU-side bone poses), so this is cheap enough
## to leave on while tuning.
@export var debug_show_colliders: bool = false
## Draw an orange wireframe of the peer-collision proxy mesh (the decimated
## triangulation built from [member peer_collider_voxel_resolution] that PEERS
## bind for cloth-cloth collision). Each line spans two representative welded
## particles at their current simulated positions, so you see the actual
## low-poly silhouette your peers are colliding against. Forces a GPU readback
## of positions each frame (same cost as [member debug_show_particles]) since
## the proxy verts move with the simulation.
@export var debug_show_peer_proxy: bool = false
## Marker size in metres (skeleton-local). Also controls the editor gizmo's
## cross size when the solver node is selected.
@export var debug_particle_size: float = 0.03:
	set(v): debug_particle_size = v; update_gizmos()

# ---------------------------------------------------------------------------
#  GPU resources (all RIDs on the main RenderingDevice; freed via
#  call_on_render_thread in _exit_tree per Hazard 8)
# ---------------------------------------------------------------------------
var _rd: RenderingDevice

var _positions_buffer: RID
var _predicted_buffer: RID
var _velocities_buffer: RID
var _constraints_buffer: RID
var _colliders_buffer: RID
var _rest_positions_buffer: RID
var _bone_indices_buffer: RID
var _bone_weights_skin_buffer: RID
var _bone_transforms_buffer: RID
var _skinned_targets_buffer: RID
var _cloth_weights_buffer: RID
var _face_normals_buffer: RID
var _indices_gpu_buffer: RID
var _vert_tri_counts_buffer: RID
var _vert_tri_offsets_buffer: RID
var _vert_tri_list_buffer: RID
# Phase 2 additions
var _bindings_buffer: RID            # K bindings per particle, fishing-line
var _pin_overrides_buffer: RID       # one entry per Marker3D pin (skel-local pos)
var _welded_index_lookup_rid: RID    # texture: render-vert idx → welded idx
# Phase 3 (XPBD): per-constraint Lagrange multiplier λ, accumulated across
# solver_iterations within each substep. Reset on iter 0 via the high bit of
# the solve push constant's constraint_offset — no separate clear pass needed.
var _lambda_buffer: RID

var _positions_img_rid: RID
var _normals_img_rid: RID
var _positions_tex: Texture2DRD
var _normals_tex: Texture2DRD
var _welded_index_tex: Texture2DRD
var _tex_w: int   # welded particle count → simulation-output dims
var _tex_h: int
var _render_tex_w: int  # render-vert count → vertex-shader-lookup dims
var _render_tex_h: int

var _skin_shader: RID
var _predict_shader: RID
var _solve_shader: RID
var _update_shader: RID
var _collide_shader: RID
var _warm_start_shader: RID
var _normals_shader: RID
var _output_shader: RID
var _fishing_shader: RID
var _pin_override_shader: RID
var _skin_collide_shader: RID  # sanitizer: pushes skinned_targets out of colliders

var _skin_pipeline: RID
var _predict_pipeline: RID
var _solve_pipeline: RID
var _update_pipeline: RID
var _collide_pipeline: RID
var _warm_start_pipeline: RID
var _normals_pipeline: RID
var _output_pipeline: RID
var _fishing_pipeline: RID
var _pin_override_pipeline: RID
var _skin_collide_pipeline: RID

var _skin_uniform_set: RID
var _predict_uniform_set: RID
var _solve_uniform_set: RID
var _update_uniform_set: RID
var _collide_uniform_set: RID
var _warm_start_uniform_set: RID
var _normals_uniform_set: RID
var _output_uniform_set: RID
var _fishing_uniform_set: RID
var _pin_override_uniform_set: RID
var _skin_collide_uniform_set: RID

# ---------------------------------------------------------------------------
#  Runtime state
# ---------------------------------------------------------------------------
var _mesh_instance_node: MeshInstance3D
var _skeleton_node: Skeleton3D
var _skin: Skin
# When false, the solver runs in "unrigged" mode: skeleton + skin are absent,
# the simulation coordinate frame is the solver's own local space, the skin
# compute pass is skipped (skinned_targets is pre-populated at init from rest
# positions), and pin_targets are the only anchoring mechanism.
var _use_skinning: bool = false
# Node whose global_transform defines the simulation's reference frame. In
# rigged mode that's _skeleton_node; in unrigged mode it's self. Cached at init
# end so all per-frame consumers (inertia tracking, pin smoothing, collider
# packing, debug overlay placement) read the same node.
var _ref_node: Node3D

var _particle_count: int        # = _welded_positions.size() — what compute simulates
var _render_vert_count: int     # = _src_vertices.size() — cloth-only verts in the particle list
var _raw_render_count: int      # full mesh vert count — what VERTEX_ID indexes into; sizes welded_index_tex
var _raw_to_filtered_lookup: PackedInt32Array  # raw render-vert idx → filtered idx (-1 if not in a cloth surface). Used to wire the lookup texture so cloth-shader VERTEX_ID lookups resolve to valid welded indices for cloth render verts.
var _tri_count: int
var _constraint_count: int
var _constraint_groups: Array = []
var _bind_count: int
var _bind_to_bone: PackedInt32Array

# Mesh ingestion (Phase 2)
var _src_vertices: PackedVector3Array
var _src_uvs: PackedVector2Array
var _src_colors: PackedColorArray
var _src_indices: PackedInt32Array     # render-vert indexed
var _src_bones: PackedInt32Array       # 4 bone indices per source vertex
var _src_weights: PackedFloat32Array   # 4 bone weights per source vertex
var _welded_positions: PackedVector3Array
var _original_to_welded: PackedInt32Array  # source-vert idx → welded particle idx
var _first_sv: PackedInt32Array            # welded particle idx → first source vert that mapped to it
var _welded_indices: PackedInt32Array      # triangle indices in welded space (for GPU normals pass)

# Fishing-line / pinning
var _pin_map: Array[Dictionary] = []   # [{marker, particle_idx, smoothed_pos}]
var _has_anchors: bool = false
var _pin_overrides_bytes: PackedByteArray  # reused per-frame to avoid alloc

var _colliders: Array[GPUClothCollider] = []
# Auto-generated capsule colliders from body_mesh. Each entry:
#   {bone_a: int, bone_b: int, radius: float}
# bone_a and bone_b are skeleton bone indices; their global_pose origins each
# frame become the capsule axis endpoints (in skel-local space).
var _auto_colliders: Array[Dictionary] = []
# Sphere-cloud colliders sampled from the body mesh. Each entry:
#   {bone: int, local_offset: Vector3, radius: float}
# At pack time: skel-local center = skel.get_bone_global_pose(bone) * local_offset,
# packed as a degenerate capsule (a == b) so the existing collide shader handles
# it as a sphere with zero extra code.
var _auto_spheres: Array[Dictionary] = []
var _collider_count: int = 0  # = _colliders.size() + _auto_colliders.size() + _auto_spheres.size()

# Skinned mesh collider — decimated body triangles, single-bone skinning.
# _collider_tris[i] = [{bone: int, local: Vector3}, {bone, local}, {bone, local}]
# Per-frame each vert's skel-local position = skel.get_bone_global_pose(bone) * local.
# Packed into _collider_tri_bytes, uploaded to _collider_tri_buffer, consumed by
# the cloth_collide_triangles compute shader.
var _collider_tris: Array = []
var _collider_tri_bytes: PackedByteArray
var _collider_tri_buffer: RID
var _collide_tris_shader: RID
var _collide_tris_pipeline: RID
var _collide_tris_uniform_set: RID
var _collide_tris_push: PackedByteArray
# Triangle-collider sanitizer: pushes skinned_targets out of body triangles
# once per frame so rest-jitter doesn't fight the per-iter collide push.
var _skin_collide_tris_shader: RID
var _skin_collide_tris_pipeline: RID
var _skin_collide_tris_uniform_set: RID

# Peer cloth collision — one entry per resolved peer:
#   {solver, uniform_set, sanitize_uniform_set, push}
# Per-peer uniform sets for both the per-substep collide (operates on
# predicted) and the once-per-frame sanitizer (operates on skinned_targets).
# Same push constant works for both — only differs by what's at binding 0/1.
var _peer_collide_shader: RID
var _peer_collide_pipeline: RID
var _peer_skin_collide_shader: RID
var _peer_skin_collide_pipeline: RID
var _peers: Array[Dictionary] = []
# Decimated triangle index buffer that PEERS read for cloth-cloth collision.
# Built once at init from _welded_indices via voxel clustering of
# _welded_positions: indices that fall in the same rest-space cell collapse to
# one representative welded particle index. The buffer therefore references
# valid entries in _positions_buffer (no separate position storage, no copy) —
# just a sparser triangulation drawn over the same particles. Falls back to
# the full welded index buffer when peer_collider_voxel_resolution == 0.
var _peer_proxy_indices_buffer: RID
var _peer_proxy_tri_count: int = 0
# CPU-side copy of the proxy index list, kept so the debug overlay can draw the
# proxy mesh as a wireframe over the live particle positions. Same data that's
# packed and uploaded to _peer_proxy_indices_buffer at init.
var _peer_proxy_indices: PackedInt32Array

# Self-collision uses the same shader + proxy buffers as peer collision; the
# only delta is uniform set bindings point at OUR positions for both "ours" and
# "peer", and the push constant's is_self flag is set so the shader skips tris
# that contain the testing particle as a vert.
var _self_collide_uniform_set: RID
var _self_collide_push: PackedByteArray

var _surf_mat: ShaderMaterial

var _prev_skel_world_pos: Vector3
var _prev_skel_world_basis: Basis

# Debug overlay
var _debug_im: ImmediateMesh
var _debug_mi: MeshInstance3D
var _debug_setup_done: bool = false
var _debug_cloth_weights: PackedFloat32Array  # CPU-side copy for coloring

# Reusable push-constant buffers
var _skin_push: PackedByteArray
var _pbd_push: PackedByteArray
var _output_push: PackedByteArray         # constant after init
var _fishing_push: PackedByteArray        # constant after init
var _pin_override_push: PackedByteArray   # constant after init
var _skin_collide_push: PackedByteArray   # constant after init (particle_count, collider_count)

var _plugin_dir: String
var _gpu_init_done: bool = false
var _needs_warm_start: bool = true


# ---------------------------------------------------------------------------
#  Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_plugin_dir = get_script().resource_path.get_base_dir().get_base_dir()

	if Engine.is_editor_hint():
		return

	if not RenderingServer.get_rendering_device():
		push_error("[GPUCloth] Requires Vulkan renderer (Forward+ or Mobile). Aborting.")
		return

	set_process_priority(100)
	print("[GPUCloth] ── Initializing GPUClothSolver ──────────────────────────")
	_initialize()


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or not _gpu_init_done:
		return
	if _needs_warm_start:
		RenderingServer.call_on_render_thread(_gpu_do_warm_start)
		_needs_warm_start = false
		return
	_simulate(delta)
	if debug_show_particles or debug_show_colliders or debug_show_peer_proxy:
		_ensure_debug_setup()
		# Skeleton-local positions are drawn at world via the skeleton's
		# global transform — re-applied each frame so the markers track the
		# character.
		_debug_mi.global_transform = _ref_node.global_transform
		if debug_show_particles or debug_show_peer_proxy:
			# Either of these needs current particle positions from GPU; the
			# collider draw piggybacks in _debug_apply.
			RenderingServer.call_on_render_thread(_debug_readback)
		else:
			# Colliders only — no readback needed, draw directly.
			_debug_apply(PackedByteArray(), PackedByteArray())
	elif _debug_setup_done:
		_debug_im.clear_surfaces()


func _exit_tree() -> void:
	if not _gpu_init_done:
		return
	_gpu_init_done = false
	# Capture every RID into a list so the lambda stays safe after this node is freed.
	# Hazard 8 — every free_rid must run on the render thread that owns the main RD.
	var rids: Array = [
		_positions_buffer, _predicted_buffer, _velocities_buffer,
		_constraints_buffer, _colliders_buffer,
		_rest_positions_buffer, _bone_indices_buffer, _bone_weights_skin_buffer,
		_bone_transforms_buffer, _skinned_targets_buffer, _cloth_weights_buffer,
		_face_normals_buffer, _indices_gpu_buffer,
		_peer_proxy_indices_buffer,
		_vert_tri_counts_buffer, _vert_tri_offsets_buffer, _vert_tri_list_buffer,
		_bindings_buffer, _pin_overrides_buffer, _welded_index_lookup_rid,
		_lambda_buffer,
		_positions_img_rid, _normals_img_rid,
		_collider_tri_buffer,
		_skin_uniform_set, _predict_uniform_set, _solve_uniform_set,
		_update_uniform_set, _collide_uniform_set, _warm_start_uniform_set,
		_normals_uniform_set, _output_uniform_set,
		_fishing_uniform_set, _pin_override_uniform_set,
		_skin_collide_uniform_set, _collide_tris_uniform_set, _skin_collide_tris_uniform_set,
		_self_collide_uniform_set,
		_skin_pipeline, _predict_pipeline, _solve_pipeline,
		_update_pipeline, _collide_pipeline, _warm_start_pipeline,
		_normals_pipeline, _output_pipeline,
		_fishing_pipeline, _pin_override_pipeline,
		_skin_collide_pipeline, _collide_tris_pipeline, _skin_collide_tris_pipeline,
		_peer_collide_pipeline, _peer_skin_collide_pipeline,
		_skin_shader, _predict_shader, _solve_shader,
		_update_shader, _collide_shader, _warm_start_shader,
		_normals_shader, _output_shader,
		_fishing_shader, _pin_override_shader,
		_skin_collide_shader, _collide_tris_shader, _skin_collide_tris_shader,
		_peer_collide_shader, _peer_skin_collide_shader,
	]
	# Per-peer uniform sets reference RIDs we don't own (the peer's
	# positions/indices buffers). When the peer's _exit_tree runs first, the
	# RD auto-invalidates every uniform set that referenced those freed
	# buffers — so by the time our own teardown runs the uniform sets we hold
	# may already be stale, and free_rid would push "Attempted to free invalid
	# ID" errors. _gpu_init_done is cleared at the top of _exit_tree, so a
	# peer with _gpu_init_done == false (or one that's been queued for delete)
	# has already either freed its buffers or is about to — skip its uniform
	# sets to avoid the cascade.
	for p in _peers:
		var peer: Object = p.solver
		var peer_alive: bool = is_instance_valid(peer) and peer._gpu_init_done
		if not peer_alive:
			continue
		if p.uniform_set.is_valid():
			rids.append(p.uniform_set)
		if p.has("sanitize_uniform_set") and p.sanitize_uniform_set.is_valid():
			rids.append(p.sanitize_uniform_set)
	RenderingServer.call_on_render_thread(func() -> void:
		var rd := RenderingServer.get_rendering_device()
		if not rd:
			return
		for rid: RID in rids:
			if rid.is_valid():
				rd.free_rid(rid)
	)
	print("[GPUCloth] GPU resource cleanup queued on render thread.")


# ---------------------------------------------------------------------------
#  Editor warnings
# ---------------------------------------------------------------------------

func _get_configuration_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	var mi := get_node_or_null(target_mesh) as MeshInstance3D
	if not mi:
		w.append("target_mesh must point to a MeshInstance3D.")
		return w
	# Skeleton is optional: when unset (or pointing to a non-Skeleton3D), the
	# solver runs in unrigged mode and pin_targets / painted cloth_weights
	# become the anchor sources. We can't cheaply check vertex colors here
	# (would require loading the mesh on every property change), so the
	# "no anchors" diagnostic lives in the runtime init log instead.
	var skel_node := get_node_or_null(skeleton)
	if skel_node != null and not skel_node is Skeleton3D:
		w.append("skeleton is set but doesn't point to a Skeleton3D. Falling back to unrigged mode.")
	return w


# ---------------------------------------------------------------------------
#  Initialization (game thread, CPU-only)
# ---------------------------------------------------------------------------

func _initialize() -> void:
	# Resolve nodes
	_mesh_instance_node = get_node_or_null(target_mesh) as MeshInstance3D
	if not _mesh_instance_node:
		push_error("[GPUCloth] target_mesh is not set or not a MeshInstance3D. Aborting.")
		return

	# Skeleton + skin are both optional. When either is missing we fall into
	# "unrigged" mode: the simulation runs in solver-local space, the skin
	# compute pass is skipped (skinned_targets is pre-populated from rest), and
	# pin_targets become the only anchoring mechanism. Both must be present for
	# the rigged path to run — half-rigged setups (skin but no skeleton, or
	# vice versa) fall back to unrigged and warn.
	_skeleton_node = get_node_or_null(skeleton) as Skeleton3D
	_skin = _mesh_instance_node.get_skin()
	_use_skinning = (_skeleton_node != null and _skin != null)
	_ref_node = _skeleton_node if _use_skinning else (self as Node3D)
	if _use_skinning:
		_bind_count = _skin.get_bind_count()
		print("[GPUCloth] Skeleton: %s  bones: %d  Skin binds: %d" % [
			_skeleton_node.name, _skeleton_node.get_bone_count(), _bind_count])
	else:
		_bind_count = 0
		var reason: String
		if _skeleton_node == null and _skin == null:
			reason = "no skeleton + no skin"
		elif _skeleton_node == null:
			reason = "no skeleton (skin present but unused)"
		else:
			reason = "no skin (skeleton present but unused)"
		print("[GPUCloth] Unrigged mode (%s). Simulation runs in solver-local space; pin_targets are the only anchor source." % reason)

	# ── Multi-surface mesh ingestion ──
	# v2.x's _extract_mesh_data walks every triangle-primitive surface, dedupes,
	# and aggregates verts/uvs/colors/bones/weights/indices. Welding then runs
	# across the aggregated set so UV seams between surfaces collapse together.
	var arr_mesh := _mesh_instance_node.mesh as Mesh
	if not arr_mesh or arr_mesh.get_surface_count() == 0:
		push_error("[GPUCloth] target_mesh has no Mesh surfaces.")
		return

	var extracted := GPUClothSolver.extract_mesh_data(arr_mesh)
	var raw_vertices: PackedVector3Array = extracted.vertices
	var raw_uvs:      PackedVector2Array = extracted.uvs
	var raw_colors:   PackedColorArray   = extracted.colors
	var raw_indices:  PackedInt32Array   = extracted.indices
	var raw_bones:    PackedInt32Array   = extracted.bones
	var raw_weights:  PackedFloat32Array = extracted.weights
	var surface_ranges: Array            = extracted.surface_ranges

	if raw_vertices.is_empty() or raw_indices.size() < 3:
		push_error("[GPUCloth] target_mesh has no valid triangle geometry.")
		return
	if raw_colors.is_empty():
		push_error("[GPUCloth] target_mesh has no vertex color (ARRAY_COLOR). Paint cloth_weight into the R channel in Blender.")
		return
	# Bone data required only when running rigged. Unrigged meshes don't need it.
	if _use_skinning and (raw_bones.is_empty() or raw_weights.is_empty()):
		push_error("[GPUCloth] target_mesh has no bone data but skeleton + skin are set. Either remove the skeleton/skin or paint bone weights.")
		return

	# ── Per-surface filter: cloth-only ──
	# Multi-surface meshes can mix simulated cloth (cape, skirt) with static
	# rigged geometry (body, hair). Aggregating ALL surfaces into the welded
	# particle list corrupts the cape's bone weights — across surfaces, bone
	# indices may reference different bone palettes, and the welder can collapse
	# cape verts with adjacent body verts (whichever vertex came first wins per
	# _first_sv, so cape verts inherit body bone weights and at runtime follow
	# the wrong bones). Solve both by including ONLY surfaces with at least one
	# free vertex (cw > 0.01) in the simulation pipeline. Non-cloth surfaces
	# render natively (no cloth shader override) using Godot's standard skinning.
	_raw_render_count = raw_vertices.size()
	var is_cloth_vert := PackedByteArray()
	is_cloth_vert.resize(_raw_render_count)
	var cloth_surface_idxs: Array[int] = []
	for rng in surface_ranges:
		var has_free := false
		for v_idx in range(rng.start, rng.end):
			var c: Color = raw_colors[v_idx]
			var cw_raw: float
			match cloth_weight_channel:
				1: cw_raw = c.g
				2: cw_raw = c.b
				3: cw_raw = c.a
				_: cw_raw = c.r
			if clampf(cw_raw, 0.0, 1.0) > 0.01:
				has_free = true
				break
		if has_free:
			cloth_surface_idxs.append(rng.src_surface)
			for v_idx in range(rng.start, rng.end):
				is_cloth_vert[v_idx] = 1

	if cloth_surface_idxs.is_empty():
		push_error("[GPUCloth] No surface has any free vertices (cw > 0.01 in channel %d). Cloth simulation has nothing to simulate. Paint at least some verts with non-zero cloth weight in the selected channel." % cloth_weight_channel)
		return

	# Map raw render-vert index → filtered render-vert index (-1 if excluded).
	# Used both to remap raw_indices into the filtered space and to wire
	# welded_index_tex (which stays sized to the raw render count so VERTEX_ID
	# lookups in the shader stay in range for non-cloth render verts — those
	# entries are never read because their surfaces don't get the cloth shader
	# override, so they can hold any in-range welded index).
	var raw_to_filtered := PackedInt32Array()
	raw_to_filtered.resize(_raw_render_count)
	var filtered_count := 0
	for i in _raw_render_count:
		if is_cloth_vert[i] != 0:
			raw_to_filtered[i] = filtered_count
			filtered_count += 1
		else:
			raw_to_filtered[i] = -1

	_src_vertices = PackedVector3Array(); _src_vertices.resize(filtered_count)
	_src_uvs      = PackedVector2Array(); _src_uvs.resize(filtered_count)
	_src_colors   = PackedColorArray();   _src_colors.resize(filtered_count)
	var has_bone_data: bool = not raw_bones.is_empty() and not raw_weights.is_empty()
	if has_bone_data:
		_src_bones   = PackedInt32Array();   _src_bones.resize(filtered_count * 4)
		_src_weights = PackedFloat32Array(); _src_weights.resize(filtered_count * 4)
	else:
		_src_bones   = PackedInt32Array()
		_src_weights = PackedFloat32Array()
	var fi := 0
	for i in _raw_render_count:
		if is_cloth_vert[i] == 0:
			continue
		_src_vertices[fi] = raw_vertices[i]
		_src_uvs[fi]      = raw_uvs[i]
		_src_colors[fi]   = raw_colors[i]
		if has_bone_data:
			for k in 4:
				_src_bones[fi * 4 + k]   = raw_bones[i * 4 + k]
				_src_weights[fi * 4 + k] = raw_weights[i * 4 + k]
		fi += 1

	# Rebuild triangle indices in filtered space, dropping any triangle whose
	# verts are all-or-partially excluded (a partial-exclusion can only happen
	# at a cross-surface seam, which would be authoring nonsense).
	_src_indices = PackedInt32Array()
	var dropped_tris := 0
	var raw_tri_count: int = raw_indices.size() / 3
	for tri in raw_tri_count:
		var ri0: int = raw_indices[tri * 3]
		var ri1: int = raw_indices[tri * 3 + 1]
		var ri2: int = raw_indices[tri * 3 + 2]
		if is_cloth_vert[ri0] != 0 and is_cloth_vert[ri1] != 0 and is_cloth_vert[ri2] != 0:
			_src_indices.append(raw_to_filtered[ri0])
			_src_indices.append(raw_to_filtered[ri1])
			_src_indices.append(raw_to_filtered[ri2])
		else:
			dropped_tris += 1

	_render_vert_count = _src_vertices.size()
	_tri_count = _src_indices.size() / 3
	print("[GPUCloth] Cloth surface(s) %s contribute %d render verts / %d triangles (from %d raw verts / %d raw triangles, %d cross-seam triangles dropped)." % [
		str(cloth_surface_idxs), _render_vert_count, _tri_count,
		_raw_render_count, raw_tri_count, dropped_tris])

	# Cache raw→filtered for the lookup texture build later in this function.
	_raw_to_filtered_lookup = raw_to_filtered

	# ── Welding ──
	# Spatial-hash welder collapses coincident verts so the simulation runs on
	# unique particles while the render mesh keeps its original slots (and UVs).
	var welded := GPUClothSolver.weld_vertices(_src_vertices, weld_epsilon)
	_welded_positions   = welded.welded_positions
	_original_to_welded = welded.original_to_welded
	_particle_count = _welded_positions.size()
	print("[GPUCloth] Welded particles: %d (from %d render verts)" % [_particle_count, _render_vert_count])

	# ── Optional skin-offset clearance buffer ──
	# Push each welded particle outward along its mesh-local face normal by
	# cloth_skin_offset metres. We mutate _welded_positions in place so every
	# downstream consumer (pos_data, rest_data, constraint rest distances, and
	# the skin shader's bone_matrix * rest_position pipeline) inherits the
	# offset automatically — the cloth equilibrium shape becomes the offset
	# shape, no warping. Normals are area-weighted (un-normalised face normals)
	# so corners and boundaries get a more stable direction than pure averaging.
	#
	# flip_normals: if the user set it, the cloth's authored triangle winding
	# has normals pointing INWARD (toward the body); without inverting our
	# offset direction the cloth gets pushed INTO the body instead of away,
	# producing z-fight at sanitizer-rescued verts. Same flag that drives the
	# render-normal flip should drive the offset flip.
	if cloth_skin_offset != 0.0:
		var particle_normals := PackedVector3Array()
		particle_normals.resize(_particle_count)
		particle_normals.fill(Vector3.ZERO)
		var src_tri_count: int = _src_indices.size() / 3
		for tri in src_tri_count:
			var ri0: int = _src_indices[tri * 3]
			var ri1: int = _src_indices[tri * 3 + 1]
			var ri2: int = _src_indices[tri * 3 + 2]
			var wi0: int = _original_to_welded[ri0]
			var wi1: int = _original_to_welded[ri1]
			var wi2: int = _original_to_welded[ri2]
			var v0: Vector3 = _welded_positions[wi0]
			var v1: Vector3 = _welded_positions[wi1]
			var v2: Vector3 = _welded_positions[wi2]
			var face_n: Vector3 = (v1 - v0).cross(v2 - v0)
			particle_normals[wi0] += face_n
			particle_normals[wi1] += face_n
			particle_normals[wi2] += face_n
		var skipped_normals := 0
		var signed_offset: float = -cloth_skin_offset if flip_normals else cloth_skin_offset
		for p in _particle_count:
			var nl: float = particle_normals[p].length()
			if nl > 1e-7:
				_welded_positions[p] += (particle_normals[p] / nl) * signed_offset
			else:
				skipped_normals += 1
		print("[GPUCloth] Skin offset %.4f m applied to %d particles (%d had degenerate normals; flip_normals=%s, effective sign=%s)." % [
			cloth_skin_offset, _particle_count - skipped_normals, skipped_normals,
			flip_normals, "−" if flip_normals else "+"])

	# Build first_sv[w]: first source vertex that maps to welded particle w.
	# Used as the authoritative source for cloth_weight, bones, weights, and
	# rest-position data when multiple source verts collapse to one particle.
	_first_sv = PackedInt32Array()
	_first_sv.resize(_particle_count)
	_first_sv.fill(-1)
	for orig_idx in _render_vert_count:
		var w_idx: int = _original_to_welded[orig_idx]
		if _first_sv[w_idx] == -1:
			_first_sv[w_idx] = orig_idx

	# Resolve bind → skeleton bone index (rigged path only)
	_bind_to_bone.resize(_bind_count)
	if _use_skinning:
		for bi in _bind_count:
			var bone_idx: int = _skin.get_bind_bone(bi)
			if bone_idx < 0:
				bone_idx = _skeleton_node.find_bone(str(_skin.get_bind_name(bi)))
			_bind_to_bone[bi] = bone_idx

	# ── Per-particle data in welded space ──
	# `mesh_to_ref` converts mesh-local positions into the simulation's
	# reference frame — skeleton-local when rigged, solver-local when unrigged.
	# Its inverse goes onto the vertex shader as `skel_to_mesh_transform`.
	var mesh_to_ref := _ref_node.global_transform.affine_inverse() \
		* _mesh_instance_node.global_transform

	var pos_data        := PackedFloat32Array(); pos_data.resize(_particle_count * 4)
	var rest_data       := PackedFloat32Array(); rest_data.resize(_particle_count * 4)
	var bone_w_data     := PackedFloat32Array(); bone_w_data.resize(_particle_count * 4)
	var cloth_w_data    := PackedFloat32Array(); cloth_w_data.resize(_particle_count * 4)
	var bone_idx_bytes  := PackedByteArray(); bone_idx_bytes.resize(_particle_count * 8)

	var n_anchored := 0; var n_blend := 0; var n_free := 0
	var disagreements := 0

	# ── Welded cloth_weight: most-pinned sibling wins ──
	# UV-seam splits (different UVs, hard edges, or material-slot boundaries
	# all force Blender to duplicate verts at the same 3D position) produce
	# multiple source verts that get welded into one particle. Previously
	# only the FIRST source vert's color was read, so painted pin regions
	# silently lost to unpainted siblings whose vert just happened to come
	# first in the GLB's arbitrary vertex order — visible as sparse pin
	# hotspots instead of a clean anchored region. Take the MIN across all
	# siblings: if any sibling was painted as pinned (cw=0), the welded
	# particle is pinned, which matches what a brush stroke means in Blender.
	var welded_cw_min := PackedFloat32Array(); welded_cw_min.resize(_particle_count); welded_cw_min.fill(2.0)
	var welded_cw_max := PackedFloat32Array(); welded_cw_max.resize(_particle_count); welded_cw_max.fill(-1.0)
	for orig_idx in _render_vert_count:
		var c0: Color = _src_colors[orig_idx]
		var cw0: float
		match cloth_weight_channel:
			1: cw0 = c0.g
			2: cw0 = c0.b
			3: cw0 = c0.a
			_: cw0 = c0.r
		cw0 = clampf(cw0, 0.0, 1.0)
		var wi: int = _original_to_welded[orig_idx]
		if cw0 < welded_cw_min[wi]: welded_cw_min[wi] = cw0
		if cw0 > welded_cw_max[wi]: welded_cw_max[wi] = cw0
	var cw_disagreements := 0
	for w_idx in _particle_count:
		if welded_cw_max[w_idx] - welded_cw_min[w_idx] > 0.05:
			cw_disagreements += 1
	if cw_disagreements > 0:
		push_warning("[GPUCloth] %d welded particles had source vertices disagreeing on cloth_weight (range > 0.05 in channel %d). Took the most-pinned (min cw) value so painted pins don't get overridden by unpainted siblings — but this means your brush coverage is incomplete; clean up the paint in Blender for crisper anchored regions." % [cw_disagreements, cloth_weight_channel])

	for w in _particle_count:
		var sv: int = _first_sv[w]
		var welded_pos: Vector3 = _welded_positions[w]
		var ref_pos: Vector3 = mesh_to_ref * welded_pos

		# cloth_weight is the min across all welded siblings (see above).
		var cw: float = welded_cw_min[w]
		cloth_w_data[w*4+0] = cw
		if cw < 0.01:
			n_anchored += 1
		elif cw > 0.99:
			n_free += 1
		else:
			n_blend += 1

		var inv_mass: float = 0.0 if cw < 0.01 else 1.0
		pos_data[w*4+0] = ref_pos.x; pos_data[w*4+1] = ref_pos.y
		pos_data[w*4+2] = ref_pos.z; pos_data[w*4+3] = inv_mass
		# rest in mesh-local for the skin shader's bone-matrix multiplication.
		# In unrigged mode the skin shader doesn't run; rest stays mesh-local
		# for shader uniformity but is never read.
		rest_data[w*4+0] = welded_pos.x; rest_data[w*4+1] = welded_pos.y
		rest_data[w*4+2] = welded_pos.z; rest_data[w*4+3] = 1.0

		# Bone indices (4 packed as 2× uint32) and weights from first sv.
		# Unrigged: leave bone_idx_bytes zero and bone_w_data zero — the skin
		# pass isn't dispatched so these buffers are never read.
		if _use_skinning:
			var b := sv * 4
			bone_idx_bytes.encode_u32(w*8+0,
				(_src_bones[b]   & 0xFFFF) | ((_src_bones[b+1] & 0xFFFF) << 16))
			bone_idx_bytes.encode_u32(w*8+4,
				(_src_bones[b+2] & 0xFFFF) | ((_src_bones[b+3] & 0xFFFF) << 16))
			bone_w_data[w*4+0] = _src_weights[b+0]
			bone_w_data[w*4+1] = _src_weights[b+1]
			bone_w_data[w*4+2] = _src_weights[b+2]
			bone_w_data[w*4+3] = _src_weights[b+3]

	# Disagreement check across source verts that mapped to the same welded
	# particle. Only meaningful when bone weights actually get used (rigged).
	if _use_skinning:
		for orig_idx in _render_vert_count:
			var w_idx: int = _original_to_welded[orig_idx]
			var sv: int = _first_sv[w_idx]
			if sv == orig_idx:
				continue
			var disagree := false
			for bi in 4:
				if _src_bones[orig_idx * 4 + bi] != _src_bones[sv * 4 + bi]:
					disagree = true; break
				if absf(_src_weights[orig_idx * 4 + bi] - _src_weights[sv * 4 + bi]) > 0.01:
					disagree = true; break
			if disagree:
				disagreements += 1
		if disagreements > 0:
			push_warning("[GPUCloth] %d source vertices disagreed on bone weights with their welded particle's first vertex (took first-vertex weights as authoritative)." % disagreements)

	print("[GPUCloth] Cloth weights → anchored: %d  blend: %d  free: %d" % [n_anchored, n_blend, n_free])

	# Per-channel statistics across raw vertex colors. Helps diagnose "pinning isn't
	# working" cases where you can't tell from the inspector whether the painted
	# weights are even in the .glb, or which channel they actually live in.
	var ch_min := [INF, INF, INF, INF]
	var ch_max := [-INF, -INF, -INF, -INF]
	var ch_sum := [0.0, 0.0, 0.0, 0.0]
	for sc in _src_colors:
		var vals := [sc.r, sc.g, sc.b, sc.a]
		for i in 4:
			ch_min[i] = minf(ch_min[i], vals[i])
			ch_max[i] = maxf(ch_max[i], vals[i])
			ch_sum[i] += vals[i]
	var n: float = float(maxi(_src_colors.size(), 1))
	print("[GPUCloth] Vertex color channels (across %d src verts):" % _src_colors.size())
	print("           R  min=%.3f  max=%.3f  mean=%.3f%s" % [ch_min[0], ch_max[0], ch_sum[0]/n, "  ← active" if cloth_weight_channel == 0 else ""])
	print("           G  min=%.3f  max=%.3f  mean=%.3f%s" % [ch_min[1], ch_max[1], ch_sum[1]/n, "  ← active" if cloth_weight_channel == 1 else ""])
	print("           B  min=%.3f  max=%.3f  mean=%.3f%s" % [ch_min[2], ch_max[2], ch_sum[2]/n, "  ← active" if cloth_weight_channel == 2 else ""])
	print("           A  min=%.3f  max=%.3f  mean=%.3f%s" % [ch_min[3], ch_max[3], ch_sum[3]/n, "  ← active" if cloth_weight_channel == 3 else ""])

	if n_anchored == 0 and pin_targets.is_empty():
		push_warning("[GPUCloth] Zero anchored vertices and no pin_targets — cloth will fall freely.")

	# ── Marker3D pins ──
	# Each marker pins the nearest welded particle to its position. Inverse
	# mass is forced to 0 regardless of the painted cloth_weight value.
	#
	# Rigged: nearest-search runs against CPU-skinned skel-local positions.
	# Skin bind poses that aren't identity-at-rest (common in GLB exports)
	# make raw mesh-to-skel positions diverge from the rendered position, so
	# the pre-skin search picks the wrong particle and the cloth pins to a
	# visually nonsensical spot. Mirrors gizmo skinning convention (see
	# gpu_cloth_solver_gizmo.gd:_redraw) and _pack_bone_matrices's
	# bone_global_pose * bind_pose formula.
	#
	# Unrigged: no skinning to apply — the rest positions (mesh_to_ref * welded)
	# already are the rendered positions, so we just use pos_data directly.
	var pin_search_positions := PackedVector3Array()
	if not pin_targets.is_empty():
		pin_search_positions.resize(_particle_count)
		if _use_skinning:
			var bone_matrices: Array[Transform3D] = []
			bone_matrices.resize(_bind_count)
			for bi in _bind_count:
				var bone_idx: int = _bind_to_bone[bi]
				if bone_idx < 0:
					bone_matrices[bi] = Transform3D.IDENTITY
				else:
					bone_matrices[bi] = _skeleton_node.get_bone_global_pose(bone_idx) * _skin.get_bind_pose(bi)
			for w in _particle_count:
				var sv: int = _first_sv[w]
				var v: Vector3 = _welded_positions[w]
				var skinned := Vector3.ZERO
				var total_w := 0.0
				for k in 4:
					var weight: float = _src_weights[sv * 4 + k]
					if weight <= 0.0001:
						continue
					var bi: int = _src_bones[sv * 4 + k]
					if bi < 0 or bi >= _bind_count:
						continue
					skinned += weight * (bone_matrices[bi] * v)
					total_w += weight
				pin_search_positions[w] = skinned if total_w > 0.0 else (mesh_to_ref * v)
		else:
			for w in _particle_count:
				pin_search_positions[w] = mesh_to_ref * _welded_positions[w]

	_pin_map.clear()
	var ref_inv := _ref_node.global_transform.affine_inverse()
	for path in pin_targets:
		var marker: Node3D = get_node_or_null(path)
		if marker == null:
			push_warning("[GPUCloth] pin_target '%s' not found." % path)
			continue
		var marker_ref_pos: Vector3 = ref_inv * marker.global_position
		var best_idx := 0; var best_d := INF
		for w in _particle_count:
			var d: float = marker_ref_pos.distance_squared_to(pin_search_positions[w])
			if d < best_d:
				best_d = d; best_idx = w
		pos_data[best_idx*4+3] = 0.0
		_pin_map.append({marker = marker, particle_idx = best_idx, smoothed_pos = marker_ref_pos})
	_has_anchors = enable_fishing_line and not _pin_map.is_empty()
	print("[GPUCloth] Marker pins: %d  fishing-line enabled: %s" % [_pin_map.size(), _has_anchors])

	# ── Constraints (welded-space topology, structural + bending) ──
	# Rest distances must be measured in the simulation's reference frame, not
	# mesh-local. If the target MeshInstance3D has a non-identity scale on its
	# transform (or sits under a parent with scale), simulated positions =
	# mesh_to_ref * welded are scaled relative to mesh-local. Computing rest in
	# mesh-local then trying to solve in ref-local makes the constraint solver
	# inject energy every iteration trying to "stretch" the cloth back to its
	# pre-scaled rest size — the cloth blows up even with zero forces.
	var con_data := _build_mesh_constraints(mesh_to_ref)
	_constraint_count = con_data.size() / 4
	print("[GPUCloth] Constraints: %d in %d groups" % [_constraint_count, _constraint_groups.size()])

	# ── Discover colliders ──
	_colliders.clear()
	if not collider_targets.is_empty():
		for path in collider_targets:
			var node: Node = get_node_or_null(path)
			if node is GPUClothCollider:
				_colliders.append(node)
			else:
				push_warning("[GPUCloth] collider_target '%s' not found or not GPUClothCollider." % path)
	else:
		# Auto-scan: skeleton tree when rigged (colliders typically live on
		# BoneAttachment3D), self when unrigged (collider expected as solver child).
		_find_colliders_recursive(_skeleton_node if _use_skinning else self)

	# ── Auto-collider generation from body_mesh ──
	_auto_colliders.clear()
	_auto_spheres.clear()
	_collider_tris.clear()
	if auto_collider_lod > 0 or body_sphere_lod > 0:
		if not _use_skinning:
			push_warning("[GPUCloth] auto_collider_lod / body_sphere_lod is set but the solver is in unrigged mode (no skeleton). Body-derived colliders require a skeleton; ignoring.")
		else:
			_build_auto_colliders()
	if body_collider_voxel_resolution > 0 and not body_mesh.is_empty():
		if not _use_skinning:
			push_warning("[GPUCloth] body_collider_voxel_resolution > 0 but the solver is in unrigged mode. Triangle mesh collider requires a skeleton; ignoring.")
		else:
			_build_collider_mesh()

	_collider_count = _colliders.size() + _auto_colliders.size() + _auto_spheres.size()
	print("[GPUCloth] Colliders: %d manual + %d auto-capsule + %d body-sphere = %d total, plus %d mesh-collider tris" % [
		_colliders.size(), _auto_colliders.size(), _auto_spheres.size(), _collider_count, _collider_tris.size()])

	# ── Welded-space adjacency (Hazard 1) ──
	# Translates render-vert indices through _original_to_welded[] before
	# bucketing, so the normal accumulator in cloth_output.glsl operates in
	# welded space (matching positions[]).
	var adj := _build_adjacency()

	# GPU index buffer for cloth_normals.glsl uses welded indices too
	# (positions[] is welded-indexed, so cross(positions[i1]-positions[i0], ...)
	# would be wrong if indices were render-vert).
	_welded_indices = PackedInt32Array()
	_welded_indices.resize(_src_indices.size())
	for i in _src_indices.size():
		_welded_indices[i] = _original_to_welded[_src_indices[i]]

	# Peer-cloth collision proxy: voxel-cluster welded particles in rest space
	# to a sparse representative subset, then remap _welded_indices through that
	# subset to produce a much smaller triangle list. Only used by *peers*
	# binding our mesh; our own simulation is unaffected.
	_peer_proxy_indices = _build_peer_proxy_indices()
	_peer_proxy_tri_count = _peer_proxy_indices.size() / 3

	# ── Texture dimensions ──
	# Two output textures, sized to welded particle count. One lookup texture,
	# sized to the RAW render-vert count (full mesh, not cloth-filtered) so the
	# vertex shader's VERTEX_ID lookup stays in range for any surface — even
	# non-cloth surfaces don't crash on out-of-bounds samples (those entries
	# just hold 0 and are never read because their surfaces don't get the cloth
	# shader override).
	_tex_w = mini(_particle_count, 4096)
	_tex_h = ceili(float(_particle_count) / float(_tex_w))
	_render_tex_w = mini(_raw_render_count, 4096)
	_render_tex_h = ceili(float(_raw_render_count) / float(_render_tex_w))
	print("[GPUCloth] Output texture: %dx%d (welded)  Lookup: %dx%d (raw render)" \
		% [_tex_w, _tex_h, _render_tex_w, _render_tex_h])

	# Welded-index lookup payload — RGBA32F (only .r used) for sampler2D parity.
	# Stored as float; cast back to int in the vertex shader. Indices < 16M are
	# representable exactly in f32, and we cap particle count at 4096*4096=16M.
	# Cloth render verts get their welded particle index; non-cloth verts get 0
	# (in-range, never sampled because their surfaces aren't cloth-shaded).
	var lookup_data := PackedFloat32Array()
	lookup_data.resize(_render_tex_w * _render_tex_h * 4)  # RGBA, only .r used
	for raw_i in _raw_render_count:
		var f_i: int = _raw_to_filtered_lookup[raw_i]
		if f_i >= 0:
			lookup_data[raw_i * 4 + 0] = float(_original_to_welded[f_i])
	# Trailing tail (when render_vert_count doesn't fill the last row) stays zero —
	# never sampled.

	# ── Texture2DRD wrappers (RIDs assigned on render thread) ──
	_positions_tex      = Texture2DRD.new()
	_normals_tex        = Texture2DRD.new()
	_welded_index_tex   = Texture2DRD.new()

	# ── Fishing-line bindings ──
	# K bindings per particle, each (anchor_idx, max_dist, weight, pad). Anchors
	# are EXPLICITLY Marker3D-pinned particles only (NOT every inv_mass=0
	# particle) — including skin-anchored particles would weld free particles to
	# the rest pose. v2.x lesson preserved.
	var binding_data := _build_bindings(pos_data, bindings_per_particle) if _has_anchors else PackedFloat32Array()

	# ── Shader material wiring ──
	# Phase 2 contract: surface material MUST use cloth_surface_textured.gdshader
	# (or a derivative that exposes the same `gpu_driven` / `positions_tex` /
	# `normals_tex` / `welded_index_tex` / `tex_width` / `render_tex_width` /
	# `skel_to_mesh_transform` uniforms). Anything else — StandardMaterial3D,
	# the v2.x procedural cloth_surface.gdshader, custom user shaders — has no
	# vertex hook reading the simulated positions, so the cloth renders as a
	# normal skinned mesh and the simulation is invisible. Force-replace and
	# warn loudly. Phase 4 will adapt the procedural fabric shader to be
	# v3-compatible so users can opt back in.
	# Shader compat check: a material is v3-compatible if its shader sources
	# from one of the two plugin-provided shaders that have the texelFetch
	# vertex hook. cloth_surface.gdshader is the procedural fabric (lava /
	# silk / linen); cloth_surface_textured.gdshader is the minimal PBR
	# passthrough. Both expose the same gpu_driven / positions_tex /
	# normals_tex / welded_index_tex / tex_width / render_tex_width /
	# skel_to_mesh_transform uniforms — the solver can wire either.
	#
	# Material precedence:
	#   1. cloth_material is a v3-compatible ShaderMaterial → duplicate and use.
	#   2. cloth_material is incompatible (warn) OR null OR StandardMaterial3D:
	#      fall through to a fresh cloth_surface_textured.
	#   3. If cloth_material is null AND the mesh's intrinsic surface material
	#      is a StandardMaterial3D, auto-port its PBR knobs (albedo texture +
	#      tint, roughness/metallic scalars and maps, normal map, AO map) so
	#      the imported asset's look survives the substrate swap. Skipped when
	#      the user explicitly assigned cloth_material — they own the look.
	var v3_paths: Array[String] = [
		_plugin_dir + "/shaders/cloth_surface_textured.gdshader",
		_plugin_dir + "/shaders/cloth_surface.gdshader",
	]
	var fallback_path: String = v3_paths[0]
	var base_mat: ShaderMaterial = null
	var port_source: StandardMaterial3D = null

	if cloth_material is ShaderMaterial:
		var cand := cloth_material as ShaderMaterial
		if cand.shader and cand.shader.resource_path in v3_paths:
			base_mat = cand
		else:
			push_warning("[GPUCloth] cloth_material's shader is not v3-compatible; force-replacing with cloth_surface_textured. Use cloth_surface.gdshader or cloth_surface_textured.gdshader to keep your shader_parameter assignments. (Auto-port skipped because cloth_material was explicitly assigned.)")
	elif cloth_material == null:
		var existing := _mesh_instance_node.get_active_material(0)
		if existing is ShaderMaterial:
			var ex_sh := existing as ShaderMaterial
			if ex_sh.shader and ex_sh.shader.resource_path in v3_paths:
				base_mat = ex_sh
		elif existing is StandardMaterial3D:
			port_source = existing as StandardMaterial3D
	# else cloth_material is StandardMaterial3D or some other type — user
	# explicitly assigned it, so we don't second-guess by porting from the mesh.

	if base_mat:
		_surf_mat = base_mat.duplicate() as ShaderMaterial
	else:
		_surf_mat = ShaderMaterial.new()
		_surf_mat.shader = load(fallback_path)
		if port_source:
			_port_standard_material(_surf_mat, port_source)

	# Apply cloth shader only to the surfaces identified as cloth above. Surfaces
	# without any free verts (body, hair, pole, etc.) keep their authored
	# materials and render natively — Godot's normal skinning handles them.
	var native_surfaces := PackedInt32Array()
	for rng in surface_ranges:
		var s: int = rng.src_surface
		if cloth_surface_idxs.has(s):
			_mesh_instance_node.set_surface_override_material(s, _surf_mat)
		else:
			native_surfaces.append(s)
	print("[GPUCloth] Cloth shader applied to surface(s): %s" % str(cloth_surface_idxs))
	if not native_surfaces.is_empty():
		print("[GPUCloth] Surface(s) left with authored materials: %s" % str(native_surfaces))
	_surf_mat.set_shader_parameter("tex_width",              _tex_w)
	_surf_mat.set_shader_parameter("render_tex_width",       _render_tex_w)
	_surf_mat.set_shader_parameter("skel_to_mesh_transform", mesh_to_ref.affine_inverse())
	_surf_mat.set_shader_parameter("gpu_driven",             true)
	_surf_mat.set_shader_parameter("positions_tex",          _positions_tex)
	_surf_mat.set_shader_parameter("normals_tex",            _normals_tex)
	_surf_mat.set_shader_parameter("welded_index_tex",       _welded_index_tex)
	_surf_mat.set_shader_parameter("render_offset",          cloth_render_offset)

	_mesh_instance_node.extra_cull_margin = 10.0

	# ── Push-constant scaffolding ──
	_skin_push = PackedByteArray(); _skin_push.resize(64)
	_skin_push.encode_u32(0, _particle_count)
	_skin_push.encode_u32(4, _bind_count)

	# 96 bytes: original 80-byte PBD layout + 16 bytes of tail holding gravity_y,
	# gravity_z, and 2 pads. Predict reads vec3(gravity_x@4, gravity_y@80,
	# gravity_z@84); solve/update/collide declare the same tail as pads.
	_pbd_push = PackedByteArray(); _pbd_push.resize(96)

	_output_push = PackedByteArray(); _output_push.resize(16)
	_output_push.encode_u32(0, _particle_count)
	_output_push.encode_u32(4, _tex_w)

	_fishing_push = PackedByteArray(); _fishing_push.resize(16)
	_fishing_push.encode_u32(0, _particle_count)
	_fishing_push.encode_u32(4, bindings_per_particle)

	_pin_override_push = PackedByteArray(); _pin_override_push.resize(16)
	_pin_override_push.encode_u32(0, _pin_map.size())

	_skin_collide_push = PackedByteArray(); _skin_collide_push.resize(16)
	_skin_collide_push.encode_u32(0, _particle_count)
	# collider_count written per-frame in _gpu_do_simulate (so it can react to
	# colliders being toggled on/off at runtime, e.g., via _collider_count drift)

	# Skinned mesh collider push constant and per-frame skinned-vert byte buffer.
	# 3 vec4 per triangle = 48 bytes per triangle. Reused each frame.
	if _collider_tris.size() > 0:
		_collide_tris_push = PackedByteArray(); _collide_tris_push.resize(16)
		_collide_tris_push.encode_u32(0, _particle_count)
		_collide_tris_push.encode_u32(4, _collider_tris.size())
		_collide_tris_push.encode_float(8, body_collider_thickness)
		_collide_tris_push.encode_float(12, collider_friction)
		_collider_tri_bytes = PackedByteArray()
		_collider_tri_bytes.resize(_collider_tris.size() * 48)

	# Reusable per-frame pin overrides bytes (16 B per pin)
	_pin_overrides_bytes = PackedByteArray()
	_pin_overrides_bytes.resize(maxi(_pin_map.size(), 1) * 16)
	_pack_pin_overrides_into(_pin_overrides_bytes)

	# ── Pack init data and queue render-thread initialization ──
	var init_data := {
		"pos_bytes":         pos_data.to_byte_array(),
		"rest_bytes":        rest_data.to_byte_array(),
		"vel_bytes":         PackedByteArray(),
		"con_bytes":         con_data.to_byte_array(),
		"bone_w_bytes":      bone_w_data.to_byte_array(),
		"cloth_w_bytes":     cloth_w_data.to_byte_array(),
		"bone_idx_bytes":    bone_idx_bytes,
		"bone_mat_bytes":    _pack_bone_matrices(),
		"col_bytes":         _pack_colliders(),
		"idx_bytes":         _pack_indices_uint(_welded_indices),
		"peer_proxy_idx_bytes": _pack_indices_uint(_peer_proxy_indices),
		"adj_counts_bytes":  adj.counts.to_byte_array(),
		"adj_offsets_bytes": adj.offsets.to_byte_array(),
		"adj_list_bytes":    adj.list.to_byte_array(),
		"lookup_bytes":      lookup_data.to_byte_array(),
		"binding_bytes":     binding_data.to_byte_array(),
		"pin_override_bytes": _pin_overrides_bytes.duplicate(),
	}
	init_data["vel_bytes"].resize(_particle_count * 16)

	RenderingServer.call_on_render_thread(_gpu_do_init.bind(init_data))
	print("[GPUCloth] GPU init queued on render thread.")

	_prev_skel_world_pos   = _ref_node.global_position
	_prev_skel_world_basis = _ref_node.global_transform.basis

	# Stash a CPU-side copy of cloth_weights for debug coloring (avoids a second
	# GPU readback). Same layout as cloth_w_data: vec4 per particle, .x is the
	# weight. We just need the .x values.
	_debug_cloth_weights = PackedFloat32Array()
	_debug_cloth_weights.resize(_particle_count)
	for w_idx in _particle_count:
		_debug_cloth_weights[w_idx] = cloth_w_data[w_idx * 4]

	print("[GPUCloth] ── CPU initialization complete ───────────────────────────")


# ---------------------------------------------------------------------------
#  GPU init (render thread)
# ---------------------------------------------------------------------------

func _gpu_do_init(init_data: Dictionary) -> void:
	_rd = RenderingServer.get_rendering_device()

	var pos_bytes:          PackedByteArray = init_data["pos_bytes"]
	var rest_bytes:         PackedByteArray = init_data["rest_bytes"]
	var vel_bytes:          PackedByteArray = init_data["vel_bytes"]
	var con_bytes:          PackedByteArray = init_data["con_bytes"]
	var bone_w_bytes:       PackedByteArray = init_data["bone_w_bytes"]
	var cloth_w_bytes:      PackedByteArray = init_data["cloth_w_bytes"]
	var bone_idx_bytes:     PackedByteArray = init_data["bone_idx_bytes"]
	var bone_mat_bytes:     PackedByteArray = init_data["bone_mat_bytes"]
	var col_bytes:          PackedByteArray = init_data["col_bytes"]
	var idx_bytes:          PackedByteArray = init_data["idx_bytes"]
	var peer_proxy_idx_bytes: PackedByteArray = init_data["peer_proxy_idx_bytes"]
	var adj_counts_bytes:   PackedByteArray = init_data["adj_counts_bytes"]
	var adj_offsets_bytes:  PackedByteArray = init_data["adj_offsets_bytes"]
	var adj_list_bytes:     PackedByteArray = init_data["adj_list_bytes"]
	var lookup_bytes:       PackedByteArray = init_data["lookup_bytes"]
	var binding_bytes:      PackedByteArray = init_data["binding_bytes"]
	var pin_override_bytes: PackedByteArray = init_data["pin_override_bytes"]

	# ── Storage buffers ──
	_positions_buffer         = _rd.storage_buffer_create(pos_bytes.size(),       pos_bytes)
	_predicted_buffer         = _rd.storage_buffer_create(pos_bytes.size(),       pos_bytes)
	_velocities_buffer        = _rd.storage_buffer_create(vel_bytes.size(),       vel_bytes)
	_constraints_buffer       = _rd.storage_buffer_create(max(con_bytes.size(), 64), con_bytes)
	# XPBD lambda buffer: one float per constraint. Initial state irrelevant —
	# iter 0 of every substep resets via the constraint_offset MSB flag.
	var lambda_init_bytes := PackedByteArray()
	lambda_init_bytes.resize(max(_constraint_count * 4, 16))
	_lambda_buffer            = _rd.storage_buffer_create(lambda_init_bytes.size(), lambda_init_bytes)
	_colliders_buffer         = _rd.storage_buffer_create(max(col_bytes.size(), 64), col_bytes)
	_rest_positions_buffer    = _rd.storage_buffer_create(rest_bytes.size(),      rest_bytes)
	_bone_indices_buffer      = _rd.storage_buffer_create(bone_idx_bytes.size(),  bone_idx_bytes)
	_bone_weights_skin_buffer = _rd.storage_buffer_create(bone_w_bytes.size(),    bone_w_bytes)
	_bone_transforms_buffer   = _rd.storage_buffer_create(max(bone_mat_bytes.size(), 64), bone_mat_bytes)
	_cloth_weights_buffer     = _rd.storage_buffer_create(cloth_w_bytes.size(),   cloth_w_bytes)
	_skinned_targets_buffer   = _rd.storage_buffer_create(pos_bytes.size(),       pos_bytes)

	if _collider_tris.size() > 0:
		_collider_tri_buffer  = _rd.storage_buffer_create(max(_collider_tri_bytes.size(), 64))

	_face_normals_buffer      = _rd.storage_buffer_create(max(_tri_count * 16, 64))
	_indices_gpu_buffer       = _rd.storage_buffer_create(idx_bytes.size(),       idx_bytes)
	# Always create the proxy buffer (even at size 0 → uses _indices_gpu_buffer
	# fallback in _ensure_peer_uniform_sets). Sized to whatever the rest-space
	# voxel decimation produced.
	if _peer_proxy_tri_count > 0:
		_peer_proxy_indices_buffer = _rd.storage_buffer_create(peer_proxy_idx_bytes.size(), peer_proxy_idx_bytes)
	_vert_tri_counts_buffer   = _rd.storage_buffer_create(adj_counts_bytes.size(),  adj_counts_bytes)
	_vert_tri_offsets_buffer  = _rd.storage_buffer_create(adj_offsets_bytes.size(), adj_offsets_bytes)
	_vert_tri_list_buffer     = _rd.storage_buffer_create(max(adj_list_bytes.size(), 16), adj_list_bytes)

	if _has_anchors:
		_bindings_buffer       = _rd.storage_buffer_create(max(binding_bytes.size(), 16), binding_bytes)
		_pin_overrides_buffer  = _rd.storage_buffer_create(max(pin_override_bytes.size(), 16), pin_override_bytes)

	# ── Output storage images ──
	var fmt := RDTextureFormat.new()
	fmt.format     = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.width      = _tex_w
	fmt.height     = _tex_h
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
					  RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
					  RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)

	_positions_img_rid = _rd.texture_create(fmt, RDTextureView.new())
	_normals_img_rid   = _rd.texture_create(fmt, RDTextureView.new())

	_positions_tex.texture_rd_rid = _positions_img_rid
	_normals_tex.texture_rd_rid   = _normals_img_rid

	# Welded-index lookup: same format, sized to render-vert count. Static —
	# uploaded once at init via texture_update, never written by compute.
	var lookup_fmt := RDTextureFormat.new()
	lookup_fmt.format     = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	lookup_fmt.width      = _render_tex_w
	lookup_fmt.height     = _render_tex_h
	lookup_fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
							 RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)
	_welded_index_lookup_rid = _rd.texture_create(lookup_fmt, RDTextureView.new())
	_rd.texture_update(_welded_index_lookup_rid, 0, lookup_bytes)
	_welded_index_tex.texture_rd_rid = _welded_index_lookup_rid

	# ── Shaders ──
	_skin_shader        = _load_shader(_plugin_dir + "/shaders/compute/cloth_skin.glsl")
	_predict_shader     = _load_shader(_plugin_dir + "/shaders/compute/cloth_predict.glsl")
	_solve_shader       = _load_shader(_plugin_dir + "/shaders/compute/cloth_solve.glsl")
	_update_shader      = _load_shader(_plugin_dir + "/shaders/compute/cloth_update.glsl")
	_collide_shader     = _load_shader(_plugin_dir + "/shaders/compute/cloth_collide.glsl")
	_warm_start_shader  = _load_shader(_plugin_dir + "/shaders/compute/cloth_warm_start.glsl")
	_normals_shader     = _load_shader(_plugin_dir + "/shaders/compute/cloth_normals.glsl")
	_output_shader      = _load_shader(_plugin_dir + "/shaders/compute/cloth_output.glsl")
	_skin_collide_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_skin_collide.glsl")
	if _collider_tris.size() > 0:
		_collide_tris_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_collide_triangles.glsl")
		_skin_collide_tris_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_skin_collide_triangles.glsl")
	# Peer collide shader doubles as the self-collide shader (is_self flag in
	# the push constant switches behavior), so load it whenever either feature
	# is on. The sanitizer is peers-only — no need for self-sanitization since
	# skinned_targets aren't naturally inside the cloth's own proxy.
	if not peer_cloth_solvers.is_empty() or self_collide:
		_peer_collide_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_collide_peer.glsl")
	if not peer_cloth_solvers.is_empty():
		_peer_skin_collide_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_skin_collide_peer.glsl")
	if _has_anchors:
		_fishing_shader      = _load_shader(_plugin_dir + "/shaders/compute/cloth_fishing.glsl")
		_pin_override_shader = _load_shader(_plugin_dir + "/shaders/compute/cloth_pin_override.glsl")

	# ── Pipelines ──
	_skin_pipeline       = _rd.compute_pipeline_create(_skin_shader)
	_predict_pipeline    = _rd.compute_pipeline_create(_predict_shader)
	_solve_pipeline      = _rd.compute_pipeline_create(_solve_shader)
	_update_pipeline     = _rd.compute_pipeline_create(_update_shader)
	_collide_pipeline    = _rd.compute_pipeline_create(_collide_shader)
	_warm_start_pipeline = _rd.compute_pipeline_create(_warm_start_shader)
	_normals_pipeline    = _rd.compute_pipeline_create(_normals_shader)
	_output_pipeline     = _rd.compute_pipeline_create(_output_shader)
	_skin_collide_pipeline = _rd.compute_pipeline_create(_skin_collide_shader)
	if _collider_tris.size() > 0:
		_collide_tris_pipeline = _rd.compute_pipeline_create(_collide_tris_shader)
		_skin_collide_tris_pipeline = _rd.compute_pipeline_create(_skin_collide_tris_shader)
	if not peer_cloth_solvers.is_empty() or self_collide:
		_peer_collide_pipeline = _rd.compute_pipeline_create(_peer_collide_shader)
	if not peer_cloth_solvers.is_empty():
		_peer_skin_collide_pipeline = _rd.compute_pipeline_create(_peer_skin_collide_shader)
	if _has_anchors:
		_fishing_pipeline      = _rd.compute_pipeline_create(_fishing_shader)
		_pin_override_pipeline = _rd.compute_pipeline_create(_pin_override_shader)

	# ── Uniform sets ──
	_skin_uniform_set = _create_uniform_set(_skin_shader, [
		_make_uniform(0, _rest_positions_buffer),
		_make_uniform(1, _bone_indices_buffer),
		_make_uniform(2, _bone_weights_skin_buffer),
		_make_uniform(3, _bone_transforms_buffer),
		_make_uniform(4, _skinned_targets_buffer),
	])
	_predict_uniform_set = _create_uniform_set(_predict_shader, [
		_make_uniform(0, _positions_buffer),
		_make_uniform(1, _predicted_buffer),
		_make_uniform(2, _velocities_buffer),
		_make_uniform(5, _skinned_targets_buffer),
	])
	_solve_uniform_set = _create_uniform_set(_solve_shader, [
		_make_uniform(1, _predicted_buffer),
		_make_uniform(3, _constraints_buffer),
		_make_uniform(8, _lambda_buffer),
	])
	_update_uniform_set = _create_uniform_set(_update_shader, [
		_make_uniform(0, _positions_buffer),
		_make_uniform(1, _predicted_buffer),
		_make_uniform(2, _velocities_buffer),
		_make_uniform(5, _cloth_weights_buffer),
		_make_uniform(6, _skinned_targets_buffer),
	])
	_collide_uniform_set = _create_uniform_set(_collide_shader, [
		_make_uniform(0, _positions_buffer),         # substep-start pos for friction tangent
		_make_uniform(1, _predicted_buffer),
		_make_uniform(4, _colliders_buffer),
		_make_uniform(5, _skinned_targets_buffer),
	])
	_warm_start_uniform_set = _create_uniform_set(_warm_start_shader, [
		_make_uniform(0, _positions_buffer),
		_make_uniform(1, _predicted_buffer),
		_make_uniform(2, _velocities_buffer),
		_make_uniform(4, _skinned_targets_buffer),
	])
	_normals_uniform_set = _create_uniform_set(_normals_shader, [
		_make_uniform(0, _positions_buffer),
		_make_uniform(1, _indices_gpu_buffer),
		_make_uniform(2, _face_normals_buffer),
	])
	_output_uniform_set = _create_uniform_set(_output_shader, [
		_make_uniform(0, _positions_buffer),
		_make_uniform(1, _face_normals_buffer),
		_make_uniform(2, _vert_tri_counts_buffer),
		_make_uniform(3, _vert_tri_offsets_buffer),
		_make_uniform(4, _vert_tri_list_buffer),
		_make_image_uniform(5, _positions_img_rid),
		_make_image_uniform(6, _normals_img_rid),
	])
	if _has_anchors:
		_fishing_uniform_set = _create_uniform_set(_fishing_shader, [
			_make_uniform(1, _predicted_buffer),
			_make_uniform(7, _bindings_buffer),
		])
		_pin_override_uniform_set = _create_uniform_set(_pin_override_shader, [
			_make_uniform(0, _skinned_targets_buffer),
			_make_uniform(1, _pin_overrides_buffer),
		])

	# Sanitizer uniform set: read+write skinned_targets, readonly colliders.
	_skin_collide_uniform_set = _create_uniform_set(_skin_collide_shader, [
		_make_uniform(0, _skinned_targets_buffer),
		_make_uniform(1, _colliders_buffer),
	])

	# Skinned mesh collider uniform set: positions (RO, substep-start, used for
	# friction tangent calc), predicted (RW), skinned tri verts (RO),
	# cloth_weights (RO, per-particle thickness multiplier).
	if _collider_tris.size() > 0:
		_collide_tris_uniform_set = _create_uniform_set(_collide_tris_shader, [
			_make_uniform(0, _positions_buffer),
			_make_uniform(1, _predicted_buffer),
			_make_uniform(4, _collider_tri_buffer),
			_make_uniform(5, _cloth_weights_buffer),
		])
		# Triangle-collider sanitizer uniform set: skinned_targets (RW) + tri verts (RO).
		_skin_collide_tris_uniform_set = _create_uniform_set(_skin_collide_tris_shader, [
			_make_uniform(0, _skinned_targets_buffer),
			_make_uniform(1, _collider_tri_buffer),
		])

	# Self-collide uniform set — eagerly built (depends only on our own
	# buffers). Skipped if no proxy was built (peer_collider_voxel_resolution
	# == 0) since there's no triangle list to push against.
	if self_collide and _peer_proxy_tri_count > 0:
		_self_collide_uniform_set = _create_uniform_set(_peer_collide_shader, [
			_make_uniform(0, _positions_buffer),         # substep-start (RO, friction)
			_make_uniform(1, _predicted_buffer),         # RW
			_make_uniform(2, _positions_buffer),         # "peer" current = ours
			_make_uniform(3, _peer_proxy_indices_buffer),# our proxy tris
			_make_uniform(5, _cloth_weights_buffer),     # per-particle thickness factor
		])
		_self_collide_push = PackedByteArray(); _self_collide_push.resize(32)
		_self_collide_push.encode_u32(0, _particle_count)
		_self_collide_push.encode_u32(4, _peer_proxy_tri_count)
		_self_collide_push.encode_float(8, self_collide_thickness)
		_self_collide_push.encode_float(12, collider_friction)
		_self_collide_push.encode_u32(16, 1)             # is_self = 1
		print("[GPUCloth] Self-collide wired: %d proxy tris, thickness %.4f m" % [_peer_proxy_tri_count, self_collide_thickness])
	elif self_collide:
		push_warning("[GPUCloth] self_collide is enabled but peer_collider_voxel_resolution = 0 (no proxy mesh built) — self-collision disabled. Set peer_collider_voxel_resolution > 0.")

	_gpu_init_done = true
	# Peer uniform-set creation is deferred to _ensure_peer_uniform_sets, called
	# lazily from _gpu_do_simulate on first use — the peer solvers might still
	# be running their own _gpu_do_init at this point, so their buffers won't
	# exist yet. Lazy init lets each solver finish independently.
	print("[GPUCloth] GPU init complete on render thread.")


# ---------------------------------------------------------------------------
#  Warm start (one-shot, render thread)
# ---------------------------------------------------------------------------

func _gpu_do_warm_start() -> void:
	var groups := ceili(float(_particle_count) / 64.0)
	var cl := _rd.compute_list_begin()

	# SKIN — produces skinned_targets[] for the current pose. Skipped in
	# unrigged mode: skinned_targets was pre-populated at GPU init from
	# pos_bytes (rest positions in ref-local) and never needs to change.
	if _use_skinning:
		_rd.compute_list_bind_compute_pipeline(cl, _skin_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _skin_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, _skin_push, 64)
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	# PIN OVERRIDE — overwrite skinned_targets for marker-pinned slots.
	if _has_anchors and _pin_map.size() > 0:
		var pin_groups := ceili(float(_pin_map.size()) / 64.0)
		_rd.compute_list_bind_compute_pipeline(cl, _pin_override_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _pin_override_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, _pin_override_push, 16)
		_rd.compute_list_dispatch(cl, pin_groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	# SANITIZE — push any skinned_target that's inside a collider back out to
	# the collider surface. Same logic as COLLIDE but operates on the anchor
	# positions (skinned_targets), not the simulated particles. Ensures the
	# warm-start positions don't begin inside the body's collider volumes.
	if _collider_count > 0:
		_skin_collide_push.encode_u32(4, _collider_count)
		_rd.compute_list_bind_compute_pipeline(cl, _skin_collide_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _skin_collide_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, _skin_collide_push, 16)
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	# SANITIZE (mesh) — same idea but pushes skinned_targets out of the body's
	# triangle proxy. Critical to prevent rest-jitter when collide_triangles
	# pushes cloth particles outward each iter while UPDATE pulls them back to
	# skinned_targets that sit inside the body surface.
	if _collider_tris.size() > 0:
		_rd.compute_list_bind_compute_pipeline(cl, _skin_collide_tris_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _skin_collide_tris_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, _collide_tris_push, 16)
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	# SANITIZE (peer cloth) — push skinned_targets out of any peer cloth's
	# current geometry. Same fix as body sanitizer but for cloth-on-cloth
	# overlap (shirt skinned_targets typically sit inside pants where the
	# meshes were authored to drape together).
	if _peers.size() > 0:
		_rd.compute_list_bind_compute_pipeline(cl, _peer_skin_collide_pipeline)
		for p in _peers:
			_rd.compute_list_bind_uniform_set(cl, p.sanitize_uniform_set, 0)
			_rd.compute_list_set_push_constant(cl, p.push, 16)
			_rd.compute_list_dispatch(cl, groups, 1, 1)
			_rd.compute_list_add_barrier(cl)

	# WARM START — copy skinned_targets → positions/predicted, zero velocities.
	var wp := PackedByteArray(); wp.resize(16)
	wp.encode_u32(0, _particle_count)
	_rd.compute_list_bind_compute_pipeline(cl, _warm_start_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _warm_start_uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, wp, 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_add_barrier(cl)

	_dispatch_output_passes(cl, groups, -1.0 if flip_normals else 1.0)

	_rd.compute_list_end()
	print("[GPUCloth] Warm start complete.")


# ---------------------------------------------------------------------------
#  Per-frame simulate (game thread)
# ---------------------------------------------------------------------------

func _simulate(delta: float) -> void:
	var sub_dt := delta / float(substeps)

	var bone_bytes := _pack_bone_matrices()
	var col_bytes  := _pack_colliders() if _collider_count > 0 else PackedByteArray()
	var tri_bytes  := _pack_collider_tris() if _collider_tris.size() > 0 else PackedByteArray()

	# Marker3D pin position smoothing — same as v2.x. Smooths a step change in
	# marker position over multiple frames so the cloth doesn't snap.
	var pin_lerp: float = clampf(pin_smooth_speed * delta, 0.0, 1.0)
	var ref_inv := _ref_node.global_transform.affine_inverse()
	if _has_anchors:
		for pin in _pin_map:
			if not is_instance_valid(pin.marker):
				continue
			var target_pos: Vector3 = ref_inv * pin.marker.global_position
			pin.smoothed_pos = pin.smoothed_pos.lerp(target_pos, pin_lerp)
		_pack_pin_overrides_into(_pin_overrides_bytes)

	# Translation inertia (reference-frame-local). The ref-local positions don't
	# move when the ref node moves in world, so we explicitly subtract the
	# delta from each free particle to make them lag behind. In unrigged mode
	# the ref node is the solver itself — moving the GPUClothSolver in the
	# scene tree produces the same "cape lags behind character" effect.
	var delta_world := _ref_node.global_position - _prev_skel_world_pos
	var delta_local := _ref_node.global_transform.basis.inverse() * delta_world
	var inertia_sub := delta_local * inertia_scale / float(substeps)
	_prev_skel_world_pos = _ref_node.global_position

	# Rotational inertia. Same reference-frame logic — ref-local positions ride
	# with the ref node's rotation; we apply the inverse to make free particles
	# lag. `counter_basis` = current_inverse * previous = "rotate back to where
	# particles were last frame", in ref-local.
	var counter_basis: Basis = (_ref_node.global_transform.basis.inverse() * _prev_skel_world_basis).orthonormalized()
	var q_full: Quaternion = counter_basis.get_rotation_quaternion()
	var q_per_sub: Quaternion = Quaternion.IDENTITY.slerp(q_full, 1.0 / float(substeps))
	q_per_sub = Quaternion.IDENTITY.slerp(q_per_sub, rotational_inertia_scale)
	_prev_skel_world_basis = _ref_node.global_transform.basis

	# Wind (solver-local frame per fork pattern)
	var t   := Time.get_ticks_msec() / 1000.0 * wind_frequency
	var gust := Vector3(
		sin(t * 1.7) + sin(t * 3.1 + 1.3),
		sin(t * 1.3 + 2.0) + sin(t * 2.7 + 0.7),
		sin(t * 2.1 + 4.0) + sin(t * 1.9 + 3.1)) * 0.5
	var eff_wind  := wind + wind.length() * gust * wind_turbulence
	var local_wind := global_transform.basis.inverse() * eff_wind

	# Gravity is authored in world space; transform to ref-local each frame so
	# the cloth sees true world-down regardless of solver/skeleton orientation.
	# Same pattern wind already uses below.
	var local_gravity := _ref_node.global_transform.basis.inverse() * gravity

	# PBD push constant (96 B; layout matches cloth_predict/solve/update/collide).
	# Last 16 bytes (offsets 80-95) hold gravity_y, gravity_z, and 2 pads —
	# predict reads them via vec3(gravity_x@4, gravity_y@80, gravity_z@84).
	_pbd_push.encode_float(0,  sub_dt)
	_pbd_push.encode_float(4,  local_gravity.x)
	_pbd_push.encode_u32(8,    _particle_count)
	_pbd_push.encode_u32(12,   _constraint_count)
	_pbd_push.encode_float(16, damping)
	_pbd_push.encode_float(20, max_speed)
	_pbd_push.encode_u32(24,   _collider_count)
	_pbd_push.encode_u32(28,   0)
	_pbd_push.encode_float(32, inertia_sub.x)
	_pbd_push.encode_float(36, inertia_sub.y)
	_pbd_push.encode_float(40, inertia_sub.z)
	# max_travel hard-clamps each free particle to within cloth_w * max_travel
	# of skinned_targets (cloth_update.glsl). In rigged mode skinned_targets
	# moves with the skeleton, so it's a cape-stays-close-to-body budget. In
	# unrigged mode skinned_targets is the static rest pose populated once at
	# init, so it acts as a per-particle leash to the rest position. Either way
	# the export is meaningful; setting it to 0 disables the clamp entirely.
	_pbd_push.encode_float(44, max_travel_distance)
	_pbd_push.encode_float(48, local_wind.x)
	_pbd_push.encode_float(52, local_wind.y)
	_pbd_push.encode_float(56, local_wind.z)
	_pbd_push.encode_float(60, 1.0 / float(substeps))
	# Rotational counter-rotation quaternion (predict-only; padding for others).
	_pbd_push.encode_float(64, q_per_sub.x)
	_pbd_push.encode_float(68, q_per_sub.y)
	_pbd_push.encode_float(72, q_per_sub.z)
	_pbd_push.encode_float(76, q_per_sub.w)
	# Gravity Y and Z (X is at offset 4); padding for non-predict shaders.
	_pbd_push.encode_float(80, local_gravity.y)
	_pbd_push.encode_float(84, local_gravity.z)
	_pbd_push.encode_float(88, 0.0)
	_pbd_push.encode_float(92, 0.0)

	var push_copy        := _pbd_push.duplicate()
	var pin_bytes_copy   := _pin_overrides_bytes.duplicate() if _has_anchors else PackedByteArray()
	var nflip            := -1.0 if flip_normals else 1.0
	var cap_substeps     := substeps
	var cap_iters        := solver_iterations

	RenderingServer.call_on_render_thread(
		_gpu_do_simulate.bind(bone_bytes, col_bytes, push_copy, pin_bytes_copy,
			tri_bytes, nflip, cap_substeps, cap_iters))


func _gpu_do_simulate(
		bone_bytes:   PackedByteArray,
		col_bytes:    PackedByteArray,
		push:         PackedByteArray,
		pin_bytes:    PackedByteArray,
		tri_bytes:    PackedByteArray,
		nflip:        float,
		p_substeps:   int,
		p_iters:      int) -> void:

	if bone_bytes.size() > 0:
		_rd.buffer_update(_bone_transforms_buffer, 0, bone_bytes.size(), bone_bytes)
	if col_bytes.size() > 0:
		_rd.buffer_update(_colliders_buffer, 0, col_bytes.size(), col_bytes)
	if _has_anchors and pin_bytes.size() > 0:
		_rd.buffer_update(_pin_overrides_buffer, 0, pin_bytes.size(), pin_bytes)
	if tri_bytes.size() > 0:
		_rd.buffer_update(_collider_tri_buffer, 0, tri_bytes.size(), tri_bytes)

	# Wire peer cloth collision lazily — peers may not have finished _gpu_do_init
	# at our own init time, so we retry every frame until they're all ready.
	_ensure_peer_uniform_sets()

	var groups := ceili(float(_particle_count) / 64.0)
	var cl     := _rd.compute_list_begin()

	# SKIN once per frame. Skipped in unrigged mode (skinned_targets is the
	# static rest pose populated at GPU init).
	if _use_skinning:
		_rd.compute_list_bind_compute_pipeline(cl, _skin_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _skin_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, _skin_push, 64)
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	# PIN OVERRIDE — patch marker-pinned slots in skinned_targets
	if _has_anchors and _pin_map.size() > 0:
		var pin_groups := ceili(float(_pin_map.size()) / 64.0)
		_rd.compute_list_bind_compute_pipeline(cl, _pin_override_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _pin_override_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, _pin_override_push, 16)
		_rd.compute_list_dispatch(cl, pin_groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	# SANITIZE — push any skinned_target that's inside a collider out to its
	# surface. Runs ONCE per frame (not per substep) — the bone-skinned target
	# is deterministic per pose, and re-projecting it is just clamping the
	# anchor positions PREDICT and UPDATE will read. Kills rest-jitter and
	# rest-clipping by ensuring the cloth's anchor is always reachable from
	# outside the collider volume.
	if _collider_count > 0:
		_skin_collide_push.encode_u32(4, _collider_count)
		_rd.compute_list_bind_compute_pipeline(cl, _skin_collide_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _skin_collide_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, _skin_collide_push, 16)
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	# SANITIZE (mesh) — same purpose, against the triangle collider.
	if _collider_tris.size() > 0:
		_rd.compute_list_bind_compute_pipeline(cl, _skin_collide_tris_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _skin_collide_tris_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, _collide_tris_push, 16)
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	# SANITIZE (peer cloth) — push skinned_targets out of peer geometry. Kills
	# the cloth-cloth rest-jitter that comes from skinned_targets sitting
	# inside an overlapping peer cloth (shirt anchor inside pants etc.).
	if _peers.size() > 0:
		_rd.compute_list_bind_compute_pipeline(cl, _peer_skin_collide_pipeline)
		for p in _peers:
			_rd.compute_list_bind_uniform_set(cl, p.sanitize_uniform_set, 0)
			_rd.compute_list_set_push_constant(cl, p.push, 16)
			_rd.compute_list_dispatch(cl, groups, 1, 1)
			_rd.compute_list_add_barrier(cl)

	for _s in p_substeps:
		# PREDICT
		_rd.compute_list_bind_compute_pipeline(cl, _predict_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _predict_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, push, 96)
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

		# SOLVE × iterations × graph-colored groups, with COLLIDE inside the
		# iter loop (Hazard 5).
		_rd.compute_list_bind_compute_pipeline(cl, _solve_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _solve_uniform_set, 0)
		for _iter in p_iters:
			# XPBD: reset λ on iter 0 of each substep. The high bit (0x80000000)
			# of constraint_offset signals "this is iter 0 — ignore lambdas[cidx]
			# and treat it as 0 before accumulating." Avoids a separate clear
			# pass at the substep boundary.
			var xpbd_reset_bit: int = 0x80000000 if _iter == 0 else 0
			for grp in _constraint_groups:
				push.encode_u32(12, grp.count)
				push.encode_u32(28, int(grp.offset) | xpbd_reset_bit)
				_rd.compute_list_set_push_constant(cl, push, 96)
				_rd.compute_list_dispatch(cl, ceili(float(grp.count) / 64.0), 1, 1)
				_rd.compute_list_add_barrier(cl)

			if _collider_count > 0:
				push.encode_u32(12, _constraint_count)
				# Offset 28 doubles as the friction μ slot for the primitive
				# collide shader (declared `float friction` there). For solve
				# it's `constraint_offset_packed` — same bytes, two interpretations.
				push.encode_float(28, collider_friction)
				_rd.compute_list_bind_compute_pipeline(cl, _collide_pipeline)
				_rd.compute_list_bind_uniform_set(cl, _collide_uniform_set, 0)
				_rd.compute_list_set_push_constant(cl, push, 96)
				_rd.compute_list_dispatch(cl, groups, 1, 1)
				_rd.compute_list_add_barrier(cl)
				_rd.compute_list_bind_compute_pipeline(cl, _solve_pipeline)
				_rd.compute_list_bind_uniform_set(cl, _solve_uniform_set, 0)

			# Skinned mesh collider — runs in the same iter slot as capsule/box
			# collide so cloth particles get pushed out of body triangles before
			# the next solve iter pulls them back via structural constraints.
			if _collider_tris.size() > 0:
				_rd.compute_list_bind_compute_pipeline(cl, _collide_tris_pipeline)
				_rd.compute_list_bind_uniform_set(cl, _collide_tris_uniform_set, 0)
				_rd.compute_list_set_push_constant(cl, _collide_tris_push, 16)
				_rd.compute_list_dispatch(cl, groups, 1, 1)
				_rd.compute_list_add_barrier(cl)
				_rd.compute_list_bind_compute_pipeline(cl, _solve_pipeline)
				_rd.compute_list_bind_uniform_set(cl, _solve_uniform_set, 0)

			# (peer cloth collision moved out of iter loop — see below)

		# FISHING — hard-clamp predicted[] to within fishing_stretch of each
		# free particle's K-nearest anchor blend. Was previously inside the
		# iter loop (run solver_iterations × substeps times per frame); moved
		# to once per substep because the clamp is a hard inequality, not a
		# soft constraint — running it once after all iters gives a clean
		# final state without burning ~8× the dispatches. Still mid-substep
		# (UPDATE is the substep boundary) so Hazard 5 holds.
		if _has_anchors:
			_rd.compute_list_bind_compute_pipeline(cl, _fishing_pipeline)
			_rd.compute_list_bind_uniform_set(cl, _fishing_uniform_set, 0)
			_rd.compute_list_set_push_constant(cl, _fishing_push, 16)
			_rd.compute_list_dispatch(cl, groups, 1, 1)
			_rd.compute_list_add_barrier(cl)

		# PEER CLOTH-CLOTH — once per substep (was per-iter, 8× cheaper now).
		# Peer cloth deforms slowly compared to a single solver's structural
		# constraints, so per-iter dispatching was overkill — peer geometry
		# barely changes between iters of the same substep. Running once at
		# end of substep gives the final solve state a clean cloth-cloth state
		# without the dispatch tax of running per-iter.
		if _peers.size() > 0:
			_rd.compute_list_bind_compute_pipeline(cl, _peer_collide_pipeline)
			for p in _peers:
				_rd.compute_list_bind_uniform_set(cl, p.uniform_set, 0)
				_rd.compute_list_set_push_constant(cl, p.push, 32)
				_rd.compute_list_dispatch(cl, groups, 1, 1)
				_rd.compute_list_add_barrier(cl)

		# SELF-COLLIDE — same shader as peer collide, our positions + our proxy
		# tris bound on both ends, is_self flag in push constant tells the
		# shader to skip tris where idx is a vert. Runs once per substep at
		# the same cadence as peer collide.
		if _self_collide_uniform_set.is_valid():
			_rd.compute_list_bind_compute_pipeline(cl, _peer_collide_pipeline)
			_rd.compute_list_bind_uniform_set(cl, _self_collide_uniform_set, 0)
			_rd.compute_list_set_push_constant(cl, _self_collide_push, 32)
			_rd.compute_list_dispatch(cl, groups, 1, 1)
			_rd.compute_list_add_barrier(cl)

		# UPDATE — per-substep soft-lerp toward skinned_targets, max_travel clamp.
		push.encode_u32(12, _constraint_count)
		push.encode_u32(28, 0)
		_rd.compute_list_bind_compute_pipeline(cl, _update_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _update_uniform_set, 0)
		_rd.compute_list_set_push_constant(cl, push, 96)
		_rd.compute_list_dispatch(cl, groups, 1, 1)
		_rd.compute_list_add_barrier(cl)

	_dispatch_output_passes(cl, groups, nflip)

	_rd.compute_list_end()


func _dispatch_output_passes(cl: int, groups: int, nflip: float) -> void:
	var tri_groups := ceili(float(_tri_count) / 64.0)

	var np := PackedByteArray(); np.resize(16)
	np.encode_u32(0, _tri_count)
	np.encode_float(4, nflip)

	_rd.compute_list_bind_compute_pipeline(cl, _normals_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _normals_uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, np, 16)
	_rd.compute_list_dispatch(cl, tri_groups, 1, 1)
	_rd.compute_list_add_barrier(cl)

	_rd.compute_list_bind_compute_pipeline(cl, _output_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _output_uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, _output_push, 16)
	_rd.compute_list_dispatch(cl, groups, 1, 1)


# ---------------------------------------------------------------------------
#  Mesh ingestion (port from v2.x:_extract_mesh_data)
# ---------------------------------------------------------------------------

static func extract_mesh_data(mesh: Mesh) -> Dictionary:
	var vertices  := PackedVector3Array()
	var uvs       := PackedVector2Array()
	var colors    := PackedColorArray()
	var indices   := PackedInt32Array()
	var bones     := PackedInt32Array()
	var weights   := PackedFloat32Array()
	# Per-Godot-surface render-vert ranges. Each entry is {src_surface, start, end}
	# where start/end are inclusive/exclusive indices into the aggregated vertices
	# array. Used by the caller to decide per-surface concerns like material
	# overrides (e.g., a pole surface with no free verts shouldn't be wrapped in
	# the cloth shader). Skipped surfaces (non-triangle, empty, etc.) do not appear.
	var surface_ranges: Array[Dictionary] = []

	var has_any_colors := false
	var has_any_bones  := false
	var skipped_surfaces := 0
	var invalid_triangles := 0

	for surface_idx in mesh.get_surface_count():
		if mesh is ArrayMesh:
			var array_mesh := mesh as ArrayMesh
			if array_mesh.surface_get_primitive_type(surface_idx) != Mesh.PRIMITIVE_TRIANGLES:
				skipped_surfaces += 1
				continue

		var arrays: Array = mesh.surface_get_arrays(surface_idx)
		if arrays.size() < Mesh.ARRAY_MAX or arrays[Mesh.ARRAY_VERTEX] == null:
			skipped_surfaces += 1
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			skipped_surfaces += 1
			continue

		# Indices: missing → fall back to identity (one tri per 3 consecutive verts).
		var surface_indices := PackedInt32Array()
		var indices_raw = arrays[Mesh.ARRAY_INDEX]
		if indices_raw == null:
			surface_indices.resize(verts.size())
			for i in verts.size():
				surface_indices[i] = i
		else:
			surface_indices = indices_raw

		var local_indices := PackedInt32Array()
		var tri_count: int = surface_indices.size() / 3
		for tri in tri_count:
			var i0: int = surface_indices[tri*3]
			var i1: int = surface_indices[tri*3+1]
			var i2: int = surface_indices[tri*3+2]
			if i0 < 0 or i0 >= verts.size() or i1 < 0 or i1 >= verts.size() or i2 < 0 or i2 >= verts.size():
				invalid_triangles += 1; continue
			local_indices.append(i0); local_indices.append(i1); local_indices.append(i2)
		if local_indices.is_empty():
			skipped_surfaces += 1; continue

		var base_index: int = vertices.size()
		vertices.append_array(verts)
		surface_ranges.append({
			src_surface = surface_idx,
			start = base_index,
			end = base_index + verts.size(),
		})

		var uvs_raw = arrays[Mesh.ARRAY_TEX_UV]
		if uvs_raw != null and uvs_raw.size() == verts.size():
			uvs.append_array(uvs_raw)
		else:
			var zero_uvs := PackedVector2Array(); zero_uvs.resize(verts.size())
			uvs.append_array(zero_uvs)

		var colors_raw = arrays[Mesh.ARRAY_COLOR]
		if colors_raw != null and colors_raw.size() == verts.size():
			if not has_any_colors:
				colors.resize(base_index)
				colors.fill(Color(0, 0, 0, 0))
				has_any_colors = true
			colors.append_array(colors_raw)
		elif has_any_colors:
			var transparent := PackedColorArray(); transparent.resize(verts.size())
			transparent.fill(Color(0, 0, 0, 0))
			colors.append_array(transparent)

		var bones_raw = arrays[Mesh.ARRAY_BONES]
		var weights_raw = arrays[Mesh.ARRAY_WEIGHTS]
		var has_surface_bones := false
		if bones_raw != null and weights_raw != null and verts.size() > 0:
			var per_vert: int = bones_raw.size() / verts.size()
			if per_vert == 4 and weights_raw.size() == verts.size() * 4:
				has_surface_bones = true
				if not has_any_bones:
					bones.resize(base_index * 4)
					weights.resize(base_index * 4)
					has_any_bones = true
				bones.append_array(bones_raw)
				weights.append_array(weights_raw)
		if not has_surface_bones and has_any_bones:
			var zero_bones := PackedInt32Array(); zero_bones.resize(verts.size() * 4)
			bones.append_array(zero_bones)
			var zero_weights := PackedFloat32Array(); zero_weights.resize(verts.size() * 4)
			weights.append_array(zero_weights)

		for idx in local_indices:
			indices.append(base_index + idx)

	if skipped_surfaces > 0:
		push_warning("[GPUCloth] Skipped %d surface(s) without triangle data." % skipped_surfaces)
	if invalid_triangles > 0:
		push_warning("[GPUCloth] Skipped %d triangle(s) with invalid indices." % invalid_triangles)

	return {
		vertices = vertices,
		uvs = uvs,
		colors = (colors if has_any_colors else PackedColorArray()),
		indices = indices,
		bones = (bones if has_any_bones else PackedInt32Array()),
		weights = (weights if has_any_bones else PackedFloat32Array()),
		surface_ranges = surface_ranges,
	}


# ---------------------------------------------------------------------------
#  Welding (port from v2.x:_weld_vertices) — spatial-hash + neighbor-cell scan
# ---------------------------------------------------------------------------

static func weld_vertices(vertices: PackedVector3Array, epsilon: float) -> Dictionary:
	var eps: float = maxf(epsilon, 1e-8)
	var eps_sq: float = eps * eps
	var inv_eps: float = 1.0 / eps
	var cell_to_welded: Dictionary = {}
	var welded := PackedVector3Array()
	var remap := PackedInt32Array()
	remap.resize(vertices.size())
	for i in vertices.size():
		var v: Vector3 = vertices[i]
		var key := Vector3i(
			int(floor(v.x * inv_eps)),
			int(floor(v.y * inv_eps)),
			int(floor(v.z * inv_eps)))

		var best_idx := -1
		var best_dist_sq := eps_sq
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var nk := Vector3i(key.x + dx, key.y + dy, key.z + dz)
					if not cell_to_welded.has(nk):
						continue
					for cand_idx in cell_to_welded[nk]:
						var dist_sq: float = v.distance_squared_to(welded[cand_idx])
						if dist_sq <= best_dist_sq:
							best_dist_sq = dist_sq
							best_idx = cand_idx

		if best_idx >= 0:
			remap[i] = best_idx
		else:
			var w := welded.size()
			welded.append(v)
			if not cell_to_welded.has(key):
				cell_to_welded[key] = []
			cell_to_welded[key].append(w)
			remap[i] = w
	return {welded_positions = welded, original_to_welded = remap}


# ---------------------------------------------------------------------------
#  Constraint emission (welded-space topology, structural + bending)
# ---------------------------------------------------------------------------

func _build_mesh_constraints(mesh_to_ref: Transform3D) -> PackedFloat32Array:
	# Walk triangles in welded-index space. Each triangle contributes 3
	# structural edges (deduped); each edge shared by exactly 2 faces also
	# contributes a bending constraint between the two non-shared vertices.
	#
	# Rest distances are measured in ref-local — the same frame the simulation
	# runs in. Pre-transform welded positions once so per-edge calls stay cheap.
	var sim_positions := PackedVector3Array(); sim_positions.resize(_particle_count)
	for i in _particle_count:
		sim_positions[i] = mesh_to_ref * _welded_positions[i]

	var edge_rest: Dictionary = {}     # Vector2i(a,b) a<b → rest distance
	var edge_faces: Dictionary = {}    # Vector2i(a,b) a<b → Array[face_idx]
	var faces: Array = []              # face_idx → [w0, w1, w2] welded indices

	var tri_count: int = _src_indices.size() / 3
	for tri in tri_count:
		var i0: int = _original_to_welded[_src_indices[tri*3]]
		var i1: int = _original_to_welded[_src_indices[tri*3+1]]
		var i2: int = _original_to_welded[_src_indices[tri*3+2]]
		# Skip triangles that collapsed to a line/point post-welding.
		if i0 == i1 or i1 == i2 or i0 == i2:
			continue
		var face_idx: int = faces.size()
		faces.append([i0, i1, i2])
		var pairs: Array = [[i0, i1], [i1, i2], [i2, i0]]
		for pair in pairs:
			var a: int = mini(pair[0], pair[1])
			var b: int = maxi(pair[0], pair[1])
			var key := Vector2i(a, b)
			if not edge_rest.has(key):
				edge_rest[key] = sim_positions[a].distance_to(sim_positions[b])
				edge_faces[key] = []
			edge_faces[key].append(face_idx)

	# XPBD compliance baked per constraint. Mapping stiffness ∈ [0, 1] → α (compliance):
	#   α = (1 - stiffness)² · scale
	# At stiffness=1.0 → α=0 (rigid, equivalent to ideal-PBD full correction).
	# At stiffness=0.0 → α=scale (very compliant). Squaring gives a finer-grained
	# stiff zone near 1.0, where most garments live.
	#
	# Per-type scales picked so the existing defaults (0.5 / 0.1) feel close to
	# what they did in PBD with iters=8, substeps=8, dt≈2 ms. Stretch tolerates
	# a smaller scale because the per-edge denominator (w_a + w_b) is small;
	# bending tolerates a larger scale because the constraint fires less often
	# and "limp" is the documented default behavior at bend_stiffness=0.1.
	const STRETCH_COMPLIANCE_SCALE: float = 1.0e-5
	const BEND_COMPLIANCE_SCALE: float    = 1.0e-4
	var stretch_compliance: float = pow(1.0 - clampf(stiffness, 0.0, 1.0), 2.0) * STRETCH_COMPLIANCE_SCALE
	var bend_compliance:    float = pow(1.0 - clampf(bend_stiffness, 0.0, 1.0), 2.0) * BEND_COMPLIANCE_SCALE

	var constraints: Array = []
	for key in edge_rest:
		constraints.append([key.x, key.y, edge_rest[key], stretch_compliance])

	var nonmanifold := 0
	if bending_from_topology:
		for key in edge_faces:
			var fl: Array = edge_faces[key]
			if fl.size() == 2:
				var fa: Array = faces[fl[0]]
				var fb: Array = faces[fl[1]]
				var na := -1; var nb := -1
				for v in fa:
					if v != key.x and v != key.y: na = v; break
				for v in fb:
					if v != key.x and v != key.y: nb = v; break
				if na >= 0 and nb >= 0 and na != nb:
					var rest: float = sim_positions[na].distance_to(sim_positions[nb])
					constraints.append([na, nb, rest, bend_compliance])
			elif fl.size() > 2:
				nonmanifold += 1
	if nonmanifold > 0:
		push_warning("[GPUCloth] %d non-manifold edges (3+ faces) skipped for bending." % nonmanifold)

	return _emit_colored_constraints(constraints)


func _emit_colored_constraints(constraints: Array) -> PackedFloat32Array:
	# Greedy graph coloring: place each constraint into the first group whose
	# vertex set doesn't already contain either endpoint. Race-free dispatch
	# requires no group contain two constraints touching the same particle.
	var groups: Array = []
	for ci in constraints.size():
		var c: Array = constraints[ci]
		var a: int = c[0]; var b: int = c[1]
		var placed := false
		for g in groups:
			var vs: Dictionary = g.vertex_set
			if not vs.has(a) and not vs.has(b):
				g.indices.append(ci)
				vs[a] = true; vs[b] = true
				placed = true; break
		if not placed:
			groups.append({indices = [ci], vertex_set = {a: true, b: true}})

	var data := PackedFloat32Array()
	data.resize(constraints.size() * 4)
	_constraint_groups = []
	var write := 0
	for g in groups:
		var start := write
		for ci in g.indices:
			var c: Array = constraints[ci]
			var off := write * 4
			data[off]   = float(c[0])
			data[off+1] = float(c[1])
			data[off+2] = c[2]
			data[off+3] = c[3]
			write += 1
		_constraint_groups.append({offset = start, count = write - start})
	assert(write == constraints.size(), "graph coloring lost or duplicated constraints")
	return data


# ---------------------------------------------------------------------------
#  Fishing-line bindings (port from v2.x:_build_bindings, mesh-Y stretch only)
# ---------------------------------------------------------------------------

func _build_bindings(pos_data: PackedFloat32Array, k: int) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(_particle_count * k * 4)

	# Anchors are EXPLICITLY Marker3D-pinned particles only — including every
	# inv_mass=0 particle would weld free particles to the rest pose (v2.x lesson).
	var pin_owned := PackedByteArray(); pin_owned.resize(_particle_count)
	for pin in _pin_map:
		pin_owned[pin.particle_idx] = 1
	var pinned_indices := PackedInt32Array()
	var pinned_positions := PackedVector3Array()
	for i in _particle_count:
		if pin_owned[i] != 0:
			pinned_indices.append(i)
			pinned_positions.append(Vector3(
				pos_data[i*4], pos_data[i*4+1], pos_data[i*4+2]))

	if pinned_indices.is_empty():
		# All slots → self-sentinel
		var idx_bytes := PackedByteArray(); idx_bytes.resize(4)
		for i in _particle_count:
			idx_bytes.encode_u32(0, i)
			var sf: float = idx_bytes.decode_float(0)
			for slot in k:
				var off := (i * k + slot) * 4
				data[off]   = sf
				data[off+1] = 0.0; data[off+2] = 0.0; data[off+3] = 0.0
		return data

	# Mesh-Y bounds for the per-particle stretch curve sample.
	var use_curve: bool = stretch_curve != null and stretch_curve.point_count > 0
	var min_y := _welded_positions[0].y; var max_y := _welded_positions[0].y
	for v in _welded_positions:
		min_y = minf(min_y, v.y); max_y = maxf(max_y, v.y)
	var mesh_top_y := max_y
	var mesh_height: float = maxf(max_y - min_y, 1e-6)

	var idx_bytes := PackedByteArray(); idx_bytes.resize(4)

	for i in _particle_count:
		idx_bytes.encode_u32(0, i)
		var self_float: float = idx_bytes.decode_float(0)

		# Pinned particles get K self-sentinels — fishing shader early-outs
		# on inverse_mass==0 anyway.
		if pos_data[i*4+3] == 0.0:
			for slot in k:
				var off := (i * k + slot) * 4
				data[off]   = self_float
				data[off+1] = 0.0; data[off+2] = 0.0; data[off+3] = 0.0
			continue

		var p := Vector3(pos_data[i*4], pos_data[i*4+1], pos_data[i*4+2])

		# Per-particle stretch
		var stretch_t: float = clampf((mesh_top_y - p.y) / mesh_height, 0.0, 1.0)
		var stretch: float = stretch_curve.sample(stretch_t) if use_curve else fishing_stretch
		stretch = maxf(stretch, 0.0)

		# Sort all pins by distance
		var sort_pairs: Array = []
		for j in pinned_indices.size():
			var d: float = p.distance_to(pinned_positions[j])
			sort_pairs.append([d, pinned_indices[j]])
		sort_pairs.sort_custom(func(a, b): return a[0] < b[0])

		var k_actual: int = mini(k, sort_pairs.size())

		# Inverse-square raw weights, normalized to 1
		var raw_weights: Array = []
		var weight_sum: float = 0.0
		for slot in k_actual:
			var d: float = sort_pairs[slot][0]
			var w: float = 1.0 / maxf(d * d, 1e-8)
			raw_weights.append(w)
			weight_sum += w

		for slot in k:
			var off := (i * k + slot) * 4
			if slot < k_actual:
				var anchor_idx: int = sort_pairs[slot][1]
				var rest_dist: float = sort_pairs[slot][0]
				var max_dist: float = rest_dist * stretch
				var norm_weight: float = raw_weights[slot] / weight_sum
				idx_bytes.encode_u32(0, anchor_idx)
				data[off]   = idx_bytes.decode_float(0)
				data[off+1] = max_dist
				data[off+2] = norm_weight
				data[off+3] = 0.0
			else:
				data[off]   = self_float
				data[off+1] = 0.0; data[off+2] = 0.0; data[off+3] = 0.0

	return data


# ---------------------------------------------------------------------------
#  Adjacency: vertex → list of touching triangles, in welded-index space (Hazard 1)
# ---------------------------------------------------------------------------

func _build_adjacency() -> Dictionary:
	var vert_tris: Array = []
	vert_tris.resize(_particle_count)
	for v in _particle_count:
		vert_tris[v] = PackedInt32Array()
	var tri_count: int = _src_indices.size() / 3
	for t in tri_count:
		var w0: int = _original_to_welded[_src_indices[t*3]]
		var w1: int = _original_to_welded[_src_indices[t*3+1]]
		var w2: int = _original_to_welded[_src_indices[t*3+2]]
		# Don't double-add when two render verts of a triangle collapse to the same particle.
		vert_tris[w0].append(t)
		if w1 != w0:
			vert_tris[w1].append(t)
		if w2 != w0 and w2 != w1:
			vert_tris[w2].append(t)

	var counts  := PackedInt32Array(); counts.resize(_particle_count)
	var offsets := PackedInt32Array(); offsets.resize(_particle_count)
	var list    := PackedInt32Array()
	var offset  := 0
	for v in _particle_count:
		counts[v]  = vert_tris[v].size()
		offsets[v] = offset
		list.append_array(vert_tris[v])
		offset += vert_tris[v].size()

	print("[GPUCloth] Adjacency list: %d entries for %d welded particles." % [list.size(), _particle_count])
	return {counts = counts, offsets = offsets, list = list}


# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------

func _pack_indices_uint(indices: PackedInt32Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(indices.size() * 4)
	for i in indices.size():
		bytes.encode_u32(i * 4, indices[i])
	return bytes


func _find_colliders_recursive(node: Node) -> void:
	if node is GPUClothCollider:
		_colliders.append(node as GPUClothCollider)
	for child in node.get_children():
		_find_colliders_recursive(child)


# Walks the body mesh's vertex bone weights and produces one capsule per
# bone with enough influence (per auto_collider_lod threshold). Each capsule's
# axis is bone → first-child-bone (chosen by which child has the most weighted
# verts among this bone's children, ties broken by skeleton index); the radius
# is the max perpendicular distance of weighted verts to that axis, clamped
# to a sensible minimum. Stores results in _auto_colliders for per-frame
# packing in _pack_colliders.
func _build_auto_colliders() -> void:
	var body_mi := get_node_or_null(body_mesh) as MeshInstance3D
	if not body_mi or not body_mi.mesh:
		push_warning("[GPUCloth] body_mesh path doesn't resolve to a valid MeshInstance3D; auto-collider generation skipped.")
		return
	var body_skin: Skin = body_mi.get_skin()
	if not body_skin:
		push_warning("[GPUCloth] body_mesh has no Skin resource; auto-collider generation skipped.")
		return

	# Resolve the body's own skin bind → skeleton bone map. The body might use
	# a different Skin than the cloth, so don't reuse _bind_to_bone.
	var body_bind_count := body_skin.get_bind_count()
	var body_bind_to_bone := PackedInt32Array()
	body_bind_to_bone.resize(body_bind_count)
	for bi in body_bind_count:
		var bone_idx: int = body_skin.get_bind_bone(bi)
		if bone_idx < 0:
			bone_idx = _skeleton_node.find_bone(str(body_skin.get_bind_name(bi)))
		body_bind_to_bone[bi] = bone_idx

	# Walk the body's vertex bone weights. For each skeleton bone, collect the
	# list of (vertex_pos, weight) pairs where this bone has weight > 0.5
	# (heaviest-influence threshold — fingertip-weight contributions don't make
	# a bone "this vert's bone" for capsule-fitting purposes).
	var body_extracted := GPUClothSolver.extract_mesh_data(body_mi.mesh)
	var b_verts:   PackedVector3Array = body_extracted.vertices
	var b_bones:   PackedInt32Array   = body_extracted.bones
	var b_weights: PackedFloat32Array = body_extracted.weights
	if b_bones.is_empty() or b_weights.is_empty():
		push_warning("[GPUCloth] body_mesh has no bone weights — can't auto-fit capsules. Skipping.")
		return

	# Project each body vert into its bone's rest-local space using the body
	# skin's bind pose. Godot stores get_bind_pose() as the INVERSE bind matrix
	# (matches the skin shader's `bone_global_pose * bind_pose` convention used
	# in _pack_bone_matrices), so `bind_pose * v_mesh_local` puts the vert
	# directly in the bone's rest-local space. This handles meshes whose mesh-
	# local origin is wildly offset from the skeleton's origin (common: GLBs
	# often have body verts at e.g. x≈-8 while bones are at x≈0; without the
	# bind transform, the radius computation thinks every vert is ~8m from
	# its bone, producing absurd radii).
	var bone_count := _skeleton_node.get_bone_count()
	var bone_verts: Array[PackedVector3Array] = []
	bone_verts.resize(bone_count)
	for i in bone_count:
		bone_verts[i] = PackedVector3Array()

	# Find each vert's strictly-heaviest bone (don't rely on GLB exporters
	# keeping weights sorted) and only claim it for that bone when the weight
	# clears auto_collider_dominance_threshold. Joint-area verts with split
	# weights (e.g., 0.55/0.45 between neck and clavicle) get skipped — they
	# don't belong squarely to either bone and would otherwise inflate the
	# winning bone's capsule with off-axis verts.
	var n_body_verts: int = b_verts.size()
	var skipped_split := 0
	for v in n_body_verts:
		var best_k := -1
		var best_w := 0.0
		for k in 4:
			var w: float = b_weights[v * 4 + k]
			if w > best_w:
				best_w = w
				best_k = k
		if best_k < 0 or best_w < auto_collider_dominance_threshold:
			skipped_split += 1
			continue
		var bind_i: int = b_bones[v * 4 + best_k]
		if bind_i < 0 or bind_i >= body_bind_count:
			continue
		var bone_idx: int = body_bind_to_bone[bind_i]
		if bone_idx < 0:
			continue
		var v_bone_local: Vector3 = body_skin.get_bind_pose(bind_i) * b_verts[v]
		bone_verts[bone_idx].append(v_bone_local)
	if skipped_split > 0:
		print("[GPUCloth] Skipped %d body verts with split weights (heaviest < %.2f). Lower auto_collider_dominance_threshold if too few bones qualify." % [
			skipped_split, auto_collider_dominance_threshold])

	# ── Sphere cloud (optional, additive on top of capsules) ──
	# Sample every Nth body vert and turn it into a sphere collider skinned to
	# its dominant bone. Each sphere stores the vert's position in BONE-LOCAL
	# space (via bind_pose); at pack time, bone_pose * local_offset gives the
	# sphere's current skel-local center. Packed as a degenerate capsule
	# (a == b) — collide shader handles that as a sphere with zero changes.
	if body_sphere_lod > 0:
		var step := 1
		match body_sphere_lod:
			1: step = 64
			2: step = 16
			3: step = 4
		var n_spheres := 0
		var n_skipped_sphere := 0
		for v_idx in range(0, n_body_verts, step):
			var best_k := -1
			var best_w := 0.0
			for k in 4:
				var w: float = b_weights[v_idx * 4 + k]
				if w > best_w:
					best_w = w
					best_k = k
			if best_k < 0 or best_w < auto_collider_dominance_threshold:
				n_skipped_sphere += 1
				continue
			var bind_i: int = b_bones[v_idx * 4 + best_k]
			if bind_i < 0 or bind_i >= body_bind_count:
				continue
			var bone_idx: int = body_bind_to_bone[bind_i]
			if bone_idx < 0:
				continue
			var v_bone_local: Vector3 = body_skin.get_bind_pose(bind_i) * b_verts[v_idx]
			_auto_spheres.append({
				bone = bone_idx,
				local_offset = v_bone_local,
				radius = body_sphere_radius,
			})
			n_spheres += 1
		print("[GPUCloth] Body sphere cloud: %d spheres at LOD %d (step %d, %d skipped split-weight, radius %.3f m)" % [
			n_spheres, body_sphere_lod, step, n_skipped_sphere, body_sphere_radius])

	# LOD thresholds — minimum number of verts a bone must own to get a capsule.
	var weight_threshold := 999999
	match auto_collider_lod:
		1: weight_threshold = 50
		2: weight_threshold = 10
		3: weight_threshold = 1

	# For each qualifying bone, build a capsule along bone → first-child axis.
	var n_built := 0
	for bone_idx in bone_count:
		var verts_here: PackedVector3Array = bone_verts[bone_idx]
		if verts_here.size() < weight_threshold:
			continue

		# Find the child bone with the most weighted verts (heaviest descent).
		var children: PackedInt32Array = _skeleton_node.get_bone_children(bone_idx)
		var best_child := -1
		var best_child_count := -1
		for c in children:
			var cc: int = bone_verts[c].size() if c < bone_verts.size() else 0
			if cc > best_child_count:
				best_child_count = cc
				best_child = c

		# Capsule axis: bone origin → child origin (both in bone-rest-space).
		# If no child or child is at the same position, fall back to a sphere
		# (axis_b = axis_a) and a slightly larger radius.
		var axis_a := Vector3.ZERO
		var axis_b: Vector3
		if best_child >= 0:
			# Child's rest position in PARENT bone's rest frame.
			var child_rest := _skeleton_node.get_bone_global_rest(best_child)
			var parent_rest_inv := _skeleton_node.get_bone_global_rest(bone_idx).affine_inverse()
			axis_b = parent_rest_inv * child_rest.origin
		else:
			axis_b = axis_a

		# Radius: percentile-th perpendicular distance of bone's verts to the axis.
		# Two filters tighten the fit:
		#   1. Axis-range gate: only verts whose projection on the bone segment
		#      falls within [-tolerance, 1+tolerance] count. Without this, a
		#      pelvis bone could include thigh verts (heavy weights bleed across
		#      joints), inflating the capsule into the next bone's region.
		#   2. Percentile instead of max: ignores the top (1-percentile)% of
		#      outliers — single misweighted verts (e.g., a clavicle vert pinned
		#      to a shoulder bone) don't dominate the radius.
		# Result is in skel-internal units (v_local is in bone-rest-local).
		var ab: Vector3 = axis_b - axis_a
		var ab2: float = ab.length_squared()
		const AXIS_TOLERANCE := 0.15  # 15 % slop past each capsule end
		var perp_sqs := PackedFloat32Array()
		for v_local in verts_here:
			var perp: Vector3
			if ab2 > 1e-10:
				var t: float = (v_local - axis_a).dot(ab) / ab2
				if t < -AXIS_TOLERANCE or t > 1.0 + AXIS_TOLERANCE:
					continue  # outside this bone's segment; belongs to a neighbor
				var clamped_t: float = clampf(t, 0.0, 1.0)
				perp = v_local - (axis_a + ab * clamped_t)
			else:
				perp = v_local - axis_a
			perp_sqs.append(perp.length_squared())
		var radius := 0.01
		if perp_sqs.size() > 0:
			perp_sqs.sort()
			var pct_idx: int = clampi(
				floori(perp_sqs.size() * auto_collider_radius_percentile),
				0, perp_sqs.size() - 1)
			radius = maxf(sqrt(perp_sqs[pct_idx]) * auto_collider_radius_scale, 0.01)

		_auto_colliders.append({
			bone_a = bone_idx,
			bone_b = best_child if best_child >= 0 else bone_idx,
			axis_a = axis_a,
			axis_b = axis_b,
			radius = radius,
		})
		n_built += 1
		print("[GPUCloth]   capsule for bone '%s' (idx %d) → '%s': %d verts (%d in-range, percentile %.2f), radius %.4f m" % [
			_skeleton_node.get_bone_name(bone_idx), bone_idx,
			_skeleton_node.get_bone_name(best_child) if best_child >= 0 else "<self>",
			verts_here.size(), perp_sqs.size(), auto_collider_radius_percentile, radius])

	print("[GPUCloth] Auto-colliders: built %d capsules (LOD %d, threshold %d verts)" % [
		n_built, auto_collider_lod, weight_threshold])


# Decimates body_mesh via voxel clustering (verts in the same grid cell collapse
# to their centroid; tris that collapse degenerately are dropped) and stores
# each surviving triangle as 3 (bone_idx, local_offset) pairs in the bone's
# bind-pose-local space. At runtime each vert's skel-local position is just
# bone_pose * local_offset — single-bone dominant-weight skinning is accurate
# enough for collision and avoids per-vert 4-bone matrix work.
func _build_collider_mesh() -> void:
	var src_mi := get_node_or_null(body_mesh) as MeshInstance3D
	if not src_mi or not src_mi.mesh:
		push_warning("[GPUCloth] body_mesh path doesn't resolve to a valid MeshInstance3D; triangle mesh collider skipped.")
		return
	var src_skin: Skin = src_mi.get_skin()
	if not src_skin:
		push_warning("[GPUCloth] body_mesh has no Skin resource; triangle mesh collider skipped.")
		return

	# Resolve the source skin's bind → bone mapping (may differ from the cloth's).
	var src_bind_count := src_skin.get_bind_count()
	var src_bind_to_bone := PackedInt32Array(); src_bind_to_bone.resize(src_bind_count)
	for bi in src_bind_count:
		var bone_idx: int = src_skin.get_bind_bone(bi)
		if bone_idx < 0:
			bone_idx = _skeleton_node.find_bone(str(src_skin.get_bind_name(bi)))
		src_bind_to_bone[bi] = bone_idx

	var extracted := GPUClothSolver.extract_mesh_data(src_mi.mesh)
	var s_verts: PackedVector3Array = extracted.vertices
	var s_indices: PackedInt32Array = extracted.indices
	var s_bones: PackedInt32Array   = extracted.bones
	var s_weights: PackedFloat32Array = extracted.weights
	if s_verts.is_empty() or s_indices.size() < 3 or s_bones.is_empty():
		push_warning("[GPUCloth] body_mesh has no usable triangle / bone data; triangle mesh collider skipped.")
		return

	# ── Voxel clustering decimation ──
	# Map each vert to a grid cell; verts in the same cell collapse to one
	# representative (their centroid). Resolution 0 = no decimation.
	var n_src := s_verts.size()
	var vert_remap := PackedInt32Array(); vert_remap.resize(n_src)
	var merged_verts := PackedVector3Array()
	var merged_centroid_count := PackedInt32Array()  # how many src verts → each merged
	var merged_dominant_bind := PackedInt32Array()   # most-common dominant bind index

	if body_collider_voxel_resolution <= 0:
		# No decimation — 1:1 mapping.
		merged_verts = s_verts.duplicate()
		merged_centroid_count.resize(n_src); merged_centroid_count.fill(1)
		merged_dominant_bind.resize(n_src); merged_dominant_bind.fill(-1)
		for i in n_src:
			vert_remap[i] = i
			# Find dominant bind for this vert.
			var best_k := -1; var best_w := 0.0
			for k in 4:
				var w: float = s_weights[i * 4 + k]
				if w > best_w:
					best_w = w; best_k = k
			if best_k >= 0:
				merged_dominant_bind[i] = s_bones[i * 4 + best_k]
	else:
		# Compute mesh AABB → voxel size.
		var min_v := s_verts[0]; var max_v := s_verts[0]
		for v in s_verts:
			min_v = min_v.min(v); max_v = max_v.max(v)
		var span := max_v - min_v
		var longest := maxf(maxf(span.x, span.y), span.z)
		var voxel_size: float = maxf(longest / float(body_collider_voxel_resolution), 1e-6)
		var inv_vs: float = 1.0 / voxel_size

		# Cluster verts by voxel cell. Each cluster accumulates centroid and
		# bind-vote tallies (dominant bone wins).
		var cell_to_cluster: Dictionary = {}
		var cluster_sum: Array[Vector3] = []
		var cluster_count: Array[int] = []
		var cluster_bind_votes: Array[Dictionary] = []  # bind_idx → weight sum

		for i in n_src:
			var v := s_verts[i]
			var cell := Vector3i(
				int(floor((v.x - min_v.x) * inv_vs)),
				int(floor((v.y - min_v.y) * inv_vs)),
				int(floor((v.z - min_v.z) * inv_vs)))
			var ci: int
			if cell_to_cluster.has(cell):
				ci = cell_to_cluster[cell]
				cluster_sum[ci] += v
				cluster_count[ci] += 1
			else:
				ci = cluster_sum.size()
				cell_to_cluster[cell] = ci
				cluster_sum.append(v)
				cluster_count.append(1)
				cluster_bind_votes.append({})
			vert_remap[i] = ci

			# Tally bone-bind weights — the dominant bind of the cluster is the
			# one with the highest summed weight across all member verts.
			for k in 4:
				var w: float = s_weights[i * 4 + k]
				if w < 0.05:
					continue
				var bi: int = s_bones[i * 4 + k]
				var votes: Dictionary = cluster_bind_votes[ci]
				votes[bi] = votes.get(bi, 0.0) + w

		var n_clusters: int = cluster_sum.size()
		merged_verts.resize(n_clusters)
		merged_centroid_count.resize(n_clusters)
		merged_dominant_bind.resize(n_clusters)
		for ci in n_clusters:
			merged_verts[ci] = cluster_sum[ci] / float(cluster_count[ci])
			merged_centroid_count[ci] = cluster_count[ci]
			# Pick highest-vote bind.
			var best_bi := -1; var best_w := 0.0
			for bi in cluster_bind_votes[ci].keys():
				var w: float = cluster_bind_votes[ci][bi]
				if w > best_w:
					best_w = w; best_bi = bi
			merged_dominant_bind[ci] = best_bi

	# ── Build triangle list, dropping degenerates ──
	# For each source triangle, remap its 3 verts. If any two map to the same
	# merged vert, the triangle has collapsed and we skip it.
	_collider_tris.clear()
	var src_tri_count: int = s_indices.size() / 3
	var dropped := 0
	for tri in src_tri_count:
		var ri0: int = s_indices[tri * 3]
		var ri1: int = s_indices[tri * 3 + 1]
		var ri2: int = s_indices[tri * 3 + 2]
		var m0: int = vert_remap[ri0]
		var m1: int = vert_remap[ri1]
		var m2: int = vert_remap[ri2]
		if m0 == m1 or m1 == m2 or m0 == m2:
			dropped += 1
			continue

		var tri_verts: Array = []
		var triangle_ok := true
		for mi in [m0, m1, m2]:
			var bind_i: int = merged_dominant_bind[mi]
			if bind_i < 0 or bind_i >= src_bind_count:
				triangle_ok = false; break
			var bone_idx: int = src_bind_to_bone[bind_i]
			if bone_idx < 0:
				triangle_ok = false; break
			# Vert in bone's bind-pose-local space: bind_pose * v_mesh_local.
			var local_offset: Vector3 = src_skin.get_bind_pose(bind_i) * merged_verts[mi]
			tri_verts.append({bone = bone_idx, local = local_offset})
		if not triangle_ok:
			dropped += 1
			continue
		_collider_tris.append(tri_verts)

	print("[GPUCloth] Mesh collider: %d source tris → %d after decimation (voxel res %d, %d dropped degenerate)" % [
		src_tri_count, _collider_tris.size(), body_collider_voxel_resolution, dropped])


# Bone matrices: 48 B per bind, row-major 3×4, encoding bone_global_pose * bind_pose.
# Maps mesh-local rest position → skeleton-local current position. Hazard 3.
func _pack_bone_matrices() -> PackedByteArray:
	if not _use_skinning:
		# Unrigged: nothing dispatches the skin pass, so no bone data is read.
		# Returning empty skips the buffer_update in _gpu_do_simulate.
		return PackedByteArray()
	var data := PackedByteArray(); data.resize(_bind_count * 48)
	for bi in _bind_count:
		var bone_idx: int = _bind_to_bone[bi]
		if bone_idx < 0:
			continue
		var m: Transform3D = _skeleton_node.get_bone_global_pose(bone_idx) * _skin.get_bind_pose(bi)
		var off := bi * 48
		data.encode_float(off +  0, m.basis.x.x); data.encode_float(off +  4, m.basis.y.x)
		data.encode_float(off +  8, m.basis.z.x); data.encode_float(off + 12, m.origin.x)
		data.encode_float(off + 16, m.basis.x.y); data.encode_float(off + 20, m.basis.y.y)
		data.encode_float(off + 24, m.basis.z.y); data.encode_float(off + 28, m.origin.y)
		data.encode_float(off + 32, m.basis.x.z); data.encode_float(off + 36, m.basis.y.z)
		data.encode_float(off + 40, m.basis.z.z); data.encode_float(off + 44, m.origin.z)
	return data


# Pin overrides: per-pin (particle_idx_bitcast, skel-local pos.xyz). Cloth_pin_override.glsl
# uses these to overwrite skinned_targets[particle_idx] each frame so PREDICT's snap
# mechanism honors marker positions (Hazard 4 — markers and skin authoring coexist).
func _pack_pin_overrides_into(out: PackedByteArray) -> void:
	var idx_bytes := PackedByteArray(); idx_bytes.resize(4)
	for i in _pin_map.size():
		var off := i * 16
		idx_bytes.encode_u32(0, _pin_map[i].particle_idx)
		out.encode_float(off + 0,  idx_bytes.decode_float(0))
		var p: Vector3 = _pin_map[i].smoothed_pos
		out.encode_float(off + 4,  p.x)
		out.encode_float(off + 8,  p.y)
		out.encode_float(off + 12, p.z)


# Hazard 2: positions live in the reference frame (skel-local when rigged,
# solver-local when unrigged); colliders pack into the same frame. This emits
# both manually-authored GPUClothColliders AND auto-generated bone capsules
# (from _build_auto_colliders) into one contiguous buffer.
func _pack_colliders() -> PackedByteArray:
	var total: int = _colliders.size() + _auto_colliders.size() + _auto_spheres.size()
	if total == 0:
		var empty := PackedByteArray(); empty.resize(64); return empty
	var data := PackedByteArray(); data.resize(total * 64)
	var cloth_inv := _ref_node.global_transform.affine_inverse()
	var write_idx := 0

	# Manual GPUClothColliders — capsule/sphere/box, each emits 4 vec4s.
	for i in _colliders.size():
		var floats := _colliders[i].pack_collider_data(cloth_inv)
		var off := write_idx * 64
		for j in 16: data.encode_float(off + j * 4, floats[j])
		write_idx += 1

	# Auto-colliders — always capsules. Endpoint a is bone_a's current origin
	# in skel-local; endpoint b is bone_b's. Since the ref frame == skel frame
	# (auto-colliders only generated in rigged mode where _ref_node == skeleton),
	# bone_global_pose.origin is already in the ref frame — no extra transform.
	# Sphere fallback (bone_b == bone_a, no child found at init) collapses to
	# a single point, which the capsule SDF handles correctly.
	if _use_skinning:
		for ac in _auto_colliders:
			var a_skel: Vector3 = _skeleton_node.get_bone_global_pose(ac.bone_a).origin
			var b_skel: Vector3 = _skeleton_node.get_bone_global_pose(ac.bone_b).origin
			# Capsule layout matches GPUClothCollider.pack_collider_data:
			#   vec4[0]: a.xyz, radius
			#   vec4[1]: b.xyz, shape_type=0.0
			#   vec4[2..3]: unused
			var off := write_idx * 64
			data.encode_float(off +  0, a_skel.x)
			data.encode_float(off +  4, a_skel.y)
			data.encode_float(off +  8, a_skel.z)
			data.encode_float(off + 12, ac.radius)
			data.encode_float(off + 16, b_skel.x)
			data.encode_float(off + 20, b_skel.y)
			data.encode_float(off + 24, b_skel.z)
			data.encode_float(off + 28, 0.0)  # shape_type capsule
			write_idx += 1

		# Sphere cloud — each sphere is packed as a degenerate capsule (a == b)
		# so the existing collide shader handles it as a sphere without changes.
		# Center = bone_pose * local_offset (vert's current skinned position).
		for sp in _auto_spheres:
			var center: Vector3 = _skeleton_node.get_bone_global_pose(sp.bone) * sp.local_offset
			var off := write_idx * 64
			data.encode_float(off +  0, center.x)
			data.encode_float(off +  4, center.y)
			data.encode_float(off +  8, center.z)
			data.encode_float(off + 12, sp.radius)
			data.encode_float(off + 16, center.x)
			data.encode_float(off + 20, center.y)
			data.encode_float(off + 24, center.z)
			data.encode_float(off + 28, 0.0)  # shape_type capsule (degenerate = sphere)
			write_idx += 1

	return data


# Builds the peer-collision proxy index list. Voxel-clusters _welded_positions
# in rest space (one representative welded particle per cell), then remaps
# _welded_indices through that subset and drops triangles that collapsed to a
# line/point. Returns the remapped index list directly — caller packs it into
# bytes and uploads alongside the full welded index buffer.
#
# The proxy uses our existing _positions_buffer (no separate storage), so the
# representative particles still move with the simulation as normal — the proxy
# is just a coarser triangulation drawn over them. peer_collider_voxel_resolution
# == 0 disables decimation (returns _welded_indices verbatim).
func _build_peer_proxy_indices() -> PackedInt32Array:
	if _welded_positions.is_empty() or _welded_indices.size() < 3:
		return PackedInt32Array()
	if peer_collider_voxel_resolution <= 0:
		# No decimation requested — peers will fall back to the full welded
		# index buffer in _ensure_peer_uniform_sets. Return empty so we don't
		# pay for an unused proxy buffer.
		print("[GPUCloth] Peer proxy: decimation disabled (voxel_resolution = 0) — peers will bind full %d-tri mesh." % (_welded_indices.size() / 3))
		return PackedInt32Array()

	# Mesh AABB → voxel size along the longest axis.
	var n_p: int = _welded_positions.size()
	var min_v: Vector3 = _welded_positions[0]
	var max_v: Vector3 = _welded_positions[0]
	for v in _welded_positions:
		min_v = min_v.min(v); max_v = max_v.max(v)
	var span: Vector3 = max_v - min_v
	var longest: float = maxf(maxf(span.x, span.y), span.z)
	var voxel_size: float = maxf(longest / float(peer_collider_voxel_resolution), 1e-6)
	var inv_vs: float = 1.0 / voxel_size

	# Cluster welded particles by voxel cell. Representative = first particle
	# encountered in each cell (cheap and stable; centroid pick would force a
	# second pass with no quality win — particles move during sim anyway).
	var cell_to_rep: Dictionary = {}
	var remap := PackedInt32Array(); remap.resize(n_p)
	for i in n_p:
		var p: Vector3 = _welded_positions[i]
		var cell := Vector3i(
			int(floor((p.x - min_v.x) * inv_vs)),
			int(floor((p.y - min_v.y) * inv_vs)),
			int(floor((p.z - min_v.z) * inv_vs)))
		var rep: int = cell_to_rep.get(cell, -1)
		if rep < 0:
			rep = i
			cell_to_rep[cell] = rep
		remap[i] = rep

	# Remap triangle list, drop degenerates (two or more verts collapsed).
	var src_tri_count: int = _welded_indices.size() / 3
	var out := PackedInt32Array()
	var dropped := 0
	for t in src_tri_count:
		var i0: int = remap[_welded_indices[t * 3 + 0]]
		var i1: int = remap[_welded_indices[t * 3 + 1]]
		var i2: int = remap[_welded_indices[t * 3 + 2]]
		if i0 == i1 or i1 == i2 or i0 == i2:
			dropped += 1
			continue
		out.push_back(i0); out.push_back(i1); out.push_back(i2)

	# De-duplicate identical triangles produced by remapping (two source tris
	# that share two verts and have their third vert collapse to the same rep
	# become the same proxy tri). Cheap key = sorted (a,b,c).
	var seen: Dictionary = {}
	var deduped := PackedInt32Array()
	var dup_dropped := 0
	var n_out_tri: int = out.size() / 3
	for t in n_out_tri:
		var a: int = out[t * 3 + 0]
		var b: int = out[t * 3 + 1]
		var c: int = out[t * 3 + 2]
		# Order-independent key — sort the three indices so a tri and its
		# winding-flipped twin map to the same dict entry.
		var lo: int = mini(mini(a, b), c)
		var hi: int = maxi(maxi(a, b), c)
		var mid: int = (a + b + c) - lo - hi
		var key: Vector3i = Vector3i(lo, mid, hi)
		if seen.has(key):
			dup_dropped += 1
			continue
		seen[key] = true
		deduped.push_back(a); deduped.push_back(b); deduped.push_back(c)

	var reps: int = cell_to_rep.size()
	print("[GPUCloth] Peer proxy: %d welded verts → %d reps (voxel res %d), %d source tris → %d proxy tris (%d degenerate, %d duplicate)" % [
		n_p, reps, peer_collider_voxel_resolution,
		src_tri_count, deduped.size() / 3, dropped, dup_dropped])
	return deduped


# Lazy init for peer-cloth collision. Runs on the render thread once both this
# solver AND its peers have completed _gpu_do_init (peers' _positions_buffer
# and _indices_gpu_buffer must exist before we can bind them). Idempotent —
# bails immediately on subsequent calls once all peers are wired.
func _ensure_peer_uniform_sets() -> void:
	if peer_cloth_solvers.is_empty():
		return
	if _peers.size() == peer_cloth_solvers.size():
		return  # already built
	_peers.clear()
	for path in peer_cloth_solvers:
		var peer := get_node_or_null(path) as GPUClothSolver
		if peer == null:
			push_warning("[GPUCloth] peer_cloth_solvers entry '%s' did not resolve to a GPUClothSolver — skipping." % path)
			continue
		if not peer._gpu_init_done:
			# Peer isn't ready yet — defer the whole batch. Next frame will retry.
			_peers.clear()
			return
		if peer._ref_node != _ref_node:
			push_warning("[GPUCloth] peer '%s' uses a different reference frame (skeleton) — cross-frame peer collision not yet supported, skipping." % path)
			continue
		# Prefer the peer's decimated proxy buffer if it built one — otherwise
		# fall back to the full welded index buffer (peer_collider_voxel_resolution
		# == 0, or the proxy collapsed to zero tris).
		var peer_idx_buffer: RID = peer._peer_proxy_indices_buffer if peer._peer_proxy_tri_count > 0 else peer._indices_gpu_buffer
		var peer_idx_tri_count: int = peer._peer_proxy_tri_count if peer._peer_proxy_tri_count > 0 else peer._tri_count
		var us := _create_uniform_set(_peer_collide_shader, [
			_make_uniform(0, _positions_buffer),         # OUR substep-start (RO, friction tangent)
			_make_uniform(1, _predicted_buffer),         # ours, RW
			_make_uniform(2, peer._positions_buffer),    # peer's CURRENT positions (RO)
			_make_uniform(3, peer_idx_buffer),           # peer's proxy or full triangle indices (RO)
			_make_uniform(5, _cloth_weights_buffer),     # OUR cloth_weights — per-particle thickness multiplier
		])
		# Sanitizer uniform set — same peer geometry, writes our skinned_targets.
		var us_sanitize := _create_uniform_set(_peer_skin_collide_shader, [
			_make_uniform(0, _skinned_targets_buffer),
			_make_uniform(2, peer._positions_buffer),
			_make_uniform(3, peer_idx_buffer),
		])
		var push := PackedByteArray(); push.resize(32)
		push.encode_u32(0, _particle_count)
		push.encode_u32(4, peer_idx_tri_count)
		push.encode_float(8, body_collider_thickness)
		push.encode_float(12, collider_friction)
		push.encode_u32(16, 0)  # is_self = 0 — real peer; never skip "vert-of-me" triangles
		_peers.append({
			solver = peer,
			uniform_set = us,
			sanitize_uniform_set = us_sanitize,
			push = push,
		})
		var src_tag := "proxy" if peer._peer_proxy_tri_count > 0 else "full"
		print("[GPUCloth] Peer cloth collider wired: %s (%d tris, %s) — both collide + sanitize" % [peer.name, peer_idx_tri_count, src_tag])


# Per-frame: skin each collider triangle's verts (single-bone dominant skinning,
# bone_pose * local_offset) and pack into the contiguous byte buffer the GPU
# shader reads. 48 bytes per triangle (3 × vec4, w unused). Reuses
# _collider_tri_bytes across frames to avoid reallocation.
func _pack_collider_tris() -> PackedByteArray:
	if _collider_tris.is_empty():
		return PackedByteArray()
	# Cache each bone's pose just once per frame — many tris share bones.
	var bone_poses: Dictionary = {}
	var write := 0
	for tri in _collider_tris:
		for v in tri:
			var bi: int = v.bone
			var pose: Transform3D
			if bone_poses.has(bi):
				pose = bone_poses[bi]
			else:
				pose = _skeleton_node.get_bone_global_pose(bi)
				bone_poses[bi] = pose
			var world: Vector3 = pose * v.local
			_collider_tri_bytes.encode_float(write +  0, world.x)
			_collider_tri_bytes.encode_float(write +  4, world.y)
			_collider_tri_bytes.encode_float(write +  8, world.z)
			_collider_tri_bytes.encode_float(write + 12, 0.0)
			write += 16
	return _collider_tri_bytes


func _load_shader(path: String) -> RID:
	var sf: RDShaderFile = load(path)
	if not sf:
		push_error("[GPUCloth] Failed to load shader: %s" % path); return RID()
	var rid := _rd.shader_create_from_spirv(sf.get_spirv())
	if not rid.is_valid():
		push_error("[GPUCloth] Shader compilation failed: %s" % path)
	return rid


func _make_uniform(binding: int, buffer: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buffer)
	return u


func _make_image_uniform(binding: int, img_rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(img_rid)
	return u


func _create_uniform_set(shader: RID, uniforms: Array[RDUniform]) -> RID:
	return _rd.uniform_set_create(uniforms, shader, 0)


# Auto-port a StandardMaterial3D's PBR parameters into a freshly created
# cloth_surface_textured ShaderMaterial. Triggered only when cloth_material is
# null and the mesh's intrinsic surface material was a StandardMaterial3D —
# preserves the imported asset's look so users don't lose textures by adopting
# v3.0. Texture-driven PBR (metallic/roughness/normal/AO maps) carries over;
# vertex_color_use_as_albedo and emission paths are not ported in v3.0.
func _port_standard_material(target: ShaderMaterial, src: StandardMaterial3D) -> void:
	var ported: Array[String] = []
	# Always-safe: albedo texture + tint. These never produce a "darker than
	# StandardMaterial would have" result.
	if src.albedo_texture:
		target.set_shader_parameter("albedo_texture", src.albedo_texture)
		ported.append("albedo_texture")
	target.set_shader_parameter("color_tint", src.albedo_color)
	ported.append("color_tint")
	# PBR scalars + maps: opt-in via port_standard_material_pbr_maps. Packed
	# PBR workflows hold metallic = 1.0 + roughness = 1.0 in the StandardMaterial
	# scalars with the per-pixel modulation living in the textures; porting
	# just the scalars (without the maps) produces a fully-metal / fully-rough
	# surface that renders dim. The AO channel mistmach (AO defaulting to RED
	# when RED holds a sim mask) is the other landmine. Opt-in keeps the
	# default visually safe across asset variation.
	if port_standard_material_pbr_maps:
		# Scalars
		target.set_shader_parameter("roughness", src.roughness)
		target.set_shader_parameter("metallic",  src.metallic)
		target.set_shader_parameter("specular",  src.metallic_specular)
		ported.append("roughness")
		ported.append("metallic")
		ported.append("specular")
		# StandardMaterial3D's texture-channel enum has a GRAYSCALE=4 value
		# that doesn't map to a single vec4 channel; clamp to 0–3 so the
		# shader's `vec4[channel_int]` lookup stays in-bounds. The (uncommon)
		# grayscale case degrades to "use the red channel".
		if src.metallic_texture:
			target.set_shader_parameter("metallic_texture", src.metallic_texture)
			target.set_shader_parameter("metallic_channel", mini(int(src.metallic_texture_channel), 3))
			ported.append("metallic_texture(ch=%d)" % src.metallic_texture_channel)
		if src.roughness_texture:
			target.set_shader_parameter("roughness_texture", src.roughness_texture)
			target.set_shader_parameter("roughness_channel", mini(int(src.roughness_texture_channel), 3))
			ported.append("roughness_texture(ch=%d)" % src.roughness_texture_channel)
		if src.normal_enabled and src.normal_texture:
			target.set_shader_parameter("normal_texture", src.normal_texture)
			target.set_shader_parameter("normal_scale",   src.normal_scale)
			ported.append("normal_texture")
		if src.ao_enabled and src.ao_texture:
			target.set_shader_parameter("ao_texture", src.ao_texture)
			target.set_shader_parameter("ao_channel", mini(int(src.ao_texture_channel), 3))
			target.set_shader_parameter("ao_light_affect", src.ao_light_affect)
			ported.append("ao_texture(ch=%d)" % src.ao_texture_channel)
	print("[GPUCloth] Auto-ported StandardMaterial3D → cloth_surface_textured: %s" % ", ".join(ported))


# ---------------------------------------------------------------------------
#  Debug particle overlay
#
#  Compromises the no-readback principle behind a toggle: every frame, when
#  debug_show_particles is on, we buffer_get_data() positions on the render
#  thread and call_deferred a draw onto an ImmediateMesh on the game thread.
#  This serializes the GPU and tanks performance — strictly a debugging tool.
# ---------------------------------------------------------------------------

func _ensure_debug_setup() -> void:
	if _debug_setup_done:
		return
	_debug_im = ImmediateMesh.new()
	_debug_mi = MeshInstance3D.new()
	_debug_mi.mesh = _debug_im
	_debug_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_debug_mi.top_level = true  # ignore solver's transform; we set global_transform manually
	var dmat := StandardMaterial3D.new()
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.vertex_color_use_as_albedo = true
	dmat.set_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST, true)
	dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_debug_mi.material_override = dmat
	add_child(_debug_mi)
	_debug_setup_done = true


# Render thread: read positions and velocities back, queue draw on game thread.
func _debug_readback() -> void:
	if not _rd:
		return
	var pos_data: PackedByteArray = _rd.buffer_get_data(_positions_buffer)
	var vel_data: PackedByteArray = _rd.buffer_get_data(_velocities_buffer)
	call_deferred("_debug_apply", pos_data, vel_data)


# Game thread: redraw the cross overlay + velocity vectors from the readback bytes.
# Yellow lines from each particle in its velocity direction, length scaled by
# 0.05 × speed so resting particles show no line and fast ones extend visibly.
func _debug_apply(pos_data: PackedByteArray, vel_data: PackedByteArray) -> void:
	if not _debug_setup_done or not _debug_im:
		return
	_debug_im.clear_surfaces()
	_debug_im.surface_begin(Mesh.PRIMITIVE_LINES)

	if debug_show_particles and pos_data.size() >= _particle_count * 16:
		var s: float = debug_particle_size
		var vel_color := Color(1.0, 1.0, 0.0, 0.9)  # yellow for velocity vectors
		for p in _particle_count:
			var off := p * 16
			var pos := Vector3(
				pos_data.decode_float(off),
				pos_data.decode_float(off + 4),
				pos_data.decode_float(off + 8))
			var vel := Vector3(
				vel_data.decode_float(off),
				vel_data.decode_float(off + 4),
				vel_data.decode_float(off + 8))
			var cw: float = _debug_cloth_weights[p] if p < _debug_cloth_weights.size() else 1.0
			var c := Color(1.0 - cw, cw, 0.0, 0.9)
			_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos + Vector3(s, 0, 0))
			_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos - Vector3(s, 0, 0))
			_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos + Vector3(0, s, 0))
			_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos - Vector3(0, s, 0))
			_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos + Vector3(0, 0, s))
			_debug_im.surface_set_color(c); _debug_im.surface_add_vertex(pos - Vector3(0, 0, s))
			# Velocity vector — only draw if there's actually some motion.
			var speed := vel.length()
			if speed > 0.01:
				_debug_im.surface_set_color(vel_color)
				_debug_im.surface_add_vertex(pos)
				_debug_im.surface_set_color(vel_color)
				_debug_im.surface_add_vertex(pos + vel * 0.05)

	if debug_show_colliders:
		_draw_debug_colliders(_debug_im)

	if debug_show_peer_proxy and _peer_proxy_indices.size() >= 3 and pos_data.size() >= _particle_count * 16:
		_draw_debug_peer_proxy(_debug_im, pos_data)

	_debug_im.surface_end()


# Adds wireframe outlines of every active collider (auto + manual) to the
# debug ImmediateMesh, in skel-local space. Cyan = auto-generated capsules
# (radii from the body mesh's bone weights), magenta = manually-authored
# GPUClothColliders. Both follow the bones at runtime because their
# endpoints are recomputed from get_bone_global_pose / collider.global_transform.
func _draw_debug_colliders(im: ImmediateMesh) -> void:
	var auto_color   := Color(0.2, 1.0, 1.0, 0.85)  # cyan — bone-axis capsules
	var sphere_color := Color(1.0, 0.85, 0.2, 0.7)  # yellow — body sphere cloud
	var manual_color := Color(1.0, 0.3, 0.9, 0.85)  # magenta — user-authored

	# Auto-collider capsules (rigged mode only — array is empty otherwise).
	if _use_skinning:
		for ac in _auto_colliders:
			var a_skel: Vector3 = _skeleton_node.get_bone_global_pose(ac.bone_a).origin
			var b_skel: Vector3 = _skeleton_node.get_bone_global_pose(ac.bone_b).origin
			_draw_capsule_wireframe(im, a_skel, b_skel, ac.radius, auto_color)
		# Sphere cloud — each sphere drawn as 3 orthogonal circles for clarity.
		for sp in _auto_spheres:
			var center: Vector3 = _skeleton_node.get_bone_global_pose(sp.bone) * sp.local_offset
			_draw_sphere_wireframe(im, center, sp.radius, sphere_color)

	# Manual GPUClothColliders — capsule and sphere only (skip boxes for now).
	var cloth_inv := _ref_node.global_transform.affine_inverse()
	for col in _colliders:
		if col.shape == GPUClothCollider.Shape.BOX:
			continue  # box wireframe not implemented here yet
		var floats := col.pack_collider_data(cloth_inv)
		var a := Vector3(floats[0], floats[1], floats[2])
		var b := Vector3(floats[4], floats[5], floats[6])
		var r: float = floats[3]
		_draw_capsule_wireframe(im, a, b, r, manual_color)

	# Body triangle collider — skin each tri's verts via single-bone dominant
	# weight (same path the GPU uses in _pack_collider_tris) and emit a 6-vertex
	# wireframe per triangle. Cache bone poses since many tris share a bone.
	if _use_skinning and _collider_tris.size() > 0:
		var tri_color := Color(0.4, 1.0, 0.4, 0.85)  # bright green — distinct from auto-capsules
		var bone_poses: Dictionary = {}
		for tri in _collider_tris:
			var pts: Array = []
			for v in tri:
				var bi: int = v.bone
				var pose: Transform3D
				if bone_poses.has(bi):
					pose = bone_poses[bi]
				else:
					pose = _skeleton_node.get_bone_global_pose(bi)
					bone_poses[bi] = pose
				pts.append(pose * v.local)
			im.surface_set_color(tri_color); im.surface_add_vertex(pts[0])
			im.surface_set_color(tri_color); im.surface_add_vertex(pts[1])
			im.surface_set_color(tri_color); im.surface_add_vertex(pts[1])
			im.surface_set_color(tri_color); im.surface_add_vertex(pts[2])
			im.surface_set_color(tri_color); im.surface_add_vertex(pts[2])
			im.surface_set_color(tri_color); im.surface_add_vertex(pts[0])


# Draws the peer-collision proxy mesh as a triangle-edge wireframe in
# ref-frame-local space (same coord system as the particle crosses, so it
# overlays them directly). Each proxy triangle's 3 edges are emitted as 6
# vertices for PRIMITIVE_LINES; duplicate shared edges are not coalesced
# (proxy tri count is already low so the doubled line cost is negligible).
func _draw_debug_peer_proxy(im: ImmediateMesh, pos_data: PackedByteArray) -> void:
	const PROXY_COLOR := Color(1.0, 0.55, 0.1, 0.85)  # orange — distinct from cyan/magenta colliders
	var tri_count: int = _peer_proxy_indices.size() / 3
	for t in tri_count:
		var i0: int = _peer_proxy_indices[t * 3 + 0]
		var i1: int = _peer_proxy_indices[t * 3 + 1]
		var i2: int = _peer_proxy_indices[t * 3 + 2]
		var p0 := Vector3(pos_data.decode_float(i0 * 16), pos_data.decode_float(i0 * 16 + 4), pos_data.decode_float(i0 * 16 + 8))
		var p1 := Vector3(pos_data.decode_float(i1 * 16), pos_data.decode_float(i1 * 16 + 4), pos_data.decode_float(i1 * 16 + 8))
		var p2 := Vector3(pos_data.decode_float(i2 * 16), pos_data.decode_float(i2 * 16 + 4), pos_data.decode_float(i2 * 16 + 8))
		im.surface_set_color(PROXY_COLOR); im.surface_add_vertex(p0)
		im.surface_set_color(PROXY_COLOR); im.surface_add_vertex(p1)
		im.surface_set_color(PROXY_COLOR); im.surface_add_vertex(p1)
		im.surface_set_color(PROXY_COLOR); im.surface_add_vertex(p2)
		im.surface_set_color(PROXY_COLOR); im.surface_add_vertex(p2)
		im.surface_set_color(PROXY_COLOR); im.surface_add_vertex(p0)


# Three orthogonal circles for a sphere wireframe. Cheap and unambiguous from
# any viewing angle.
func _draw_sphere_wireframe(im: ImmediateMesh, c: Vector3, r: float, color: Color) -> void:
	const SEGMENTS := 12
	var bases := [
		[Vector3.RIGHT, Vector3.UP],
		[Vector3.RIGHT, Vector3.FORWARD],
		[Vector3.UP,    Vector3.FORWARD],
	]
	for basis_pair in bases:
		var bx: Vector3 = basis_pair[0]
		var by: Vector3 = basis_pair[1]
		for i in SEGMENTS:
			var t0 := float(i)     * TAU / SEGMENTS
			var t1 := float(i + 1) * TAU / SEGMENTS
			im.surface_set_color(color); im.surface_add_vertex(c + bx * (cos(t0) * r) + by * (sin(t0) * r))
			im.surface_set_color(color); im.surface_add_vertex(c + bx * (cos(t1) * r) + by * (sin(t1) * r))


# Draws a capsule wireframe (two end-circles + 4 connecting lines + two
# hemisphere caps) into the given ImmediateMesh, in its current surface_begin
# call. Capsule axis is `a` → `b`; degenerate case (a == b) draws as a sphere.
func _draw_capsule_wireframe(im: ImmediateMesh, a: Vector3, b: Vector3, r: float, color: Color) -> void:
	const SEGMENTS := 16
	var axis: Vector3 = b - a
	var axis_len := axis.length()
	# Build a perpendicular basis (bx, by) to the axis.
	var axis_dir: Vector3
	if axis_len > 1e-5:
		axis_dir = axis / axis_len
	else:
		axis_dir = Vector3.UP
	var bx: Vector3 = axis_dir.cross(Vector3.UP)
	if bx.length_squared() < 0.01:
		bx = axis_dir.cross(Vector3.RIGHT)
	bx = bx.normalized()
	var by: Vector3 = axis_dir.cross(bx).normalized()

	# End circles (perpendicular to axis).
	for i in SEGMENTS:
		var t0 := float(i)       * TAU / SEGMENTS
		var t1 := float(i + 1)   * TAU / SEGMENTS
		var p0 := bx * (cos(t0) * r) + by * (sin(t0) * r)
		var p1 := bx * (cos(t1) * r) + by * (sin(t1) * r)
		im.surface_set_color(color); im.surface_add_vertex(a + p0)
		im.surface_set_color(color); im.surface_add_vertex(a + p1)
		if axis_len > 1e-5:
			im.surface_set_color(color); im.surface_add_vertex(b + p0)
			im.surface_set_color(color); im.surface_add_vertex(b + p1)

	# Connecting lines between the two end-circles at 4 quadrants (skip if
	# degenerate sphere case).
	if axis_len > 1e-5:
		for k in 4:
			var t := float(k) * PI * 0.5
			var off := bx * (cos(t) * r) + by * (sin(t) * r)
			im.surface_set_color(color); im.surface_add_vertex(a + off)
			im.surface_set_color(color); im.surface_add_vertex(b + off)

	# Hemisphere caps at each end (two semicircles per cap, in bx and by planes).
	var half_segs := SEGMENTS / 2
	for i in half_segs:
		var t0 := float(i)       * PI / half_segs
		var t1 := float(i + 1)   * PI / half_segs
		# Cap at a — curves AWAY from b (along -axis_dir).
		var ap0 := bx * (cos(t0) * r) + (-axis_dir) * (sin(t0) * r)
		var ap1 := bx * (cos(t1) * r) + (-axis_dir) * (sin(t1) * r)
		im.surface_set_color(color); im.surface_add_vertex(a + ap0)
		im.surface_set_color(color); im.surface_add_vertex(a + ap1)
		var aq0 := by * (cos(t0) * r) + (-axis_dir) * (sin(t0) * r)
		var aq1 := by * (cos(t1) * r) + (-axis_dir) * (sin(t1) * r)
		im.surface_set_color(color); im.surface_add_vertex(a + aq0)
		im.surface_set_color(color); im.surface_add_vertex(a + aq1)
		# Cap at b — curves AWAY from a (along +axis_dir).
		if axis_len > 1e-5:
			var bp0 := bx * (cos(t0) * r) + axis_dir * (sin(t0) * r)
			var bp1 := bx * (cos(t1) * r) + axis_dir * (sin(t1) * r)
			im.surface_set_color(color); im.surface_add_vertex(b + bp0)
			im.surface_set_color(color); im.surface_add_vertex(b + bp1)
			var bq0 := by * (cos(t0) * r) + axis_dir * (sin(t0) * r)
			var bq1 := by * (cos(t1) * r) + axis_dir * (sin(t1) * r)
			im.surface_set_color(color); im.surface_add_vertex(b + bq0)
			im.surface_set_color(color); im.surface_add_vertex(b + bq1)
