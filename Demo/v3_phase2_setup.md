# v3.0 Phase 2 verification scene setup

Phase 2 layered welding, K-nearest fishing-line, bending constraints, and
Marker3D pinning on top of the Phase 1 substrate. Build `demo/v3_phase2.tscn`
to verify all of it together.

## What's new (Phase 2 additions to the API)

```gdscript
# Mesh ingestion
@export var weld_epsilon: float = 0.001

# Bending constraints (topology-driven, in addition to structural edges)
@export var bend_stiffness: float = 0.1
@export var bending_from_topology: bool = true

# Marker3D pinning
@export var pin_targets: Array[NodePath] = []
@export var pin_smooth_speed: float = 20.0

# Fishing-line K-nearest tension propagation
@export var enable_fishing_line: bool = true
@export var fishing_stretch: float = 1.02
@export var stretch_curve: Curve  # optional, samples by mesh-Y bounds
@export_range(1, 8) var bindings_per_particle: int = 4
```

## Authoring model — pins vs. cloth_weights (Hazard 4)

The two anchoring tools are orthogonal:

| Tool | Use for | Mechanism |
|---|---|---|
| `cloth_weights` (vertex color R) | Skeleton-driven garments — collar tracks neck bone, hem swings | `cloth_weight = 0` → particle locks to bone-skinned position; gradient soft-lerps in update |
| `pin_targets: Array[Marker3D]` | Sparse anchors not driven by a bone — banner on poles, fabric attached to a non-skeletal prop | Marker pins the nearest welded particle to the marker's position; the pin_override pass plugs that into `skinned_targets` so PREDICT honors it |
| Combined | Most authoring. Paint `cloth_weight` for skeleton regions, drop Marker3D children for explicit anchors. | Both run; markers don't override `cloth_weights` semantics |

**Fishing-line constrains free particles to within `stretch × rest_distance` of their K nearest *Marker3D-pinned* anchors. It does NOT use skin-anchored particles as anchors** (including them welds free particles to the rest pose — v2.x lesson). For pure-skinned cloth without markers, set `enable_fishing_line = false`; the soft-lerp + max_travel handles tension naturally.

## Mesh requirements (Phase 2)

Same as Phase 1, plus:

