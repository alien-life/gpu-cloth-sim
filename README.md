# GPU Cloth Sim

GPU-accelerated cloth simulation for Godot 4.5+ using Position-Based Dynamics on compute shaders.

## Demo

![Demo](demo/UpdatedCloth.gif)


## Support
Join the discord for support :) -- https://discord.gg/maFsFAfqnY

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

- **Full GPU pipeline** — predict, constraint solve, collision, and update phases all run as compute shaders on a local `RenderingDevice`
- **Position-Based Dynamics** with graph-colored constraint solving — no race conditions, no atomics, fully parallel per constraint group
- **Collision primitives** — sphere, capsule, and oriented bounding box (OBB)
- **Inertia system** — cloth naturally trails behind parent node movement
- **Wind** with organic turbulence via sum-of-sines at irrational frequency ratios
- **Structural, diagonal, and bending constraints** for controllable stiffness vs. drape
- **Pin targets** — pin particles to `Marker3D` nodes or auto-pin the top row, with per-pin smoothing to prevent snap on fast motion
- **Fishing-line anchor constraint** — Ghost-of-Tsushima-style hard distance clamp from each particle to its nearest pin, so tension propagates instantly instead of one spring-link per iteration
- **Procedural fabric shader** — silk / linen / animated lava with border trim (per-edge bitmask), emblem layer, dirt, and wear, all parameterized
- **Shape-mask cutout** — bind a `sampler2D` to mask out non-rectangular cloth shapes via fragment `discard`
- **Per-particle voxel ambient occlusion** — cloth folds darken naturally via a per-frame voxelization compute pass, no screen-space noise
- **Editor preview** — wireframe grid, pin connections, and collider shapes drawn in the editor viewport (`@tool`)
- **Double-sided rendering** with proper back-face normal-map handling
- **Async GPU readback** — compute submission and mesh sync are pipelined across frames to hide GPU latency

## Requirements

- **Godot 4.5+**
- **Vulkan renderer** (Forward+ or Mobile) — compute shaders require it. The Compatibility (OpenGL) renderer is not supported.

## Installation

1. Download or clone this repository
2. Use the Godot AssetLib to import gpu_cloth_sim.zip into your project

Or clone the entire repo to try the included demo scene immediately.

### Building a ZIP

To create an installable ZIP from the repo root:

```bash
zip -r gpu_cloth_sim.zip addons/ demo/ LICENSE README.md -x "*.import" "*.uid"
```

## Quick Start

1. Add a **GPUClothSolver** node to your scene
2. Set `cloth_width`, `cloth_height`, and `particle_spacing` to define the grid
3. Enable `pin_top_row` (or add `Marker3D` children and assign them to `pin_targets`)
4. Optionally add **GPUClothCollider** children for collision
5. Run the scene

## GPUClothSolver Properties

| Property | Type | Default | Description |
|---|---|---|---|
| `cloth_width` | `int` | `20` | Particles along X axis |
| `cloth_height` | `int` | `20` | Particles along Y axis |
| `particle_spacing` | `float` | `0.1` | Distance between adjacent particles |
| `gravity_strength` | `float` | `-9.8` | Gravity acceleration |
| `solver_iterations` | `int` | `8` | Constraint solver passes per substep |
| `substeps` | `int` | `8` | Physics substeps per frame |
| `stiffness` | `float` | `0.5` | Structural constraint stiffness |
| `bend_stiffness` | `float` | `0.1` | Bending constraint stiffness |
| `damping` | `float` | `0.99` | Velocity damping per substep |
| `max_speed` | `float` | `5.0` | Velocity clamp |
| `pin_targets` | `Array[NodePath]` | `[]` | `Marker3D` nodes to pin nearest particles to |
| `pin_top_row` | `bool` | `false` | Auto-pin all particles in row 0 |
| `pin_smooth_speed` | `float` | `20.0` | Lerp speed for pin tracking. Higher = stiffer follow. `0` freezes pins at their initial position. |
| `enable_fishing_line` | `bool` | `true` | Hard-clamp each free particle to within `fishing_stretch × rest_distance` of its nearest pin's current position each substep. Eliminates rubber-band droop. Skipped when no pins exist. |
| `fishing_stretch` | `float` | `1.02` | Allowed slack on the fishing-line distance. `1.0` = perfectly inelastic, `1.02` = 2% stretch, `1.10+` = visibly slack. |
| `collider_targets` | `Array[NodePath]` | `[]` | Explicit collider list (e.g. for colliders living elsewhere in the tree). When empty, the solver falls back to scanning direct children for `GPUClothCollider` nodes. |
| `cloth_material` | `Material` | `null` | Override material (default: built-in procedural fabric shader) |
| `inertia_scale` | `Vector3` | `(1,1,1)` | How strongly cloth resists parent movement |
| `wind` | `Vector3` | `(0,0,0)` | Global wind direction and strength |
| `wind_turbulence` | `float` | `0.3` | Wind gust intensity |
| `wind_frequency` | `float` | `1.0` | Wind gust speed |
| `voxel_ao_enabled` | `bool` | `true` | Run per-particle voxel AO pass and feed results into vertex colors |
| `voxel_ao_cell_size` | `float` | `0.06` | Voxel grid cell size in solver-local units |
| `voxel_ao_grid_dim` | `Vector3i` | `(32,32,16)` | Voxel grid resolution (cells in X, Y, Z) |
| `voxel_ao_radius` | `int` | `2` | Sample neighborhood radius in cells. Higher = softer/larger AO at cost of more samples. |
| `voxel_ao_strength` | `float` | `1.0` | Multiplier on raw occlusion fraction before clamping to [0,1] |

