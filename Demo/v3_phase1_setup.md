# v3.0 Phase 1 verification scene setup

The substrate swap is in. Build `demo/v3_phase1.tscn` against your real assets to verify the rewrite.

## What changed at the API level

The v2.x API (`source_mesh: Mesh`, `sim_mask_from_vertex_color`, `skin_attach_radius`, `rotational_inertia_scale`, `voxel_ao_*`, the grid path, `debug_show_*`) is gone. Existing scenes using those exports will fail to load — the v2.1.0 tag preserves a working snapshot. Rebuild against the new API:

| Old export | New mechanism |
|---|---|
| `source_mesh: Mesh` | `target_mesh: NodePath` pointing at a `MeshInstance3D` |
| `sim_mask_from_vertex_color` + `sim_mask_channel` | Vertex color **R channel** = cloth weight (no toggle) |
| `skin_attach_radius` | `max_travel_distance` |
| `skin_velocity_damp` | (gone — soft-lerp in `cloth_update.glsl` handles boundary buzz structurally) |
| `rotational_inertia_scale` | (gone — skeleton-local positions eliminate the patchwork) |
| `pin_targets`, `pin_smooth_speed`, `enable_fishing_line`, `fishing_stretch`, `bindings_per_particle` | Phase 2 reintroduces these |
| `bend_stiffness`, `bending_from_topology`, `weld_epsilon` | Phase 2 reintroduces these |
| `voxel_ao_*` | Gone permanently in v3.0 (revisit as SSAO in v3.1 if missed) |
| `cloth_width`, `cloth_height`, `particle_spacing`, `pin_top_row` | Gone permanently (grid-cape path) |
| `debug_show_*`, `debug_particle_size` | Gone (no cheap CPU debug overlay on the substrate) |

## Mesh requirements (Phase 1)

The `target_mesh` MeshInstance3D must:

1. Have an `ArrayMesh` with the desired surface present at `surface_index` (default 0).
2. Have a `Skin` resource assigned (`set_skin(...)`); the solver reads bind-bone mappings via `_skin.get_bind_bone(bi)`.
3. Use a skinned, indexed mesh (`ARRAY_BONES` + `ARRAY_WEIGHTS` populated, `ARRAY_INDEX` non-empty).
4. Have **vertex color R channel** painted as cloth weight: `0.0` = anchored to the bone-skinned target, `1.0` = fully simulated, intermediate = soft blend. Phase 1 reads R only — paint it in Blender's Vertex Paint mode (Color Attribute → Active Render slot).

Phase 1 does not weld vertices. Each render vertex maps 1:1 to a simulated particle. UV-seam tearing returns in Phase 2 with the welder.

## Scene structure

```
ClothDemo (Node3D)
├── DirectionalLight3D
├── Camera3D
├── WorldEnvironment
├── Ground (MeshInstance3D)
└── Character_A (Node3D, instance of your character scene)
    └── ... → contains a Skeleton3D and a cape MeshInstance3D
    └── GPUClothSolver
        ├── target_mesh = NodePath("../path/to/CapeMeshInstance3D")
        ├── skeleton = NodePath("../path/to/Skeleton3D")
        └── GPUClothCollider (capsule)
            └── target = NodePath("../../path/to/ChestBoneAttachment")
```

Three instances side-by-side. Each owns its own solver/collider; they share the main `RenderingDevice` and exercise the multi-solver compute-list compose pattern.

## Smoke-test prerequisite

Before running the verification scene, run `addons/godot_gpu_cloth/test/smoke.tscn`. Three instances should print:
```
[smoke A] PASS — 120 frames, 256 elements, buffer[i] == i + 120 everywhere.
[smoke B] PASS — 120 frames, 256 elements, buffer[i] == i + 120 everywhere.
[smoke C] PASS — 120 frames, 256 elements, buffer[i] == i + 120 everywhere.
```
If any FAIL, halt — the multi-solver compose pattern is broken on this Godot/driver combo and v3.0 needs a single-shared-compute-list autoload before continuing. The smoke test is gate-keeping; don't ignore a failure.

## What to verify

1. **Frame 1 renders correctly.** Cape is on the character, not at the rest pose (warm-start works).
2. **Skeleton animation drives the cloth.** Spin or animate the character — cape follows.
3. **3-solver scene at 120+ FPS.** Compare against `git checkout v2.1.0` (which falls to ~5 FPS in a multi-solver scene).
4. **Smooth cloth weight gradient.** Paint a half-anchored half-free strip on the cape; the boundary should not buzz (the soft-lerp in `cloth_update.glsl` handles this structurally).
5. **Profiler.** No `_physics_process` time on the solver; only `_process` and the render-thread callable.
6. **Collider gizmos.** Visible in 3D editor viewport on `GPUClothCollider` nodes (sphere/capsule/box outlines).
7. **RID cleanup.** Quit/restart Godot 5×; check Output for RID leak warnings.
8. **GPU profiler trace** (RenderDoc / Vulkan validation layer): no `vkDeviceWaitIdle`-like fences; only the COMPUTE→VERTEX barrier between dispatch and draw.

## Common setup gotchas

- **No vertex color anchoring.** If Output shows `Zero anchored vertices — cloth will fall freely`, paint at least some pixels with R=0 in Blender. Without anchors the cape just falls.
- **No Skin resource.** Output shows `target_mesh has no Skin resource. Aborting.` — Mixamo / GLB imports usually produce one automatically; if hand-built, assign one in the inspector.
- **Wrong surface_index.** A multi-surface mesh defaults to surface 0; if the cape is surface 1, set `surface_index = 1`.
- **Colliders not found.** If `collider_targets` is empty, the solver scans the **skeleton tree** (not the solver's children). Parent your `GPUClothCollider` under a `BoneAttachment3D` or under the skeleton itself; alternately, set `collider_targets` explicitly.
- **Cape rendering at origin.** Likely the surface material's `gpu_driven` parameter didn't get set to `true`. Verify in the inspector after init that the MeshInstance3D's surface override material has `gpu_driven = true`, `tex_width`, `skel_to_mesh_transform`, and the two `*_tex` parameters wired.
- **Cape inverted normals.** Toggle `flip_normals` on the solver.