- **Multi-surface meshes are now supported.** All triangle-primitive surfaces are walked and aggregated; UV seams between surfaces collapse via the welder.
- **UV seams can be present.** The welder collapses coincident verts (within `weld_epsilon`) into single simulated particles. The render mesh keeps its un-welded slots so UVs/tangents stay intact.
- **Cloth weights still go in vertex color R channel.** Per welded particle, the FIRST source vertex that mapped to it wins (matches the welder's first-encounter rule). Disagreements between source verts are warned at init.

## Verification scenes

### Scene A — skinned cape with UV seams (welding test)

A character with a cape mesh that has hard-edge / UV-seam splits down the center. Without welding, Phase 1 would tear at every seam.

```
Character (Node3D)
└── Skeleton3D
    ├── BoneAttachment3D (chest)
    │   └── GPUClothCollider (capsule)
    └── (cape MeshInstance3D somewhere in the hierarchy)
GPUClothSolver
├── target_mesh = NodePath("Character/.../Cape")
├── skeleton = NodePath("Character/Skeleton3D")
├── enable_fishing_line = false  # pure-skinned, no markers
└── (no Marker3D children)
```

**Verifies:**
- Cape doesn't tear at UV seams.
- Cape doesn't tear at UV-island boundaries on multi-surface meshes.
- Bending constraints produce visible stiffness (try `bend_stiffness = 0.5` vs `0.05`).
- 3-instance scene runs at 120+ FPS.

### Scene B — Marker3D-pinned banner (fishing-line test)

A flat banner mesh (single rectangular surface, no seams) skinned to a single bone. Two Marker3D nodes pin the top corners — these are the K-nearest fishing anchors. Free particles bound by `bindings_per_particle = 4`.

```
Banner (Node3D)
└── Skeleton3D (single bone, identity pose; the cloth needs A skeleton even
                 if the bone never moves — the pin pass is the actual anchor source)
    └── Banner_Mesh (MeshInstance3D, has Skin assigned)
GPUClothSolver
├── target_mesh = NodePath("Banner_Mesh")
├── skeleton = NodePath("Skeleton3D")
├── enable_fishing_line = true
├── fishing_stretch = 1.02
├── bindings_per_particle = 4
├── pin_targets = [Marker3D_TopLeft, Marker3D_TopRight]
└── child Marker3D nodes positioned at the banner's top corners
```

To exercise the fishing-line, animate the markers (e.g., `cloth_demo_driver.gd` from the fork's demo). Free particles should track the marker movements *immediately*, not droop a frame and catch up.

**Verifies:**
- Long stiff banner with 2 markers doesn't visibly droop before tension propagates (K=4 fishing-line working).
- Marker positions update smoothly (`pin_smooth_speed` controls catch-up rate).
- `enable_fishing_line = false` in the same scene → cloth visibly droops/lags markers.

### Scene C — hybrid skinned-and-pinned (Hazard 4 sanity)

Two solvers in the same scene running both authoring methods:
- One skinned cape with `cloth_weights` (no markers) — uses Scene A's setup.
- One Marker3D-pinned banner (no skeleton movement) — uses Scene B's setup.

**Verifies:** both authoring methods coexist; markers don't interfere with cloth_weights, and vice versa.

## Known limitations (Phase 2)

- **Skeleton is required** even for pure-marker cases. The skin pass dispatches every frame; for a banner with no real bone movement, use a 1-bone skeleton with the bone at identity. (Phase 3 will relax this.)
- **No screen-space AO yet.** Voxel AO was scope-cut in v3.0; revisit in v3.1 if visual loss matters.
- **No cloth-on-cloth collision.** Out of scope for v3.0.
- **`source_mesh: Mesh` (v2.x) export is gone.** Existing scenes using it fail to load. Tag `v2.1.0` preserves a working snapshot.

## What to verify, end-to-end

After Phase 2 lands, all of these should pass:

1. **3-solver baseline.** Compare against `git checkout v2.1.0` (which falls to ~5 FPS in a multi-solver scene). Target: 120+ FPS.
2. **Skinned cape with UV seams** (Scene A) — no tearing, animation drives the cloth.
3. **Marker3D banner** (Scene B) — animated markers, no droop, K=4 fishing visible.
4. **Hybrid scene** (Scene C) — three solvers (cape × 1, banner × 1, plus repeat for stress), two authoring methods, all running at full FPS.
5. **Bending stiffness sweep.** `bend_stiffness ∈ {0.05, 0.2, 0.5, 1.0}`. Cloth should drape progressively stiffer; no triangle flips, no jitter.
6. **RID cleanup.** Quit/restart Godot 5×; check Output for RID leak warnings.
7. **GPU profiler trace.** RenderDoc / Vulkan validation: no `vkDeviceWaitIdle`-like fences; only the COMPUTE→VERTEX barrier between dispatch and draw.
8. **Multi-solver compose.** Re-run `addons/godot_gpu_cloth/test/smoke.tscn` after Phase 2 commit lands to catch regressions.

## Common gotchas

- **Marker pin appears stuck at origin.** The marker's *world* position is read each frame. If the marker is parented to something that's hidden, scaled to zero, etc., its world position may be (0, 0, 0). Check `marker.global_position` in remote inspector.
- **Marker pin appears delayed.** `pin_smooth_speed` controls the lerp rate. Default `20.0` smooths roughly to 1-frame lag at 60 FPS. Lower for slower follow, higher for snappier (but watch for snap artifacts).
- **Fishing seems to do nothing.** Verify `enable_fishing_line = true`, `pin_targets` is non-empty, and the markers resolve to valid `Marker3D` nodes. Check Output for `[GPUCloth] Marker pins: N  fishing-line enabled: true`.
- **Cape tears in spite of welding.** Lower `weld_epsilon` doesn't help — raise it. Default `0.001` is 1mm; for meshes with larger gaps between coincident verts (rare), try `0.01`. Watch the `Welded particles: X (from Y render verts)` log line: if X == Y, no welding happened.
- **Disagreement warning at init.** `[GPUCloth] N source vertices disagreed on bone weights with their welded particle's first vertex` means UV-seam siblings have different bone weights painted in Blender. The first source vertex wins. Re-export the mesh with consistent skin weights at hard edges if visual artifacts appear.
- **Bending too soft / too stiff.** `bend_stiffness` is per-iteration; effective stiffness scales with `solver_iterations`. Default `bend_stiffness=0.1, solver_iterations=8` is typical garment cloth.