## GPUClothCollider Properties

| Property | Type | Default | Description |
|---|---|---|---|
| `shape` | `SPHERE` / `CAPSULE` / `BOX` | `CAPSULE` | Collision primitive type |
| `radius` | `float` | `0.3` | Sphere/capsule radius |
| `height` | `float` | `1.6` | Capsule total height |
| `extents` | `Vector3` | `(0.5,0.5,0.5)` | Box half-extents |
| `target` | `NodePath` | | Optional node to track transform from |

## How It Works

Each frame, the solver runs a 4-phase compute pipeline inside a single command list:

```
for each substep:
    PREDICT  →  apply gravity, wind, inertia offset
    SOLVE    →  PBD distance constraints (14 graph-colored groups × N iterations)
    FISHING  →  clamp each free particle to within stretch × rest of its nearest pin (optional)
    COLLIDE  →  project particles out of collision primitives
    UPDATE   →  recover velocity from position delta, apply damping
```

Constraint groups are graph-colored so no two constraints in a group share a particle — this eliminates data races without atomics. The solver dispatches each group separately with GPU barriers between them.

The optional **fishing-line pass** runs once per substep after the spring solve. At init, each particle records the index of its nearest pin and the rest distance to that pin. Each substep the compute shader reads the pin's *current* position, computes the vector to its assigned particle, and if the length exceeds `fishing_stretch × rest_distance` clamps it back onto the sphere of radius `fishing_stretch × rest_distance` around the pin. Tension propagates from any pin to any particle in a single shader invocation — no cascading through the spring network. The pass touches only its own particle's position so no graph-coloring is required.

Particle positions are stored as `vec4(x, y, z, inverse_mass)` where `inverse_mass = 0` means pinned and `inverse_mass = 1` means free. This encoding lets the constraint solver naturally handle pin/free weighting in a single code path.

The mesh readback is **asynchronous**: each frame the solver submits the compute list and sets a "pending readback" flag. On the next frame's `_physics_process`, before kicking off new work, it calls `_rd.sync()` and reads the previous frame's results back into the `ArrayMesh`. This pipelines GPU simulation against the next frame's CPU work (game logic, physics, rendering setup) instead of forcing a CPU stall on the same frame the work was submitted. The visible cloth is one frame behind the simulation, which is imperceptible at typical framerates.

If `voxel_ao_enabled`, after the cloth substep loop the solver runs two more compute passes per frame: a voxelize pass that bit-packs particle occupancy into a small grid via `atomicOr`, and a sample pass that for each particle scans a neighborhood of cells and counts occupied cells as occlusion. Per-particle AO is read back alongside positions and written to vertex `COLOR.r` (visibility = 1 − occlusion). The default surface shader consumes this as Godot's `AO` builtin output, which the engine multiplies into the ambient lighting term.

## Demo

Open `demo/cloth_demo.tscn` for a working example: a cape-sized cloth with top-row pinning and a sphere collider, along with a pinned cloth example.

The `cloth_demo_driver.gd` script (not attached by default) oscillates pins and the collider for stress testing.

## License

MIT
