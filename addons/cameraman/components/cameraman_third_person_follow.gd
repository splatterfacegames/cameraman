@tool
class_name CameramanThirdPersonFollow
## BODY-stage component that computes a shoulder rig, obstacle casts, and target-relative camera
## distance.
extends CameramanComponent

## Seconds to reach about 63% of desired position and yaw; zero snaps immediately.
@export var damping: Vector3 = Vector3.ZERO
## Target-local shoulder offset in meters before obstacle casts are evaluated.
@export var shoulder_offset: Vector3 = Vector3(0.5, 1.5, 0.0)
## Target-local vertical distance in meters from shoulder to camera hand.
@export var vertical_arm_length: float = 0.0
## Interpolates from left shoulder at 0 to right shoulder at 1.
@export_range(0.0, 1.0) var camera_side: float = 1.0
## Desired distance in meters from the effective hand to the camera.
@export var camera_distance: float = 4.0
## Collision settings used to shorten or slide the shoulder and camera path.
@export var avoid_obstacles: CameramanObstacleAvoidance

var _collision_distance: float = -1.0
var _cast_sphere: SphereShape3D

func _init() -> void:
	avoid_obstacles = CameramanObstacleAvoidance.new()

func stage() -> CameramanCore.Stage:
	return CameramanCore.Stage.BODY

func rebases_on_target_warp() -> bool:
	return true

func mutate_camera_state(state: CameramanCameraState, delta: float) -> void:
	var target: Node3D = follow_target
	if target == null:
		return
	var target_rotation: Quaternion = target.global_basis.get_rotation_quaternion()
	var side_offset: Vector3 = shoulder_offset
	side_offset.x *= lerpf(-1.0, 1.0, camera_side)
	var root: Vector3 = target.global_position
	var shoulder: Vector3 = root + target_rotation * side_offset
	var hand: Vector3 = shoulder + target_rotation * Vector3(0.0, vertical_arm_length, 0.0)
	var centreline: Vector3 = root + target_rotation * Vector3(
		0.0, side_offset.y + vertical_arm_length, side_offset.z
	)
	var obstacle_path: Dictionary = _get_obstacle_path(centreline, hand, target_rotation, delta)
	var effective_hand: Vector3 = obstacle_path["hand"] as Vector3
	var desired_distance: float = float(obstacle_path["distance"])
	var desired: Vector3 = effective_hand + target_rotation * Vector3(0.0, 0.0, desired_distance)
	if not vcam.previous_state_is_valid:
		state.raw_position = desired
	else:
		state.raw_position += CameramanDamper.damp_vector(desired - state.raw_position, damping, delta)
	if not vcam.previous_state_is_valid:
		state.raw_orientation = target_rotation
	else:
		var rotation_weight: float = CameramanDamper.damp(1.0, damping.y, delta)
		state.raw_orientation = state.raw_orientation.slerp(target_rotation, rotation_weight)

