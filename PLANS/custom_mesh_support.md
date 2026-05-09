# v2.0 — Custom Mesh Support

**Status:** implemented/stabilized in the v2.0 working tree. This document is now historical design context; the README is the source of truth for current user-facing behavior.
**Tracking issue:** GitHub request for arbitrary `Mesh` as the cloth source instead of auto-generated planar grids.
**Estimated effort:** ~1 focused week, or 2 weeks of evening work.

## Problem

The plugin currently only supports auto-generated `cloth_width × cloth_height` planar grids. Real projects want imported meshes (`.gltf`, `.fbx`, `.obj`, programmatically built `ArrayMesh`) as the cloth source — flags with cutout shapes, irregular banners, character clothing, etc.

The shape-mask cutout from v1.1 is a workaround that fakes non-rectangular shapes from a regular grid. Custom mesh support is the proper fix.

## Goal

A new export `source_mesh: Mesh` on `GPUClothSolver`. When assigned, the solver uses that mesh's vertices as the particle set, its triangle topology to build constraints, and its UVs/indices for rendering. When null, falls back to the existing procedural grid (default behaviour).

Imported meshes typically have duplicated vertices at UV seams and hard-normal edges — the same world position appears 2-6 times. The solver must weld these to a unique particle set or the cloth will explode at every seam.

## Architectural decision — unified mesh path

Two implementation strategies:

- **(A) Branched.** `source_mesh != null` → mesh codepath. Else → grid codepath. Two parallel code paths in `_ready()`.
- **(B) Unified.** The grid is just a particularly simple mesh. Procedural grid path internally generates an `ArrayMesh` and feeds it through the universal mesh path. One code path.

**Recommendation: (B).** Half the surface area to maintain. New constraint-extraction logic is the bulk of the work either way; might as well let the grid path benefit from the shared infrastructure. Migration is invisible to existing users — `cloth_width / cloth_height / particle_spacing` still work, just internally generate the mesh instead of a special builder.

## What gets reused vs. new

| Component | Status |
|---|---|
| All four core compute shaders (predict, solve, collide, update) | Reused — they're already topology-agnostic |
| Voxel AO shaders | Reused — operate on positions buffer only |
| Fishing-line shader | Reused — operates on weighted bindings, doesn't care about grid |
| `_build_bindings()` (fishing line) | Reused — already mesh-agnostic |
| Async readback, pin smoothing, inertia, collider tracking | Reused — operate on the abstract particle set |
| `_build_positions()` | **Replace** with mesh-driven equivalent |
| `_build_constraints()` | **Replace** with mesh-driven topology extraction |
| `_build_mesh_topology()` | **Replace** — UVs/indices come from input mesh |
| `_redraw_editor_preview()` | **Update** — draw input mesh's wireframe |

Net: zero shader changes. All work is on the CPU side.

## API additions

```gdscript
@export_group("Source Mesh")
## When assigned, overrides cloth_width/cloth_height/particle_spacing.
## Particles are derived from this mesh's welded vertices, constraints from
## its triangle topology, UVs and triangle indices preserved for rendering.
@export var source_mesh: Mesh

## Vertices closer than this distance are merged to a single simulated
## particle. Imported meshes have duplicated vertices at UV seams and hard
## edges — without welding the cloth falls apart at every seam.
@export var weld_epsilon: float = 0.001

## Build bending constraints from edge-shared triangle pairs. Off = only
## structural (edge-length) constraints, cloth will be very droopy.
@export var bending_from_topology: bool = true

@export_group("Pinning")
# Existing: pin_targets, pin_top_row, pin_smooth_speed kept as-is.

## Pin particles whose imported vertex color exceeds the threshold on the
## chosen channel. Lets you paint a pin mask in Blender and import it. Zero
## additional UI in the addon.
@export var pin_from_vertex_color: bool = false
@export_range(0.0, 1.0) var pin_color_threshold: float = 0.5
## 0 = R, 1 = G, 2 = B, 3 = A. Alpha is the conventional choice.
@export_range(0, 3) var pin_color_channel: int = 3
```

