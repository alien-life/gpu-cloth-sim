# GPU Cloth Sim

GPU-accelerated cloth simulation for Godot 4.5+ using Position-Based Dynamics on compute shaders.

## Demo

![Demo](Demo/showcase.gif)

## Video Tutorial


[![Tutorial](https://img.youtube.com/vi/Ta_X90fqqZ4/hqdefault.jpg)](https://youtu.be/Ta_X90fqqZ4)

^^ click me

## Support
Join the discord for support :) -- https://discord.gg/maFsFAfqnY

## What's New in 3.0.0

Substrate rewrite plus a full body-and-cloth collision stack. The solver now simulates on *welded particles* with GPU-side normal computation and storage-texture mesh writeback (no more per-frame CPU mesh readback), and it can stack multiple cloth solvers that collide against each other AND against a character's animated body — silhouette-accurate. The fold-through artifacts that used to break flag normals are gone, the per-frame CPU stall is gone, and animated characters with shirts AND pants on the same skeleton just work. Six pieces compose:

- **GPU substrate** — particle positions, predicted positions, velocities, and normals all live in storage buffers; render meshes read positions + normals from storage textures bound to the vertex shader (`positions_tex` / `normals_tex` sampled via a `VERTEX_ID → welded_idx` lookup texture). No per-frame `ArrayMesh` writeback, no `_rd.sync()` stall — the GPU pipeline runs end-to-end, and the rendered mesh just samples the simulation's textures in the vertex stage. Compute passes compose freely without forcing readbacks: predict → constraints → collisions → update → normals → output, all in one command list.
- **Body-derived colliders, one mesh source.** A single `body_mesh` export feeds three independent collider techniques that each opt in via their own LOD knob: **auto-fitted bone capsules** (`auto_collider_lod`, fits one capsule per qualifying bone using bone-weighted vert distributions with percentile-trimmed radii), **sphere cloud** (`body_sphere_lod`, dense per-vert sphere coverage for irregular regions where capsules can't fit), and a **decimated skinned triangle mesh collider** (`body_collider_voxel_resolution`, voxel-clusters body verts to a low-poly proxy and skins each tri's verts via single-bone dominant weight per frame). Pick one for cheap bulk coverage, or stack them — the triangle mesh is silhouette-accurate where capsules approximate. Drives `cloth_skin_offset` so cloth particles physically sit off the body, plus a `body_collider_thickness` "padding" knob that controls the contact gap and `collider_friction` for Bridson Coulomb damping at every contact (kills the velocity injection that propagates as jitter through structural constraints).
- **Multi-cloth: peer cloth-cloth collision** — list other solvers in the `peer_cloth_solvers` array and each peer's *current* animated geometry becomes a triangle SDF collider for this solver. Peers share buffers via the main `RenderingDevice` (no copy, no per-frame readback), so a shirt-on-pants setup is just two solvers naming each other as peers. Each solver pre-builds a **decimated peer-collision proxy** (voxel-clustered welded particles, `peer_collider_voxel_resolution`) — peers bind the small proxy index buffer (typically 200-500 tris from a 6000-tri cloth) plus our full positions buffer, dropping per-frame cost by ~20× vs colliding against the full mesh. Per-frame cost = `peer_proxy_tri_count × our_particle_count`, dispatched once per substep.
- **Self-collision** — the same peer-proxy infrastructure pointed at self. Enable `self_collide` and each particle SDF-pushes out of its own decimated proxy mesh every substep, with the shader skipping triangles where the testing particle is a vertex (else infinite-direction push). Fold-through that used to break flag normals (overlapping faces averaged to zero in the normal accumulator, producing black holes) goes away because layers physically separate by `self_collide_thickness` (default 5 mm) instead of overlapping. Lets you crank `max_travel_distance` without tunneling artifacts.
- **Skinned-target sanitization** — once per frame, BEFORE the substep loop, a sanitizer pass pushes every particle's *skinned target* (the bone-driven position cloth attaches to) out of every active collider — body capsules, body triangle mesh, AND every peer cloth's current geometry. Kills the rest-jitter / rest-clipping cycle: without it, anchor positions sit inside the body or inside a peer cloth, every substep snaps pinned particles back into that volume, collide pushes them out, and the cycle propagates structurally as visible jitter. With it, anchor positions are always reachable from outside collider volumes; rest is genuinely at rest.
- **Per-particle thickness** — both peer and body collide passes multiply the base thickness by per-particle `cloth_weight` (the same vertex-color value that drives attachment stiffness). Pinned particles (weight 0) contribute zero thickness so they don't fight their snapped anchor; blend-zone particles (weight 0.3-0.7) get proportionally less push; fully-free particles (weight 1) get the full base thickness. Without this, the attachment-region "tight chest" verts kept pushing themselves out of the body and away from their pin targets — the same blend channel now correctly suppresses self-push where the cloth is meant to be attached.

> **Authoring model in v3.0:** vertex-color channel R = **cloth weight** (0 = anchored to skinned target, 1 = free PBD); `Marker3D` pins are **orthogonal** to weights (a particle can be pinned to a marker AND have a free cloth weight, in which case the marker overrides the skinned target). Pick a channel via `cloth_weight_channel`. Anchored verts (weight near 0) are inverse-mass 0 in the solver.

> **Debug:** `debug_show_particles` (colored crosses + velocity vectors), `debug_show_colliders` (cyan capsules, yellow sphere cloud, green body triangle mesh, magenta manual colliders, all in their current animated pose), and `debug_show_peer_proxy` (orange wireframe of the cloth-cloth proxy mesh deforming with the simulation in real time) — leave the collider overlay on while tuning.

> **Migration:** `flip_normals` default is now `true` — Blender/glTF round-trips overwhelmingly land here producing inward right-hand-rule normals, and four out of five existing scenes already set it true. A single existing scene that relied on `false` (`Demo/Assets/LowPolyDude/low_poly_dude.tscn`) now sets it explicitly. The old separate `body_collider_mesh` export was collapsed into `body_mesh` — set `body_collider_voxel_resolution > 0` to opt into the triangle mesh collider.

## What's New in 2.1.0

Bone-driven attachment + per-vertex sim mask. Drop a skinned cape into the solver, paint a mask layer in Blender saying "rigid here, free here," and the solver does the right thing on the same mesh — collar tracks the spine bone every frame, hem swings under gravity, smooth blending in between. The standard production-cloth pipeline, with no in-engine UI required. Three pieces compose:

- **Bone bindings from imported mesh.** New `skeleton: NodePath` export. The solver reads `ARRAY_BONES`/`ARRAY_WEIGHTS` from the source mesh, captures each bone's init pose in solver-local space, and per frame uploads `Skeleton3D.get_bone_global_pose(b)` to a small mat4 buffer. A new compute pass (`cloth_skinning.glsl`) skins each particle's *attachment target* per substep — same compute primitive as the v1.4 fishing-line pass, just with bone matrices replacing pin positions.
- **Continuous sim mask** painted as a vertex color attribute. New `sim_mask_from_vertex_color` + `sim_mask_channel` exports. `mask = 0` (paint black) → particle rigidly follows its skinned target every frame. `mask = 1` (paint white) → free PBD simulation, bounded by `skin_attach_radius`. Smooth values lerp the attachment stiffness — this is the keystone for "tight chest, loose hem on the same garment." The continuous mask subsumes v2.0's binary `pin_from_vertex_color`, which is now deprecated and forwards to the new path with threshold-0.5 binarization.
- **Same mask, three target sources.** When `skeleton` is wired, the target is bone-driven. When `pin_targets` (`Marker3D`s) are set instead, the target is the K-nearest pin blend. When neither is wired, the target is the particle's init local position. The mask interpretation is identical across all three regimes — lets you drop a painted cape in the solver and see the mask working before you wire up a skeleton, then add the skeleton incrementally.

> **Migration:** `pin_from_vertex_color` keeps working with a deprecation warning. Note the semantic flip when migrating: the old "high channel value = pinned" became "low channel value = rigid" in the continuous mask. If you painted *white-where-pinned* in Blender for v2.0, you'll want to invert that channel for the new continuous mask (or just keep using the deprecated path until you re-paint).

## Blender Authoring Pipeline

The end-to-end workflow for a skinned cape (or any garment):

1. **Model the garment** in Blender. Standard modelling — keep topology cloth-friendly (avoid degenerate triangles), UV unwrap normally.
2. **Rig.** Parent the garment to your character's existing armature (`Object → Parent → With Empty Groups` if you'll paint weights manually). For a cape you typically need 1-3 bones (spine top, neck, optionally a controller for the cape itself).
3. **Weight paint bones.** Standard Blender Weight Paint mode. Paint full weight to the parent bone(s) on the **collar / attachment region**. Leave the **simulation region** unweighted — those particles aren't bone-driven, they'll be pure simulation.
4. **Add the `cloth_weight` vertex color layer.**
   - In `Object Data Properties → Color Attributes`, add a new `Face Corner ▸ Byte Color` attribute named `cloth_weight`. (Float Color works too; both export to `.glb` as vertex color.)
   - Switch to Vertex Paint mode, select the new attribute as the active one.
   - **Paint black** (R = 0) where the cloth should rigidly follow bones (collar, chest panel — the bone-weighted region from step 3).
   - **Paint red / white** (R = 1) where the cloth should freely simulate (hem, sleeves — the unweighted region).
   - **Paint mid-red** for soft attachment falloff (the transition strip between rigid and free, typically 1-3 cm wide).
   - The mask reads the **red channel** by default. Paint into R or override via the solver's `cloth_weight_channel` export (0=R, 1=G, 2=B, 3=A).
