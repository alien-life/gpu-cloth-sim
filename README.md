# GPU Cloth Sim

GPU-accelerated cloth simulation for Godot 4.5+ using Position-Based Dynamics on compute shaders.

## Demo

![Demo](demo/UpdatedCloth.gif)


## Support
Join the discord for support :) -- https://discord.gg/maFsFAfqnY

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
- **Procedural fabric shader** — silk / linen / animated lava with border trim (per-edge bitmask), emblem layer, dirt, and wear, all parameterized
- **Shape-mask cutout** — bind a `sampler2D` to mask out non-rectangular cloth shapes via fragment `discard`
- **Editor preview** — wireframe grid, pin connections, and collider shapes drawn in the editor viewport (`@tool`)
- **Double-sided rendering** with automatic back-face normal flip
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
| `collider_targets` | `Array[NodePath]` | `[]` | Explicit collider list (e.g. for colliders living elsewhere in the tree). When empty, the solver falls back to scanning direct children for `GPUClothCollider` nodes. |
| `cloth_material` | `Material` | `null` | Override material (default: built-in procedural fabric shader) |
| `inertia_scale` | `Vector3` | `(1,1,1)` | How strongly cloth resists parent movement |
| `wind` | `Vector3` | `(0,0,0)` | Global wind direction and strength |
| `wind_turbulence` | `float` | `0.3` | Wind gust intensity |
| `wind_frequency` | `float` | `1.0` | Wind gust speed |

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
    COLLIDE  →  project particles out of collision primitives
    UPDATE   →  recover velocity from position delta, apply damping
```

Constraint groups are graph-colored so no two constraints in a group share a particle — this eliminates data races without atomics. The solver dispatches each group separately with GPU barriers between them.

Particle positions are stored as `vec4(x, y, z, inverse_mass)` where `inverse_mass = 0` means pinned and `inverse_mass = 1` means free. This encoding lets the constraint solver naturally handle pin/free weighting in a single code path.

The mesh readback is **asynchronous**: each frame the solver submits the compute list and sets a "pending readback" flag. On the next frame's `_physics_process`, before kicking off new work, it calls `_rd.sync()` and reads the previous frame's results back into the `ArrayMesh`. This pipelines GPU simulation against the next frame's CPU work (game logic, physics, rendering setup) instead of forcing a CPU stall on the same frame the work was submitted. The visible cloth is one frame behind the simulation, which is imperceptible at typical framerates.

## Demo

Open `demo/cloth_demo.tscn` for a working example: a cape-sized cloth with top-row pinning and a sphere collider, along with a pinned cloth example.

The `cloth_demo_driver.gd` script (not attached by default) oscillates pins and the collider for stress testing.

## License

MIT