`pin_top_row` becomes meaningless when `source_mesh` is assigned — emit a `push_warning` if both are set, prefer `source_mesh`.

## Implementation phases

### Phase 1 — Mesh I/O + vertex welding (foundation)

Goal: load a `Mesh` resource, weld duplicate vertices, populate the positions buffer.

Tasks:
- [ ] New helper `_extract_mesh_data(mesh: Mesh) -> Dictionary` that calls `mesh.surface_get_arrays(0)` and returns `{vertices, normals, uvs, colors, indices}`.
- [ ] New helper `_weld_vertices(vertices: PackedVector3Array, epsilon: float) -> Dictionary` that returns `{welded_positions: PackedVector3Array, original_to_welded: PackedInt32Array}`. Implementation: spatial-hash positions, check neighboring cells by distance, accumulate.
- [ ] In `_ready()`, branch on `source_mesh != null`:
  - if assigned, call extract + weld → seed `pos_data` from welded positions
  - else, existing `_build_positions()` produces the planar grid (eventually rewrap as a mesh internally for unified path)
- [ ] `_particle_count` is now derived from the welded vertex count, not `cloth_width * cloth_height`.

Deliverable: a `source_mesh` cube falls under gravity (no constraints yet), 8 particles, no rendering yet.

### Phase 2 — Constraint extraction from topology

Goal: derive structural and bending constraints from triangle data.

Tasks:
- [ ] Walk triangles. For each triangle, emit 3 structural constraints (one per edge), keyed on `(min(a, b), max(a, b))` to dedupe shared edges. Rest distance = initial Euclidean separation between welded particles.
- [ ] Build edge → adjacent-faces map. Iterate edges; for each interior edge (shared by exactly 2 faces), find the two non-shared vertices and emit a bending constraint.
- [ ] Non-manifold edges (3+ faces sharing): skip + `push_warning` once with edge count.
- [ ] No diagonal constraints — they're a grid-specific stiffening trick. Bending replaces them functionally.

Deliverable: a `source_mesh` cube falls under gravity, structural+bending constraints active, rigid-ish behaviour. Pin one vertex via `pin_targets` — the cube hangs and stretches sensibly.

### Phase 3 — Runtime graph coloring

Goal: add topology-driven greedy coloring for source meshes while keeping the legacy grid coloring path compatible.

Tasks:
- [ ] After constraints are built, run greedy coloring:
  ```
  for each constraint c in some order:
	  for g in 0..groups.size():
		  if g doesn't already contain a vertex shared with c:
              groups[g].append(c)
              break
      else:
          groups.append(new group with c)
  ```
- [ ] Track each group's vertex set as a `Dictionary` for O(1) "does this group already touch vertex X" lookup.
- [ ] Sort constraints into final buffer ordered by group; each group gets `{offset, count}` recorded in `_constraint_groups`.
- [ ] Existing dispatch loop iterates `_constraint_groups` so it adapts automatically — verify by logging group count + sizes for the cube test.
- [ ] Sanity check: total constraints across all groups == original constraint count.

Deliverable: arbitrary mesh topology produces correctly-colored constraints; cloth solves without race conditions.

### Phase 4 — Mesh rendering preservation

Goal: render the input mesh's actual triangles with its UVs and (potentially duplicated-at-seams) vertices, but driven by the welded particle simulation.

Tasks:
- [ ] At init, build the rendering arrays from input mesh:
  - `_render_uvs` = input UVs (NOT remapped — UV seams must persist)
  - `_render_indices` = input indices (also NOT remapped — they reference original vertex slots)
  - `_render_to_particle: PackedInt32Array` — for each rendered vertex slot, the welded particle index
