@tool
extends EditorPlugin

const ColliderGizmoPlugin = preload("src/gpu_cloth_collider_gizmo.gd")
const SolverGizmoPlugin = preload("src/gpu_cloth_solver_gizmo.gd")

var _collider_gizmo: EditorNode3DGizmoPlugin
var _solver_gizmo: EditorNode3DGizmoPlugin


func _enter_tree() -> void:
	add_custom_type(
		"GPUClothSolver",
		"Node3D",
		preload("src/gpu_cloth_solver.gd"),
		preload("icons/gpu_cloth_solver.svg")
	)
	add_custom_type(
		"GPUClothCollider",
		"Node3D",
		preload("src/gpu_cloth_collider.gd"),
		preload("icons/gpu_cloth_collider.svg")
	)
	_collider_gizmo = ColliderGizmoPlugin.new()
	add_node_3d_gizmo_plugin(_collider_gizmo)
	_solver_gizmo = SolverGizmoPlugin.new()
	add_node_3d_gizmo_plugin(_solver_gizmo)


func _exit_tree() -> void:
	remove_custom_type("GPUClothSolver")
	remove_custom_type("GPUClothCollider")
	remove_node_3d_gizmo_plugin(_collider_gizmo)
	remove_node_3d_gizmo_plugin(_solver_gizmo)