5. **Export `.glb`** with Mesh + Armature. Tick "Vertex Colors" and "Skinning" in the export panel.
6. **In Godot:** add a `GPUClothSolver` node. Set `target_mesh` to the imported `MeshInstance3D`. Set `skeleton` to the imported armature's `Skeleton3D` node. Confirm `cloth_weight_channel` matches the channel you painted. Run.

Mental model: **bone weights say *where* the cloth attaches; the cloth_weight says *how rigidly*.** They're orthogonal channels of authoring intent. The weight mask works without a skeleton too — useful for debugging the painting before wiring up rigging — in which case `cloth_weight = 0` particles freeze at their init local position and `cloth_weight = 1` particles simulate freely. `Marker3D` pins listed in `pin_targets` are a third orthogonal channel: they override the skinned target of the nearest particle regardless of cloth_weight.

## What's New in 2.0.0

Custom-mesh source. The solver no longer hardcodes a planar grid — assign any `Mesh` resource (imported `.gltf`/`.fbx`/`.obj` or a programmatic `ArrayMesh`) to the new `source_mesh` export and the cloth simulates on that mesh's actual topology. UV seams persist; pins can be painted in Blender via vertex color; bending behaviour is derived from edge-shared triangle pairs. Five things compose to make this work:

- **Vertex welding** — imported meshes duplicate vertices at UV seams and hard-normal edges (same world position appears 2-6 times). Without welding the simulation tears apart at every seam. The solver spatial-hashes positions, checks neighboring cells by true distance against `weld_epsilon`, and collapses coincident verts into a unique particle set while keeping a remap from original render slots to welded particles.
- **Topology-driven constraints** — structural constraints are emitted from each unique edge in the welded mesh, with rest distance set from the initial Euclidean separation. Bending constraints come from edge-shared triangle pairs (the two non-shared vertices) instead of the v1.x grid-specific "skip-one" pattern. Toggle via `bending_from_topology`.
- **Runtime graph coloring** — source-mesh constraints are colored at init. A greedy coloring pass walks the constraint list and places each constraint into the first group whose vertex set doesn't already contain either endpoint. The solver dispatch loop iterates `_constraint_groups` so arbitrary topology produces correct race-free dispatches.
- **Render-vertex preservation** — the simulation runs on welded particles but rendering uses the input mesh's original vertex slots, indices, and UVs. Two slots on either side of a UV seam map to the same particle (so they get the same world position) but keep their distinct UVs and per-face normals. Tangents are recomputed per-frame from UV gradients.
- **Vertex-color pin authoring** — flip `pin_from_vertex_color`, set a channel + threshold, and weight-paint a pin mask in Blender. Welded particles whose source vertices exceed the threshold are marked `inverse_mass = 0`. `pin_targets` (`Marker3D` based) still works for dynamic anchors.

