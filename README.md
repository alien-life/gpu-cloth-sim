# GPU Cloth Sim

GPU-accelerated cloth simulation for Godot 4.5+ using Position-Based Dynamics on compute shaders.

## Demo

![Demo](demo/UpdatedCloth.gif)


## Support
Join the discord for support :) -- https://discord.gg/maFsFAfqnY

## Features

- **Full GPU pipeline** — predict, constraint solve, collision, and update phases all run as compute shaders on a local `RenderingDevice`
- **Position-Based Dynamics** with graph-colored constraint solving — no race conditions, no atomics, fully parallel per constraint group
- **Collision primitives** — sphere, capsule, and oriented bounding box (OBB)
- **Inertia system** — cloth naturally trails behind parent node movement
- **Wind** with organic turbulence via sum-of-sines at irrational frequency ratios
- **Structural, diagonal, and bending constraints** for controllable stiffness vs. drape
- **Pin targets** — pin particles to `Marker3D` nodes or auto-pin the top row
- **Editor preview** — wireframe grid, pin connections, and collider shapes drawn in the editor viewport (`@tool`)
- **Double-sided rendering** with automatic back-face normal flip

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
| `cloth_material` | `Material` | `null` | Override material (default: built-in double-sided shader) |
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

## Demo

Open `demo/cloth_demo.tscn` for a working example: a cape-sized cloth with top-row pinning and a sphere collider, along with a pinned cloth example.

The `cloth_demo_driver.gd` script (not attached by default) oscillates pins and the collider for stress testing.

## License

MIT
