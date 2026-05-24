# Contributing

Thanks for your interest in GPU Cloth Sim! Contributions are welcome.

## Ways to contribute

- **Bug reports** — open an issue with your Godot version, GPU/renderer, and
  a minimal scene or steps to reproduce.
- **Features / fixes** — open a PR (see below).
- **Questions** — the [Discord](https://discord.gg/maFsFAfqnY) is the fastest place.

## Pull requests

1. Fork the repo and branch off `main`.
2. Make your change. Keep commits focused; match the surrounding GDScript style.
3. Test against the demo scene (`Demo/cloth_demo.tscn`) — confirm the existing
   example setups (AnimatedHuman, LowPolyDude, GreenFlag, Cat) still run.
4. Open a PR describing what changed and why. Link any related issue.

PRs are how you land in the project's commit history and contributor list, so
your work is credited automatically — no manual attribution needed.

## Requirements

- **Godot 4.5+**
- **Vulkan renderer** (Forward+ or Mobile). The Compatibility (OpenGL) renderer
  is not supported — compute shaders require Vulkan.

## License

By contributing, you agree your contributions are licensed under the project's
[MIT License](LICENSE).