> **Compatibility:** existing scenes with no `source_mesh` assigned keep the original `cloth_width × cloth_height` grid path unchanged. `pin_top_row` is honoured only on the grid path; with a `source_mesh` it's ignored (with a warning).

## What's New in 1.4.0

The fishing-line constraint matures from "single nearest pin" into a properly generalized binding system. Three changes that compose:

- **Velocity-aware projection** — when the fishing-line constraint clamps a particle to its boundary sphere, the outward radial component of velocity is now zeroed. Pure tangential motion is preserved. Previously the particle would buzz against the boundary every frame because its outward velocity kept pushing it back outside; now it slides along the boundary like a real piece of fabric reaching the end of its tether. Subtle visually but kills a real source of high-frequency jitter.
- **Per-particle stretch via `stretch_curve`** — a new optional `Curve` resource lets you author "stiff at the pin row, looser at the hem" with one curve. Sampled by `row_index / (cloth_height - 1)`, so curve `t = 0` is the top row and `t = 1` is the bottom. When unassigned (or the curve has no points), falls back to the scalar `fishing_stretch`. Stretch is baked into the bindings buffer at init, so per-particle authoring costs zero runtime.
- **K-nearest binding** — each free particle is now bound to its `K` nearest pins (default `K = 4`) with weights inversely proportional to rest distance. The constraint clamps to the *weighted blend* of pin positions, with a *weighted blend* of per-binding max distances. Eliminates the "Voronoi seam" artifact you'd see between regions assigned to different pins on a cloth with multiple pins. `K = 1` reproduces v1.3 behaviour. Each step of `K` adds 16 bytes per particle to the binding buffer; cost is dominated by the cloth size, not `K`.

> **API note:** the old `fishing_stretch` scalar still works as the default. `stretch_curve` is opt-in. `bindings_per_particle` defaults to 4 — if you want the v1.3 single-anchor behaviour exactly, set it to 1.

## What's New in 1.3.1