- [ ] In `_update_mesh()`:
  - Read welded particle positions from GPU
  - Scatter to render-vertex array via `_render_to_particle`: `render_verts[i] = welded_positions[_render_to_particle[i]]`
  - Recompute per-vertex normals from face cross products (existing logic should mostly transfer)
  - Recompute tangents (existing logic — use UV layout)
- [ ] If input mesh has vertex colors AND `pin_from_vertex_color` is OFF (otherwise color is consumed by pin logic), pass them through to the output mesh so user shaders can read them.

Deliverable: visually correct cloth that preserves the input mesh's UV layout and seam structure while simulating the welded particle set underneath.

### Phase 5 — Pin retargeting

Goal: replace `pin_top_row` with mesh-friendly authoring.

Tasks:
- [ ] In the Phase 1 mesh-extract step, also pull `Mesh.ARRAY_COLOR` if present.
- [ ] If `pin_from_vertex_color`, after welding: for each welded particle, sample the chosen channel of any one of its source vertices' colors (they should all be ~equal post-welding; could average for robustness). If above `pin_color_threshold`, mark as pinned.
- [ ] `pin_targets` (Marker3D-driven) still works unchanged — `_pin_map` stores `(marker, particle_idx, smoothed_pos)` and the lookup logic is identical.
- [ ] `pin_top_row` skipped when `source_mesh` is assigned, with warning.

Deliverable: paint a pin mask in Blender on a cape mesh, import, drop in solver — no scripting, cape pins along the painted edge.

### Phase 6 — Editor preview update

Goal: `_redraw_editor_preview()` shows the input mesh's wireframe instead of the grid.

Tasks:
- [ ] Branch in `_redraw_editor_preview()`: if `source_mesh != null`, walk its triangles and emit line segments (3 per face, dedupe by edge if performance matters — not critical for editor).
- [ ] Pin marker preview: same as today, but uses welded particle positions.
- [ ] Collider previews: unchanged.

Deliverable: drop a `source_mesh` in the inspector → editor viewport shows the mesh's wireframe + pin markers.

### Phase 7 — Demo + docs + polish

Tasks:
- [ ] Add a second demo scene `demo/cloth_demo_custom_mesh.tscn` with an imported `.glb` flag.
- [ ] Update README:
  - "What's New in 2.0" entry
  - New `Source Mesh` properties table section
  - "How It Works" section addition: vertex welding, topology-driven constraints, runtime graph coloring
  - Note: imported skin weights are not yet consumed (forward reference to the skinning feature)
- [ ] Profile at 1k, 5k, 10k welded particles. Document any performance cliffs.
- [ ] Bump `plugin.cfg` to `2.0.0`.

## Open questions / decisions to make during implementation

1. **Should the procedural grid path actually go through the unified mesh path?** Recommendation: yes. Build a planar `ArrayMesh` from `cloth_width × cloth_height` once at init, hand off to the same code path. ~30 line internal helper, eliminates the dual code path forever. But: the existing diagonal constraints disappear (mesh path uses bending, not diagonals). Verify visually that the new grid behaviour is acceptable; if not, keep the legacy grid builder behind a flag.

2. **How to bake the input mesh's local transform.** A mesh exported from Blender at scale 0.5 should produce particles at half the size. Recommendation: ignore this for v2.0 — the user can apply transforms in Blender or set the solver's scale. If users complain, add `apply_mesh_transform: bool` later.

3. **Quad meshes.** If the input is a quad-faced mesh (rare in Godot since `ArrayMesh` triangulates on import), it'll come in as triangles already. Should be a non-issue but flag any explicit quad handling needed.

4. **Vertex skinning data on imported character clothing.** Imported character clothing meshes have bone weights. v2.0 will silently discard them. v2.1+ skinning feature will consume them. Flag in the README that this is the intended pairing.