## Returns unobstructed root, shoulder, and hand positions for debug drawing.
func get_rig_positions() -> Array[Vector3]:
	var target: Node3D = follow_target
	if target == null:
		return [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	var rotation: Quaternion = target.global_basis.get_rotation_quaternion()
	var side_offset: Vector3 = shoulder_offset
	side_offset.x *= lerpf(-1.0, 1.0, camera_side)
	var root: Vector3 = target.global_position
	var shoulder: Vector3 = root + rotation * side_offset
	var hand: Vector3 = shoulder + rotation * Vector3(0.0, vertical_arm_length, 0.0)
	return [root, shoulder, hand]

## Updates camera_distance from an externally forced camera position.
func force_camera_position(position: Vector3, _rotation: Quaternion) -> void:
	var rig: Array[Vector3] = get_rig_positions()
	if rig.size() >= 3:
		camera_distance = rig[2].distance_to(position)

## Clears collision damping when the tracked target teleports.
func on_target_object_warped(target: Node3D, _delta: Vector3) -> void:
	if target == follow_target:
		_collision_distance = -1.0

func on_transition_from_camera(from: Object, _world_up: Vector3, _delta: float) -> bool:
	if (
		vcam == null
		or (int(vcam.get("blend_hint")) & CameramanCore.BlendHint.INHERIT_POSITION) == 0
		or from == null
		or not from.has_method("get_state")
	):
		return false
	var previous: CameramanCameraState = from.get_state()
	force_camera_position(previous.get_final_position(), previous.get_final_orientation())
	return true

func _get_obstacle_path(
	root: Vector3,
	hand: Vector3,
	rotation: Quaternion,
	delta: float
) -> Dictionary:
	var desired_distance: float = camera_distance
	if avoid_obstacles == null or not avoid_obstacles.enabled or not is_inside_tree():
		return {"hand": hand, "distance": desired_distance}
	var world_node: Node3D = vcam as Node3D
	if world_node == null or world_node.get_world_3d() == null:
		return {"hand": hand, "distance": desired_distance}
	var path: Dictionary = _cast_camera_path(world_node, root, hand, rotation, desired_distance)
	var target_distance: float = float(path["distance"])
	if _collision_distance < 0.0:
		_collision_distance = target_distance
	var damp_time: float = (
		avoid_obstacles.damping_into
		if target_distance < _collision_distance
		else avoid_obstacles.damping_from_collision
	)
	_collision_distance += (target_distance - _collision_distance) * (
		CameramanDamper.damp(1.0, damp_time, delta)
	)
	return {
		"hand": path["hand"] as Vector3,
		"distance": _collision_distance
	}

func _cast_camera_path(
	world_node: Node3D,
	root: Vector3,
	hand: Vector3,
	rotation: Quaternion,
	distance: float
) -> Dictionary:
	var exclusions: Array[RID] = _get_collision_exclusions()
	var minimum_distance: float = maxf(avoid_obstacles.minimum_distance_from_target, 0.05)
	var hand_fraction: float
	if avoid_obstacles.camera_radius <= 0.0:
		hand_fraction = _cast_ray_fraction(world_node, root, hand, exclusions)
	else:
		hand_fraction = _cast_shape(world_node, _get_cast_sphere(), root, hand, exclusions)
	if hand_fraction <= 0.0:
		var minimum_end: Vector3 = root + rotation * Vector3(0.0, 0.0, minimum_distance)
		var minimum_fraction: float
		if avoid_obstacles.camera_radius <= 0.0:
			minimum_fraction = _cast_ray_fraction(
				world_node, root, minimum_end, exclusions
			)
		else:
			minimum_fraction = _cast_shape(
				world_node, _get_cast_sphere(), root, minimum_end, exclusions
			)
		return {"hand": root, "distance": maxf(minimum_distance * minimum_fraction, 0.05)}
	var effective_hand: Vector3 = (
		hand
		if hand_fraction >= 1.0
		else root.lerp(hand, maxf(hand_fraction - 0.01, 0.0))
	)
	var end: Vector3 = effective_hand + rotation * Vector3(0.0, 0.0, distance)
	var end_fraction: float
	if avoid_obstacles.camera_radius <= 0.0:
		end_fraction = _cast_ray_fraction(world_node, effective_hand, end, exclusions)
	else:
		end_fraction = _cast_shape(world_node, _get_cast_sphere(), effective_hand, end, exclusions)
	var safe: float = distance * end_fraction
	var result: float = safe if end_fraction < 1.0 else maxf(safe, minimum_distance)
	return {"hand": effective_hand, "distance": maxf(result, 0.05)}

## One sphere shape for every cast, rather than a new one (a new physics server shape) per cast.
func _get_cast_sphere() -> SphereShape3D:
	if _cast_sphere == null:
		_cast_sphere = SphereShape3D.new()
	if not is_equal_approx(_cast_sphere.radius, avoid_obstacles.camera_radius):
		_cast_sphere.radius = avoid_obstacles.camera_radius
	return _cast_sphere

func _cast_ray_fraction(
	world_node: Node3D,
	start: Vector3,
	end: Vector3,
	exclusions: Array[RID]
) -> float:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(start, end)
	query.collision_mask = avoid_obstacles.collision_mask
	query.exclude = exclusions
	var hit: Dictionary = _intersect_ray_ignoring_groups(
		world_node.get_world_3d().direct_space_state,
		query,
		exclusions
	)
	if hit.is_empty():
		return 1.0
	var span: float = start.distance_to(end)
	if span <= 0.0001:
		return 0.0
	return clampf(start.distance_to(hit["position"] as Vector3) / span, 0.0, 1.0)

func _cast_shape(
	world_node: Node3D,
	shape: Shape3D,
	start: Vector3,
	end: Vector3,
	exclusions: Array[RID]
) -> float:
	var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = avoid_obstacles.collision_mask
	return CameramanPhysicsQueries.cast_shape_filtered(
		world_node.get_world_3d().direct_space_state, query, start, end - start, exclusions, _is_ignored_group
	)

func _get_collision_exclusions() -> Array[RID]:
	var result: Array[RID] = []
	CameramanPhysicsQueries.append_target_bodies(result, follow_target)
	if avoid_obstacles.ignore_group != &"" and is_inside_tree():
		for node in get_tree().get_nodes_in_group(avoid_obstacles.ignore_group):
			_add_collision_exclusion(result, node)
	CameramanPhysicsQueries.append_rids(result, avoid_obstacles.excluded_rids)
	return result

func _add_collision_exclusion(exclusions: Array[RID], collider: Object) -> void:
	if collider is CollisionObject3D:
		var rid: RID = (collider as CollisionObject3D).get_rid()
		if not exclusions.has(rid):
			exclusions.append(rid)

func _intersect_ray_ignoring_groups(
	space: PhysicsDirectSpaceState3D,
	query: PhysicsRayQueryParameters3D,
	exclusions: Array[RID]
) -> Dictionary:
	return CameramanPhysicsQueries.intersect_ray_filtered(space, query, exclusions, _is_ignored_group)

func _is_ignored_group(collider: Object) -> bool:
	if collider == null or not collider is Node:
		return false
	var group_name: StringName = avoid_obstacles.ignore_group
	if group_name.is_empty():
		return false
	var node: Node = collider as Node
	while node != null:
		if node.is_in_group(group_name):
			return true
		node = node.get_parent()
	return false