- **World-down gravity fix** — gravity used to be applied in solver-local space, so rotating the `GPUClothSolver` node in the world tilted "down" with it (a 90° roll made cloth fall sideways). The CPU now transforms world-space gravity into solver-local each frame before pushing it to the predict shader, the same way wind has always worked. Push constant grew from 64 to 80 bytes; all four core compute shaders updated to match.
- **Surface shader documentation** — the procedural fabric shader (silk / linen / lava, borders, emblems, grunge, wear, shape mask, voxel-AO consumer) is no longer a one-line bullet in the README. Full uniform reference now lives in the [Cloth Surface Shader](#cloth-surface-shader) section.

## What's New in 1.3.0

- **Fishing-line anchor constraint** — borrowed from the Ghost of Tsushima cloth pipeline. PBD's spring network propagates tension one link per iteration, so a tall cape's bottom row keeps drooping for several frames before the top pin "tells" it to stop. The fishing line precomputes each particle's nearest pin and rest distance, then hard-clamps every free particle to within `fishing_stretch × rest_distance` of that pin's *current* position each substep — propagating tension in O(1) instead of O(grid). Lets stiff cloth actually feel stiff at low iteration counts. One extra compute pass, ~particle_count threads, no graph-coloring needed (each thread reads only its own anchor's position). Disable via `enable_fishing_line` if you want pure PBD behaviour.

## What's New in 1.2.0

- **Per-particle voxel ambient occlusion** — a 5th compute pass voxelizes the cloth's particles into a small bit-packed grid (default 32×32×16) each frame, then samples a neighborhood per particle to compute occlusion. The result is read back alongside positions, written to vertex `COLOR.r` (visibility), and consumed by the surface shader as Godot's `AO` builtin output. Folds darken naturally with no screen-space noise, view-independent, ~0.2 ms on a mid-range GPU.
- **Double-sided lighting fix** — back-face normal-map handling now flips the tangent-space z component so cloth back faces light correctly. Previously the procedural fabric normal pointed the wrong way on the side facing away from the camera/light, producing flat or wrong shading.

## What's New in 1.1.0

- **Procedural fabric surface shader** — silk, linen, and animated lava fabric types with primary/secondary tint, border trim (per-edge bitmask), emblem layer, dirt, and edge wear. Replaces the previous minimal default shader.
- **Shape-mask UV cutout** — bind a `sampler2D` to `shape_mask` and the fragment shader `discard`s where the red channel falls below `shape_mask_threshold`. Lets you cut non-rectangular cloth shapes (banners, ragged hems, perforations) without changing the simulation grid.
- **Async GPU readback** — the solver now submits compute work and defers the `_rd.sync()` to the next physics frame, so the GPU pipelines simulation against the next frame's CPU work instead of stalling.
- **Smoothed pin tracking** — pins lerp toward their marker target each frame instead of teleporting, eliminating cloth snap when markers move quickly. Tunable via `pin_smooth_speed`.
- **Explicit collider list** — new `collider_targets: Array[NodePath]` lets the solver track colliders that aren't direct children (e.g. bones in a skeleton). Falls back to child auto-discovery when empty.
- **Numerical stability fixes** — inertia magnitude clamped per substep to prevent cloth collapse on fast parent motion; constraint solver falls back to a gravity-axis correction direction when particles fully collapse instead of producing NaNs.

> **Migration note:** the new default shader uses different uniform names (`fabric_type`, `primary_color`, `secondary_color`, etc.). The old `albedo_texture` / `color_tint` uniforms no longer exist. Existing scenes that wired those will need their `shader_parameter/*` fields updated.

## Features

- **Full GPU pipeline** — predict, constraint solve, collision, normal computation, and mesh output all run as compute shaders; no per-frame CPU mesh readback (render meshes sample positions/normals from storage textures bound to the vertex shader)
- **Position-Based Dynamics** with graph-colored constraint solving — no race conditions, no atomics, fully parallel per constraint group
- **Multi-cloth interaction** — list other solvers in `peer_cloth_solvers` and they collide against each other's current animated geometry every substep via decimated proxy meshes (~20× cheaper than colliding against full mesh). Shared `RenderingDevice` buffer sharing, no per-frame copy or readback. Symmetric setup: name peers on both sides for two-way interaction
- **Self-collision** — enable `self_collide` to push each particle out of its own decimated proxy mesh every substep. Fixes fold-through artifacts on flags/capes/skirts without limiting `max_travel_distance`
- **Body-derived colliders** — point `body_mesh` at any skinned MeshInstance3D and opt into three independent techniques via their own LOD knobs: auto-fitted bone capsules (percentile-trimmed radii), per-vert sphere cloud for irregular regions, and a voxel-decimated triangle mesh collider that's silhouette-accurate. All three can stack
- **Bridson Coulomb friction** at every contact — damps tangential motion at body / peer / self contacts by `μ × push_magnitude`, killing the velocity injection that propagates as jitter through structural constraints. Tunable via `collider_friction`
- **Skinned-target sanitization** — once-per-frame pre-substep pass projects each particle's bone-driven anchor position out of all active colliders (body capsules + body triangle mesh + every peer cloth's current geometry), eliminating rest-jitter from anchors trapped inside collider volumes
- **Per-particle thickness** — collide thickness scales by the per-particle `cloth_weight` value, so attachment-region particles (weight near 0) don't fight their snapped anchors while free particles (weight 1) get the full thickness
- **Manual collision primitives** — sphere, capsule, and oriented bounding box (OBB) via `GPUClothCollider` nodes
- **Inertia system** — cloth naturally trails behind parent node movement
- **Wind** with organic turbulence via sum-of-sines at irrational frequency ratios
- **Structural, diagonal, and bending constraints** for controllable stiffness vs. drape
- **Pin targets** — pin particles to `Marker3D` nodes with per-pin smoothing to prevent snap on fast motion. Marker pins are orthogonal to the vertex-color cloth-weight channel — pinned particles override their skinned target
- **Fishing-line constraint with K-nearest weighted blending** — Ghost-of-Tsushima-style hard distance clamp from each particle to the weighted blend of its K nearest pins (default K=4). Tension propagates instantly across the cloth instead of one spring-link per iteration. Per-row stretch authoring via optional `Curve` resource. Velocity-aware projection zeros outward radial velocity at the boundary so cloth slides instead of buzzes
- **First-class procedural fabric shader** — ships as the default material on every solver, no setup required. Three fabric types (silk with directional sheen streaks, linen with basket-weave warp/weft, animated lava with domain-warped FBM cracks and emission), each with matching procedural normal maps. Configurable primary/secondary colors with full PBR knobs (roughness, metallic, specular). Border trim with per-edge bitmask (any combination of left/right/top/bottom) and optional glow. Heraldic emblem layer (place any texture, three blend modes). Two-channel grunge — gradient + edge + noise dirt, plus edge wear that brightens fabric near hems. Lava-specific controls for crack scale, flow speed, octave count, emission strength
- **Shape-mask cutout** — bind a `sampler2D` to `shape_mask` and the fragment shader `discard`s where the red channel falls below `shape_mask_threshold`. Lets you cut non-rectangular cloth shapes (banners, ragged hems, pennants, perforations) without changing the simulation mesh. UV scale + offset uniforms let you tile or position the mask
- **Drop-in custom material** — every uniform on the default shader is exposed in the inspector, but you can replace it entirely by assigning anything to `cloth_material`. The substrate group (`positions_tex`, `normals_tex`, `welded_index_tex`) is what custom shaders bind to read the GPU-simulated state in their vertex stage
- **Editor preview + runtime debug overlays** — solver/collider gizmos drawn in the editor viewport (`@tool`). At runtime: `debug_show_particles` (colored crosses + velocity vectors, red=anchored / green=free), `debug_show_colliders` (cyan capsules, yellow sphere cloud, green body triangle mesh, magenta manual colliders — all in their current animated pose), `debug_show_peer_proxy` (orange wireframe of the cloth-cloth proxy deforming with the simulation in real time)
- **Double-sided rendering** with proper back-face normal-map handling

## Requirements

- **Godot 4.5+**
- **Vulkan renderer** (Forward+ or Mobile) — compute shaders require it. The Compatibility (OpenGL) renderer is not supported.

## Installation

The easiest path is the prebuilt plugin zip — addon code only, ~100 KB:

1. Grab `gpu_cloth_sim.zip` from the repo root (or download a release).
2. In Godot: `AssetLib` tab → top-right install icon → pick the zip → install into your project. Drops everything into `addons/godot_gpu_cloth/`.
3. `Project → Project Settings → Plugins`, tick **GPU Cloth Sim**.

To explore the demo scenes (animated human in shirt + pants, low-poly cat, flag, capes), clone the full repo — the `Demo/` folder ships the assets that aren't bundled in the plugin zip (it's ~600 MB of skinned meshes + textures, intentionally kept out of the install zip).