5. **Welding tolerance.** `weld_epsilon = 0.001` is conservative. Some meshes need looser welding (e.g., low-precision exports), some need tighter (CAD-precise meshes with intentional small features). Inspector tunable; document the symptom of wrong values: too loose → cloth collapses or features merge; too tight → cloth explodes at seams.

6. **What happens when mesh is changed at runtime?** v2.0: nothing — the addon reads `source_mesh` at `_ready()` and never re-checks. Document this. If runtime mesh swap is needed later, expose a `rebuild()` method.

## Out of scope for v2.0

- **Cloth-on-cloth collision.** Same primitive-only collision as today.
- **Per-particle skinning weights.** Deferred to the skinning feature; will use the same `_build_bindings`-style infrastructure.
- **Tearing / dynamic constraint removal.** Some cloth sims let you cut cloth at runtime; not us, not yet.
- **LOD support.** Future feature.
- **Persistent-mapped vertex buffers / GPU mesh streaming.** Performance optimization. The per-frame `clear_surfaces() + add_surface_from_arrays()` is fine up to ~5k vertices; beyond that, refactor to `surface_update_vertex_region()` is its own PR.
- **Auto-bind from skeleton proximity.** Skinning-feature work, not custom-mesh work.

## Reference points in the existing codebase

| File | Lines | What it does | Where new code lands |
|---|---|---|---|
| `addons/godot_gpu_cloth/src/gpu_cloth_solver.gd` | `_ready()` | Init pipeline | Branch on `source_mesh != null` here |
| `addons/godot_gpu_cloth/src/gpu_cloth_solver.gd` | `_build_positions()` | Grid → particles | Replace with mesh-driven version |
| `addons/godot_gpu_cloth/src/gpu_cloth_solver.gd` | `_build_constraints()` | Grid topology → constraints | Replace entirely; greedy coloring |
| `addons/godot_gpu_cloth/src/gpu_cloth_solver.gd` | `_build_mesh_topology()` | Grid UVs + indices | Source from input mesh |
| `addons/godot_gpu_cloth/src/gpu_cloth_solver.gd` | `_update_mesh()` | Per-frame mesh write-back | Add scatter-via-remap step |
| `addons/godot_gpu_cloth/src/gpu_cloth_solver.gd` | `_redraw_editor_preview()` | Editor wireframe | Mesh wireframe path |
| `addons/godot_gpu_cloth/src/gpu_cloth_solver.gd` | `_build_bindings()` | Fishing-line bindings | Already mesh-agnostic, no changes |

## Testing strategy

Visual targets, in order:

1. **Cube hanging from one corner.** 8 welded particles, 12 edges, 6 bending constraints across faces. Verify cube hangs and stretches without exploding.
2. **Subdivided plane (imported, non-grid topology).** Same as today's behaviour but driven through the new path. Verify procedural grid case still works after the unification.
3. **Flag with cutout shape.** Imported `.glb` of a non-rectangular flag with the top edge weight-painted in vertex color alpha. Drop in solver, set `pin_from_vertex_color = true`. Flag flutters in wind, holds the painted edge.
4. **Sphere of cloth (closed manifold).** Tests bending around manifold boundaries. Should drape and squish without seams.
5. **Low-poly skirt.** Tests pin_targets on bone-tracking markers, irregular topology, fast deformation under wind.
6. **Performance: 5k-vertex mesh.** Check that the per-frame mesh writeback doesn't tank framerate. If it does, that's the trigger for the `surface_update_vertex_region()` refactor.

For each: take a screenshot via the bridge, eyeball, iterate. The compute side should "just work" without modification — bugs will be in the new builders.

## Scope reminder

This issue is asking for **arbitrary mesh as cloth source**, not "complete cloth simulation overhaul." Resist the urge to fold in skinning, cloth-on-cloth, LOD, etc. Each of those is its own feature with its own scope discussion. Ship v2.0 small and focused; the architectural unification creates the right foundation for the next features but doesn't pre-implement them.
