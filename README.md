# GPU Cloth Sim

GPU-accelerated cloth simulation for Godot 4.5+ using Position-Based Dynamics on compute shaders.

## Demo

![Demo](demo/UpdatedCloth.gif)


## Support
Join the discord for support :) -- https://discord.gg/maFsFAfqnY

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

- **Full GPU pipeline** — predict, constraint solve, collision, and update phases all run as compute shaders on a local `RenderingDevice`
- **Position-Based Dynamics** with graph-colored constraint solving — no race conditions, no atomics, fully parallel per constraint group
- **Collision primitives** — sphere, capsule, and oriented bounding box (OBB)
- **Inertia system** — cloth naturally trails behind parent node movement
- **Wind** with organic turbulence via sum-of-sines at irrational frequency ratios
- **Structural, diagonal, and bending constraints** for controllable stiffness vs. drape
- **Pin targets** — pin particles to `Marker3D` nodes or auto-pin the top row, with per-pin smoothing to prevent snap on fast motion
- **Fishing-line constraint with K-nearest weighted blending** — Ghost-of-Tsushima-style hard distance clamp from each particle to the weighted blend of its K nearest pins (default K=4). Tension propagates instantly across the cloth instead of one spring-link per iteration. Per-row stretch authoring via optional `Curve` resource. Velocity-aware projection zeros outward radial velocity at the boundary so cloth slides instead of buzzes
- **First-class procedural fabric shader** — ships as the default material on every solver, no setup required. Three fabric types (silk with directional sheen streaks, linen with basket-weave warp/weft, animated lava with domain-warped FBM cracks and emission), each with matching procedural normal maps. Configurable primary/secondary colors with full PBR knobs (roughness, metallic, specular). Border trim with per-edge bitmask (any combination of left/right/top/bottom) and optional glow. Heraldic emblem layer (place any texture, three blend modes). Two-channel grunge — gradient + edge + noise dirt, plus edge wear that brightens fabric near hems. Lava-specific controls for crack scale, flow speed, octave count, emission strength
- **Shape-mask cutout** — bind a `sampler2D` to `shape_mask` and the fragment shader `discard`s where the red channel falls below `shape_mask_threshold`. Lets you cut non-rectangular cloth shapes (banners, ragged hems, pennants, perforations) without changing the simulation grid. UV scale + offset uniforms let you tile or position the mask
- **Drop-in custom material** — every uniform on the default shader is exposed in the inspector, but you can replace it entirely by assigning anything to `cloth_material`. Vertex `COLOR.r` carries voxel AO so any custom shader can consume it
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
| `enable_fishing_line` | `bool` | `true` | Master toggle. Hard-clamps each free particle to within `stretch × rest_distance` of the weighted blend of its K nearest pins. Velocity at the boundary has its outward radial component zeroed. Skipped when no pins exist. |
| `fishing_stretch` | `float` | `1.02` | Default stretch multiplier when `stretch_curve` is unassigned. `1.0` = perfectly inelastic, `1.02` = 2% stretch, `1.10+` = visibly slack. |
| `stretch_curve` | `Curve` | `null` | Optional per-row stretch override sampled by `row_index / (cloth_height - 1)`. `t = 0` is the top row, `t = 1` is the bottom. When assigned (and non-empty), takes precedence over `fishing_stretch`. |
| `bindings_per_particle` | `int` (1–8) | `4` | How many of each particle's nearest pins it binds to. `K = 1` reproduces v1.3 single-anchor behaviour. `K = 4` smooths Voronoi seams between multiple pins. Higher = smoother blends, bigger binding buffer. |
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

## Cloth Surface Shader

Every `GPUClothSolver` ships with a procedural fabric shader as its default material. No texture authoring required — three fabric types, full PBR controls, border trim, emblem placement, grunge/wear, animated lava, shape-mask cutout, and voxel-AO consumption are all driven by inspector uniforms. To use a custom shader, assign anything to the solver's `cloth_material` and the default is bypassed.

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

### Occlusion

| Uniform | Type | Default | Description |
|---|---|---|---|
| `ao_strength` | `float` (0–2) | `1.0` | Multiplier on the per-vertex voxel AO. The AO value itself is read from `COLOR.r` written by the solver each frame |
| `ao_roughness_boost` | `float` (0–0.5) | `0.15` | Occluded regions get rougher by this much, on top of the AO output's natural ambient suppression |

The shader writes Godot's `AO` builtin output (with `AO_LIGHT_AFFECT = 0.4`), which the engine multiplies into the ambient term and partially into direct lighting. Folds darken without screen-space noise. If you write a custom shader and want to keep this behaviour, read `COLOR.r` in `vertex()` and forward it to `AO` in `fragment()`.

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

The optional **fishing-line pass** runs once per substep after the spring solve. At init, each particle records its K nearest pins, their per-binding max distances (`rest_distance × stretch`, where `stretch` comes from the curve or the scalar fallback), and inverse-square weights normalized to sum to 1.0. Each substep the compute shader walks the K bindings, reads the pins' *current* positions, accumulates a weighted-blend target position and a weighted-blend max distance, and if the particle is outside that sphere projects it back onto the boundary. The outward radial component of velocity is zeroed at the same time so the particle slides along the boundary instead of buzzing against it. Tension propagates from any pin to any particle in a single shader invocation — no cascading through the spring network. The pass writes only the dispatch's own particle position and velocity, so no graph-coloring is required.

Particle positions are stored as `vec4(x, y, z, inverse_mass)` where `inverse_mass = 0` means pinned and `inverse_mass = 1` means free. This encoding lets the constraint solver naturally handle pin/free weighting in a single code path.

Gravity and wind are authored in world space and transformed into solver-local space by the CPU before each frame's compute dispatch. Rotating the `GPUClothSolver` node tilts the cloth's rest pose with it, but gravity still points world-down and wind still blows world-east — exactly what you want when attaching cloth to a character that turns or rolls.

The mesh readback is **asynchronous**: each frame the solver submits the compute list and sets a "pending readback" flag. On the next frame's `_physics_process`, before kicking off new work, it calls `_rd.sync()` and reads the previous frame's results back into the `ArrayMesh`. This pipelines GPU simulation against the next frame's CPU work (game logic, physics, rendering setup) instead of forcing a CPU stall on the same frame the work was submitted. The visible cloth is one frame behind the simulation, which is imperceptible at typical framerates.

If `voxel_ao_enabled`, after the cloth substep loop the solver runs two more compute passes per frame: a voxelize pass that bit-packs particle occupancy into a small grid via `atomicOr`, and a sample pass that for each particle scans a neighborhood of cells and counts occupied cells as occlusion. Per-particle AO is read back alongside positions and written to vertex `COLOR.r` (visibility = 1 − occlusion). The default surface shader consumes this as Godot's `AO` builtin output, which the engine multiplies into the ambient lighting term.

## Demo

Open `demo/cloth_demo.tscn` for a working example: a cape-sized cloth with top-row pinning and a sphere collider, along with a pinned cloth example.

The `cloth_demo_driver.gd` script (not attached by default) oscillates pins and the collider for stress testing.

## License

MIT