### Rebuilding the ZIP

To rebuild `gpu_cloth_sim.zip` from the repo root after changes:

```bash
zip -r gpu_cloth_sim.zip addons/ LICENSE README.md -x "*.import" "*.uid" "*.DS_Store"
```

Plugin-only — `Demo/` is intentionally excluded for download size. Godot regenerates `.import` and `.uid` files on first project load, so excluding them is safe and produces a smaller zip.

## Quick Start

1. Add a **GPUClothSolver** node, set `target_mesh` to a `MeshInstance3D` whose mesh you want to simulate (any `.glb`/`.fbx`/`.obj` import or programmatic `ArrayMesh`).
2. *(Rigged cloth only)* Set `skeleton` to the `Skeleton3D` driving the mesh — bone weights from the imported mesh automatically become per-particle attachment targets.
3. Paint a **cloth weight** layer in Blender as a vertex color: weight 0 = anchored to skinned target, weight 1 = free PBD; smooth values blend. Pick which channel via `cloth_weight_channel` (default R).
4. *(Optional)* Add `Marker3D` children and list them in `pin_targets` for dynamic anchors that override the skinned target. Or add **GPUClothCollider** children for manually-placed sphere/capsule/box collision.
5. *(Optional, rigged)* Point `body_mesh` at the character's body and pick a collider technique: `auto_collider_lod > 0` for bone capsules, `body_sphere_lod > 0` for sphere cloud, `body_collider_voxel_resolution > 0` for the decimated triangle mesh. Stack any combination.
6. *(Optional, multi-cloth)* List other solvers in `peer_cloth_solvers` for cloth-on-cloth, or flip `self_collide = true` to prevent fold-through.
7. Run.

## GPUClothSolver Properties

The properties below are the headline knobs. **Every export has a full long-form docstring visible in the Godot inspector** — hover the property name for the detailed explanation, edge cases, and tuning advice. The summary here is intentionally compact.

### Mesh Input

| Property | Type | Default | Description |
|---|---|---|---|
| `target_mesh` | `NodePath` | `(empty)` | `MeshInstance3D` to simulate. Any `.glb`/`.fbx`/`.obj` import or programmatic `ArrayMesh` works. |
| `skeleton` | `NodePath` | `(empty)` | `Skeleton3D` driving `target_mesh` (rigged-mode). When set, the mesh's `ARRAY_BONES`/`ARRAY_WEIGHTS` become per-particle skinned attachment targets. Unset = unrigged mode, cloth attaches to its own initial local position. |
| `weld_epsilon` | `float` | `0.001` | Vertex coalescing tolerance — duplicates at UV seams / hard normals within this distance collapse to one simulated particle. |
| `cloth_weight_channel` | `int` (0–3) | `0` | Which vertex-color channel carries the cloth-weight mask (R/G/B/A). 0 = anchored to skinned target, 1 = free PBD, smooth blend in between. |

### Physics

| Property | Type | Default | Description |
|---|---|---|---|
| `gravity` | `Vector3` | `(0, -9.8, 0)` | World-space gravity. Authored in world, transformed into solver-local each frame. |
| `solver_iterations` | `int` (1–32) | `8` | Constraint solver passes per substep. |
| `substeps` | `int` (1–32) | `8` | Physics substeps per frame. |
| `stiffness` | `float` (0–1) | `0.5` | Structural constraint stiffness. |
| `bend_stiffness` | `float` (0–1) | `0.1` | Bending constraint stiffness. |
| `bending_from_topology` | `bool` | `true` | Build bending constraints from edge-shared triangle pairs. Off = structural only, very droopy cloth. |
| `damping` | `float` (0–1) | `0.99` | Velocity damping per substep. |
| `max_speed` | `float` | `5.0` | Per-particle velocity clamp. |
| `max_travel_distance` | `float` | `0.1` | Per-substep position-delta clamp. Crank with `self_collide` on to allow snappy cloth without tunneling. |

### Pinning + Fishing Line

| Property | Type | Default | Description |
|---|---|---|---|
| `pin_targets` | `Array[NodePath]` | `[]` | `Marker3D` nodes that override the skinned target of the nearest particle. Orthogonal to `cloth_weight_channel`. |
| `pin_smooth_speed` | `float` | `20.0` | Lerp speed for pin tracking. 0 = freeze at init. |
| `enable_fishing_line` | `bool` | `true` | Hard-clamp each free particle to `stretch × rest_distance` of its K-nearest pin blend. Tension propagates in O(1) per particle. Skipped if no pins. |
| `fishing_stretch` | `float` | `1.02` | Default stretch multiplier (fallback when `stretch_curve` unset). 1.0 = inelastic. |
| `stretch_curve` | `Curve` | `null` | Optional per-row stretch override. `t=0` = top, `t=1` = bottom. |
| `bindings_per_particle` | `int` (1–8) | `4` | How many nearest pins each particle weights against. K=1 = v1.3 behaviour, K=4 = smooth blends. |

### Colliders (body)

| Property | Type | Default | Description |
|---|---|---|---|
| `collider_targets` | `Array[NodePath]` | `[]` | Manually-placed `GPUClothCollider` nodes (sphere/capsule/box). When empty, auto-discovers children. |
| `body_mesh` | `NodePath` | `(empty)` | Single source mesh for all three body-derived collider techniques below. Rigged-mode only. |
| `auto_collider_lod` | `int` (0–3) | `0` | 0 = off, 1-3 = bone-weight threshold for auto-fitted capsules. ~6-40 capsules depending on level. |
| `body_sphere_lod` | `int` (0–3) | `0` | 0 = off, 1-3 = sphere-cloud density. Per-vert spheres for irregular regions. |
| `body_collider_voxel_resolution` | `int` (0–128) | `0` | 0 = off, > 0 = decimation grid resolution for the triangle mesh collider (silhouette-accurate). |
| `body_collider_thickness` | `float` (0.001–0.1) | `0.01` | Outward push distance for the triangle mesh collider — the cloth-to-body gap. |
| `collider_friction` | `float` (0–1) | `0.3` | Bridson Coulomb μ at every contact (body + peer + self). 0 = slip, 0.3 = light, 0.7 = sticky. |

### Multi-cloth + Self-collision

| Property | Type | Default | Description |
|---|---|---|---|
| `peer_cloth_solvers` | `Array[NodePath]` | `[]` | Other `GPUClothSolver`s whose current geometry this solver should collide against. Symmetric: name both ways for two-way interaction. |
| `peer_collider_voxel_resolution` | `int` (0–64) | `12` | Decimation resolution for the proxy mesh peers (and self) bind. 0 = no proxy (full mesh, much more expensive). |
| `self_collide` | `bool` | `false` | Enable cloth-on-self collision using this solver's own proxy mesh. Fixes flag/cape fold-through. |
| `self_collide_thickness` | `float` (0.001–0.05) | `0.005` | Gap layers separate by when they meet. Also the resting "puff" above the cloth's own surface. |

### Appearance + Inertia + Wind

| Property | Type | Default | Description |
|---|---|---|---|
| `cloth_material` | `Material` | `null` | Override material (default: built-in procedural fabric shader). |
| `flip_normals` | `bool` | `true` | Negate computed normals — matches the common Blender/glTF round-trip winding. Set false for meshes that already produce outward right-hand-rule normals. |
| `cloth_render_offset` | `float` | `0.0` | Visual-only outward shell extrusion. Hides body-poke-through without touching physics. |
| `cloth_skin_offset` | `float` (0–0.1) | `0.0` | Physical outward offset applied to particles at init. Pairs with `cloth_render_offset`. |
| `inertia_scale` | `Vector3` | `(1,1,1)` | How strongly cloth resists parent translation per axis. |
| `rotational_inertia_scale` | `float` (0–1) | `1.0` | How strongly cloth resists parent rotation. |
| `wind` | `Vector3` | `(0,0,0)` | World-space wind direction + strength. |
| `wind_turbulence` | `float` (0–2) | `0.3` | Wind gust intensity. |
| `wind_frequency` | `float` | `1.0` | Wind gust speed. |

### Debug

| Property | Type | Default | Description |
|---|---|---|---|
| `debug_show_particles` | `bool` | `false` | Colored cross at every particle (red = anchored, green = free) + yellow velocity vectors. Forces a GPU readback each frame — leave off for perf. |
| `debug_show_colliders` | `bool` | `false` | Wireframes of every active collider in its current animated pose. Cheap (uses CPU bone poses). |
| `debug_show_peer_proxy` | `bool` | `false` | Orange wireframe of the cloth-cloth proxy mesh deforming with the simulation. |

## GPUClothCollider Properties

| Property | Type | Default | Description |
|---|---|---|---|
| `shape` | `SPHERE` / `CAPSULE` / `BOX` | `CAPSULE` | Collision primitive type |
| `radius` | `float` | `0.3` | Sphere/capsule radius |
| `height` | `float` | `1.6` | Capsule total height |
| `extents` | `Vector3` | `(0.5,0.5,0.5)` | Box half-extents |
| `target` | `NodePath` | | Optional node to track transform from |

## Cloth Surface Shader

Every `GPUClothSolver` ships with a procedural fabric shader as its default material. No texture authoring required — three fabric types, full PBR controls, border trim, emblem placement, grunge/wear, animated lava, and shape-mask cutout are all driven by inspector uniforms. To use a custom shader, assign anything to the solver's `cloth_material` and the default is bypassed; custom shaders bind the `substrate` group (`positions_tex`, `normals_tex`, `welded_index_tex`) to read the GPU-simulated state in their vertex stage.

The shader file is at `addons/godot_gpu_cloth/shaders/cloth_surface.gdshader`. Uniforms are organized into inspector groups:

### Fabric

| Uniform | Type | Default | Description |
|---|---|---|---|
| `fabric_type` | `int` (0–2) | `1` | `0 = Lava`, `1 = Silk`, `2 = Linen`. Switches both the procedural albedo function and the matching procedural normal map |
| `fabric_scale` | `float` (1–100) | `30.0` | Spatial frequency of the fabric pattern. Higher = finer weave / tighter sheen streaks |
| `fabric_normal_intensity` | `float` (0–2) | `0.5` | Strength of the procedural normal map (driven into Godot's `NORMAL_MAP_DEPTH`) |

### Colors

| Uniform | Type | Default | Description |
|---|---|---|---|
| `primary_color` | `vec4` | dark plum | Base fabric tone. For lava, this is the cool stone; for silk/linen, the unlit/recessed thread color |
| `secondary_color` | `vec4` | bright purple | Highlight tone. For lava, the glowing crack color (also used for emission tint); for silk/linen, the lit/raised thread color |

### PBR

| Uniform | Type | Default | Description |
|---|---|---|---|
| `base_roughness` | `float` (0–1) | `0.75` | Base roughness before per-pixel modulation by the fabric pattern, dirt, and wear |
| `metallic` | `float` (0–1) | `0.0` | Metallic factor. Cloth is usually 0; bump up for foiled/silver-thread looks |
| `specular` | `float` (0–1) | `0.3` | Standard Godot specular |

### Border

| Uniform | Type | Default | Description |
|---|---|---|---|
| `border_width` | `float` (0–0.15) | `0.04` | Border thickness in UV units |
| `border_color` | `vec4` | gold | Border tint |
| `border_sharpness` | `float` (0–1) | `0.7` | `0` = soft fade, `1` = hard edge |
| `border_glow` | `float` (0–2) | `0.3` | Border emission multiplier |
| `border_edge_mask` | `int` (0–15) | `7` | Bitmask of edges to draw on. `1=left, 2=right, 4=bottom, 8=top`. Sum the bits for combinations (e.g. `4` for hem-only, `15` for all four edges) |

### Emblem

| Uniform | Type | Default | Description |
|---|---|---|---|
| `emblem_texture` | `sampler2D` | unbound | Heraldic / decal texture. Detected as unbound when smaller than 4 px and skipped automatically |
| `emblem_center` | `vec2` | `(0.5, 0.45)` | UV-space placement of the emblem center |
| `emblem_scale` | `vec2` | `(0.3, 0.3)` | UV-space size of the emblem |
| `emblem_tint` | `vec4` | gold | Multiplied into the sampled texture color |
| `emblem_opacity` | `float` (0–1) | `1.0` | Master opacity; multiplied with the emblem texture's alpha |
| `emblem_blend_mode` | `int` (0–2) | `0` | `0 = Replace`, `1 = Overlay`, `2 = Additive` |

### Grunge / Dirt

| Uniform | Type | Default | Description |
|---|---|---|---|
| `dirt_amount` | `float` (0–1) | `0.3` | Master multiplier on all three dirt sources |
| `dirt_color` | `vec4` | dark brown | Color the fabric is tinted toward |
| `dirt_gradient_power` | `float` (0.5–5) | `2.0` | Curve of the bottom-hem dirt gradient; higher = more concentrated at the hem |
| `dirt_edge_width` | `float` (0–0.2) | `0.08` | UV-distance over which edge dirt fades in |
| `dirt_noise_scale` | `float` (1–20) | `5.0` | Spatial frequency of procedural grime patches |
| `dirt_noise_intensity` | `float` (0–1) | `0.4` | Weight of the noise-based dirt source |
| `dirt_roughness_boost` | `float` (0–0.5) | `0.15` | Dirty regions get rougher by this much |

### Wear

| Uniform | Type | Default | Description |
|---|---|---|---|
| `wear_amount` | `float` (0–1) | `0.15` | Strength of the wear effect (brightens fabric near edges, simulating bleached/threadbare hems) |
| `wear_noise_scale` | `float` (1–30) | `12.0` | Spatial frequency of the wear noise mask |
| `wear_edge_width` | `float` (0–0.15) | `0.06` | UV-distance over which wear fades from edges into the body |

### Lava (only when `fabric_type = 0`)

| Uniform | Type | Default | Description |
|---|---|---|---|
| `lava_speed` | `float` (0–2) | `0.3` | Animation speed of the warped FBM cracks |
| `lava_crack_scale` | `float` (1–20) | `6.0` | Spatial frequency of the crack pattern |
| `lava_noise_octaves` | `int` (2–5) | `3` | FBM octave count. More = richer detail at the cost of fragment cost |
| `lava_emission` | `float` (0–5) | `2.0` | Brightness of the glowing-crack emission. The emission color comes from `secondary_color` |

### Shape

| Uniform | Type | Default | Description |
|---|---|---|---|
| `shape_mask` | `sampler2D` | unbound | Texture whose red channel cuts out non-rectangular shapes (banners, pennants, ragged hems). Detected as unbound when smaller than 4 px and skipped automatically |
| `shape_mask_threshold` | `float` (0–1) | `0.5` | Red value below which fragments are `discard`ed |
| `shape_mask_uv_scale` | `vec2` | `(1, 1)` | Scale the cloth UVs before sampling the mask. Useful for tiling/centering |
| `shape_mask_uv_offset` | `vec2` | `(0, 0)` | Offset added after the scale |

> The voxel-AO consumer that lived here in 1.2.x–2.x was removed in the v3 substrate rewrite (the per-frame voxelize + sample compute passes assumed a per-frame CPU readback that the new GPU-only pipeline no longer does). Folds still self-shadow via standard lighting; SSAO at the camera level remains the recommended fill. A re-implementation that fits the new substrate is on the v3.1 backlog.

## How It Works

Each frame, the solver runs an end-to-end GPU pipeline inside a single command list — no per-frame CPU mesh readback, no `_rd.sync()` stall. The rendered mesh's vertex shader samples `positions_tex` / `normals_tex` (written by the output pass) via a `welded_index_tex` lookup, so the simulation feeds rendering directly through storage textures.

```
once per frame, BEFORE substeps:
    SKIN              →  bone-skin each particle's attachment target (mat4 · rest_offset)
    SANITIZE          →  push every skinned target out of body + peer cloth volumes (kills rest jitter)

for each substep:
    PREDICT           →  apply gravity, wind, inertia offset; clamp to max_travel_distance
    for each iter:
      SOLVE           →  PBD distance constraints (graph-colored groups + barriers)
      COLLIDE         →  manual collider primitives (sphere/capsule/box)
      COLLIDE_TRIS    →  body triangle mesh collider (skinned per frame, SDF push + friction)
    FISHING           →  K-nearest pin clamp (optional, when pins exist)
    COLLIDE_PEER × N  →  one dispatch per peer cloth solver (SDF push against decimated proxy)
    COLLIDE_SELF      →  cloth-on-self via own decimated proxy (optional)
    UPDATE            →  recover velocity from position delta, lerp toward skinned target, damping

after substep loop:
    NORMALS  →  face normals per triangle (rest-aware sign correction)
    OUTPUT   →  accumulate per-vertex normals, write positions_tex + normals_tex
```

**Welded particle substrate.** At init, the input mesh's vertices are coalesced by a spatial hash + distance check (`weld_epsilon`) so duplicates at UV seams or hard-normal edges collapse into one simulated particle. Each unique edge becomes a structural constraint; each edge-shared triangle pair becomes a bending constraint between the two non-shared vertices. Rendering uses the original (un-welded) vertex slots, indices, and UVs — the welded layer is purely simulation. The render mesh's vertex shader does a two-step lookup: `VERTEX_ID → welded_idx` (via `welded_index_tex`), then `welded_idx → position/normal` (via `positions_tex`/`normals_tex`). UV seams persist visually because two slots either side of a seam map to the same welded particle, getting the same position but keeping their distinct UVs and per-face tangents.

**Graph-colored constraint solving.** Constraints are colored at init with a greedy pass — each constraint goes into the first group whose vertex set doesn't already contain either endpoint. No two constraints in a group share a particle, so each group dispatches race-free without atomics. Barriers between groups, no global sync.

**Skinning pass.** When `skeleton` is set, at init the solver reads `ARRAY_BONES` + `ARRAY_WEIGHTS` from the target mesh and captures each bone's init pose in solver-local space. Each frame the CPU re-packs current bone poses into a column-major `mat4` buffer; the compute shader computes `target = Σ bones[idx[i]] · rest_offset[i] · weight[i]` per particle. The cloth-weight channel (0=anchored, 1=free) drives both the per-particle `inverse_mass` (weight 0 = pinned) and the attachment-stiffness lerp in the UPDATE pass that pulls free particles toward their skinned target. `Marker3D` pins override the skinned target for the nearest particle.

**Body-derived colliders.** A single `body_mesh` source can produce three independent collider techniques in parallel: auto-fitted bone capsules (one per qualifying bone, axis bone→child, radius from percentile-trimmed bone-weighted vert distances), per-vert sphere cloud (each sphere skinned to its dominant bone, packed as a degenerate capsule), and a voxel-decimated triangle mesh collider (cluster centroids per voxel, single-bone dominant skinning per tri vert). All three pack into a unified collider buffer that the per-substep collide passes consume. `collider_friction` applies Bridson Coulomb damping at every contact, killing the velocity injection that propagates as jitter through structural constraints.

**Multi-cloth via shared RIDs.** When `peer_cloth_solvers` is non-empty, each solver builds a *decimated peer-collision proxy* at init (voxel-cluster welded particles in rest space, remap `_welded_indices` through the rep subset). Peers bind the small proxy index buffer plus our full positions buffer directly via shared `RenderingDevice` — no copy, no readback. Per-frame dispatch = `peer_proxy_tri_count × our_particle_count`, typically 20× cheaper than full-mesh collision. Self-collision reuses the same shader with a push-constant `is_self` flag that tells the shader to skip triangles where the testing particle is a vertex.

**Fishing-line constraint.** Once per substep after the spring solve, each particle reads its K-nearest pins' current positions, accumulates a weighted-blend target, and projects back onto the `stretch × rest_distance` sphere if it's drifted past. The outward radial velocity component is zeroed at the boundary so the particle slides instead of buzzing. Tension propagates pin → particle in O(1), no cascading through the spring network.

**Particle representation.** Positions are `vec4(x, y, z, inverse_mass)` where `inverse_mass = 0` means pinned. The constraint solver naturally handles pin/free weighting in a single code path.

**Gravity / wind frame.** Both are authored in world space and transformed into the reference-frame (skeleton in rigged mode, solver-local in unrigged) by the CPU before dispatch. Rotating the `GPUClothSolver` node tilts the rest pose with it, but gravity still points world-down and wind still blows world-east.

## Demo

Open `Demo/cloth_demo.tscn` for the v3 showcase scene. The `Demo/Assets/` subfolder ships four self-contained example setups:

- **AnimatedHuman** — rigged character in shirt + pants, each its own solver, peer-collision wired both ways. Body-derived triangle mesh collider on the pants. Shows the full multi-cloth + body-collision stack.
- **LowPolyDude** — single-cape solver attached to a humanoid skeleton; demonstrates `cloth_weight_channel` painting for "rigid collar, free hem" on one mesh.
- **GreenFlag** — flag with `self_collide` enabled so the cloth can fold over itself in the wind without fold-through artifacts.
- **Cat** — low-poly cat with a draped sim-masked cape, exercising the unrigged-mode + skinned-target sanitization paths.

Companion scripts in `Demo/` (`orbit_camera.gd`, `player_controller.gd`, `spin.gd`, `sine_wiggle.gd`) drive scene cameras and animations.

## Credits

Built and maintained by [alien-life](https://github.com/alien-life).

Significant contributions to the solver architecture by [MaxYari](https://github.com/MaxYari/). Thank you.

The fishing-line anchor constraint (`v1.3.0`) was inspired by Sucker Punch's *Ghost of Tsushima* cloth pipeline.

## License

MIT
