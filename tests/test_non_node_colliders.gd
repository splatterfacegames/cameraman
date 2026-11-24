extends GutTest
## Collision that has no node: bodies created directly on PhysicsServer3D, as a streamed world
## attaches its baked cell collision. Their query hits carry `collider == null`.

const FRAME: float = 1.0 / 60.0

var _server_rids: Array[RID] = []
var _loose_objects: Array[Object] = []

func after_each() -> void:
	for rid in _server_rids:
		PhysicsServer3D.free_rid(rid)
	_server_rids.clear()
	for object in _loose_objects:
		if is_instance_valid(object):
			object.free()
	_loose_objects.clear()

func _server_box(position: Vector3, size: Vector3, instance_id: int = 0) -> RID:
	var shape: RID = PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(shape, size * 0.5)
	var body: RID = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body, 1)
	PhysicsServer3D.body_set_collision_mask(body, 1)
	PhysicsServer3D.body_add_shape(body, shape)
	PhysicsServer3D.body_set_state(
		body, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis.IDENTITY, position)
	)
	if instance_id != 0:
		PhysicsServer3D.body_attach_object_instance_id(body, instance_id)
	PhysicsServer3D.body_set_space(body, get_tree().root.get_world_3d().space)
	_server_rids.append(body)
	_server_rids.append(shape)
	return body

func _node_box(root: Node3D, position: Vector3, size: Vector3, group: StringName = &"") -> StaticBody3D:
	var body: StaticBody3D = StaticBody3D.new()
	body.position = position
	if not group.is_empty():
		body.add_to_group(group)
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	shape_node.shape = box
	body.add_child(shape_node)
	root.add_child(body)
	return body

func _follow_rig(root: Node3D, radius: float) -> CameramanThirdPersonFollow:
	var camera: CameramanCamera = CameramanCamera.new()
	camera.name = "camera"
	var follow: CameramanThirdPersonFollow = CameramanThirdPersonFollow.new()
	follow.avoid_obstacles.enabled = true
	follow.avoid_obstacles.camera_radius = radius
	follow.avoid_obstacles.ignore_group = &"ignored_obstacle"
	camera.add_child(follow)
	root.add_child(camera)
	return follow

func _settle() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame

func test_server_body_hit_has_no_node() -> void:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var body: RID = _server_box(Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3(0, 0, 6))
	var hit: Dictionary = root.get_world_3d().direct_space_state.intersect_ray(query)
	assert_false(hit.is_empty(), "the ray hits the server body")
	assert_null(hit.get("collider"), "a server body has no collider object")
	assert_eq(int(hit.get("collider_id", -1)), 0)
	assert_eq(hit.get("rid"), body, "the hit names the body by RID")
	assert_null(CameramanPhysicsQueries.get_hit_node(hit))

func test_hit_node_is_null_for_non_node_and_freed_objects() -> void:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var loose: Object = Object.new()
	_loose_objects.append(loose)
	_server_box(Vector3(0, 0, 4), Vector3(4, 4, 0.5), loose.get_instance_id())
	var freed: Object = Object.new()
	var freed_id: int = freed.get_instance_id()
	freed.free()
	_server_box(Vector3(20, 0, 4), Vector3(4, 4, 0.5), freed_id)
	await _settle()
	var space: PhysicsDirectSpaceState3D = root.get_world_3d().direct_space_state
	for x in [0.0, 20.0]:
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			Vector3(x, 0, 0), Vector3(x, 0, 6)
		)
		var hit: Dictionary = space.intersect_ray(query)
		assert_false(hit.is_empty())
		assert_null(CameramanPhysicsQueries.get_hit_node(hit))

func test_third_person_sphere_cast_stops_at_server_body() -> void:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var follow: CameramanThirdPersonFollow = _follow_rig(root, 0.3)
	_server_box(Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var sphere: SphereShape3D = SphereShape3D.new()
	sphere.radius = 0.3
	var exclusions: Array[RID] = follow._get_collision_exclusions()
	var fraction: float = follow._cast_shape(follow.vcam, sphere, Vector3.ZERO, Vector3(0, 0, 6), exclusions)
	# The face is at z = 3.75; a 0.3 m sphere stops with its centre near z = 3.45.
	assert_almost_eq(fraction * 6.0, 3.45, 0.06)

func test_third_person_ray_cast_stops_at_server_body() -> void:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var follow: CameramanThirdPersonFollow = _follow_rig(root, 0.0)
	_server_box(Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var exclusions: Array[RID] = follow._get_collision_exclusions()
	var fraction: float = follow._cast_ray_fraction(follow.vcam, Vector3.ZERO, Vector3(0, 0, 6), exclusions)
	assert_almost_eq(fraction * 6.0, 3.75, 0.01)

func test_third_person_excludes_server_body_by_rid() -> void:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var follow: CameramanThirdPersonFollow = _follow_rig(root, 0.3)
	var body: RID = _server_box(Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	follow.avoid_obstacles.excluded_rids.append(body)
	await _settle()
	var sphere: SphereShape3D = SphereShape3D.new()
	sphere.radius = 0.3
	var exclusions: Array[RID] = follow._get_collision_exclusions()
	assert_true(exclusions.has(body))
	assert_almost_eq(
		follow._cast_shape(follow.vcam, sphere, Vector3.ZERO, Vector3(0, 0, 6), exclusions), 1.0, 0.001
	)
	assert_almost_eq(
		follow._cast_ray_fraction(follow.vcam, Vector3.ZERO, Vector3(0, 0, 6), exclusions), 1.0, 0.001
	)

func test_third_person_ignored_node_does_not_hide_server_body() -> void:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var follow: CameramanThirdPersonFollow = _follow_rig(root, 0.3)
	_node_box(root, Vector3(0, 0, 2), Vector3(4, 4, 0.5), &"ignored_obstacle")
	_server_box(Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var sphere: SphereShape3D = SphereShape3D.new()
	sphere.radius = 0.3
	var none: Array[RID] = []
	var sphere_fraction: float = follow._cast_shape(follow.vcam, sphere, Vector3.ZERO, Vector3(0, 0, 6), none)
	var ray_fraction: float = follow._cast_ray_fraction(follow.vcam, Vector3.ZERO, Vector3(0, 0, 6), none)
	assert_almost_eq(sphere_fraction * 6.0, 3.45, 0.06)
	assert_almost_eq(ray_fraction * 6.0, 3.75, 0.01)

func test_third_person_ignores_group_of_object_attached_to_server_body() -> void:
	# The collider of a hit need not be a CollisionObject3D (CSG shapes and GridMaps are not):
	# an ignored one is skipped by the hit's RID, not by the node's.
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var follow: CameramanThirdPersonFollow = _follow_rig(root, 0.3)
	var owner_node: Node3D = Node3D.new()
	owner_node.add_to_group(&"ignored_obstacle")
	root.add_child(owner_node)
	_server_box(Vector3(0, 0, 2), Vector3(4, 4, 0.5), owner_node.get_instance_id())
	_server_box(Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var sphere: SphereShape3D = SphereShape3D.new()
	sphere.radius = 0.3
	var none: Array[RID] = []
	var sphere_fraction: float = follow._cast_shape(follow.vcam, sphere, Vector3.ZERO, Vector3(0, 0, 6), none)
	var ray_fraction: float = follow._cast_ray_fraction(follow.vcam, Vector3.ZERO, Vector3(0, 0, 6), none)
	assert_almost_eq(sphere_fraction * 6.0, 3.45, 0.06)
	assert_almost_eq(ray_fraction * 6.0, 3.75, 0.01)

func test_third_person_camera_stays_in_front_of_server_wall() -> void:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var target: Node3D = Node3D.new()
	root.add_child(target)
	var follow: CameramanThirdPersonFollow = _follow_rig(root, 0.2)
	var camera: CameramanCamera = follow.get_parent() as CameramanCamera
	camera.tracking_target = target
	follow.shoulder_offset = Vector3(0.0, 1.5, 0.0)
	follow.camera_distance = 4.0
	_server_box(Vector3(0, 1.5, 2.25), Vector3(6, 6, 0.5))
	await _settle()
	for _frame in 30:
		camera.update_state(Vector3.UP, FRAME)
	var position: Vector3 = camera.get_state().get_final_position()
	# The wall's face is at z = 2; a 0.2 m camera rests near z = 1.8, never behind the face.
	assert_lt(position.z, 1.85)
	assert_gt(position.z, 1.6)

func test_deoccluder_pulls_camera_in_front_of_server_body() -> void:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var target: Node3D = Node3D.new()
	root.add_child(target)
	var camera: CameramanCamera = CameramanCamera.new()
	camera.tracking_target = target
	var extension: CameramanDeoccluder = CameramanDeoccluder.new()
	camera.add_child(extension)
	root.add_child(camera)
	var body: RID = _server_box(Vector3(0, 0, 5), Vector3(4, 4, 0.5))
	await _settle()
	var state: CameramanCameraState = CameramanCameraState.create_default()
	state.raw_position = Vector3(0.0, 0.0, 8.0)
	extension.post_pipeline_stage_callback(camera, CameramanCore.Stage.BODY, state, 0.1)
	assert_true(extension.is_occluded())
	assert_almost_eq(state.get_final_position().z, 4.75, 0.01)
	extension.excluded_rids.append(body)
	state = CameramanCameraState.create_default()
	state.raw_position = Vector3(0.0, 0.0, 8.0)
	extension.post_pipeline_stage_callback(camera, CameramanCore.Stage.BODY, state, 0.1)
	assert_false(extension.is_occluded(), "an excluded RID does not occlude")
	assert_almost_eq(state.get_final_position().z, 8.0, 0.001)

func test_deoccluder_finds_occluder_behind_ignored_body() -> void:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var target: Node3D = Node3D.new()
	root.add_child(target)
	var camera: CameramanCamera = CameramanCamera.new()
	camera.tracking_target = target
	var extension: CameramanDeoccluder = CameramanDeoccluder.new()
	extension.ignore_group = &"ignored_obstacle"
	camera.add_child(extension)
	root.add_child(camera)
	_node_box(root, Vector3(0, 0, 2), Vector3(4, 4, 0.5), &"ignored_obstacle")
	_server_box(Vector3(0, 0, 5), Vector3(4, 4, 0.5))
	await _settle()
	var state: CameramanCameraState = CameramanCameraState.create_default()
	state.raw_position = Vector3(0.0, 0.0, 8.0)
	extension.post_pipeline_stage_callback(camera, CameramanCore.Stage.BODY, state, 0.1)
	assert_true(extension.is_occluded())
	assert_almost_eq(state.get_final_position().z, 4.75, 0.01)

func test_deoccluder_ignored_body_alone_does_not_occlude() -> void:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var target: Node3D = Node3D.new()
	root.add_child(target)
	var camera: CameramanCamera = CameramanCamera.new()
	camera.tracking_target = target
	var extension: CameramanDeoccluder = CameramanDeoccluder.new()
	extension.transparent_groups = [&"glass"]
	camera.add_child(extension)
	root.add_child(camera)
	_node_box(root, Vector3(0, 0, 2), Vector3(4, 4, 0.5), &"glass")
	await _settle()
	var state: CameramanCameraState = CameramanCameraState.create_default()
	state.raw_position = Vector3(0.0, 0.0, 8.0)
	extension.post_pipeline_stage_callback(camera, CameramanCore.Stage.BODY, state, 0.1)
	assert_false(extension.is_occluded())
	assert_almost_eq(state.get_final_position().z, 8.0, 0.001)

func test_third_person_aim_stops_on_server_body() -> void:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	var camera: CameramanCamera = CameramanCamera.new()
	root.add_child(camera)
	var extension: CameramanThirdPersonAim = CameramanThirdPersonAim.new()
	extension.ignore_group = &"ignored_obstacle"
	autofree(extension)
	_node_box(root, Vector3(0, 0, -2), Vector3(4, 4, 0.5), &"ignored_obstacle")
	var body: RID = _server_box(Vector3(0, 0, -5), Vector3(4, 4, 0.5))
	await _settle()
	var state: CameramanCameraState = CameramanCameraState.create_default()
	state.raw_position = Vector3.ZERO
	state.raw_orientation = Quaternion.IDENTITY
	extension.pre_pipeline_mutate_camera_state(camera, state, 0.1)
	assert_almost_eq(extension.aim_target.z, -4.75, 0.01)
	extension.excluded_rids.append(body)
	extension.pre_pipeline_mutate_camera_state(camera, state, 0.1)
	assert_almost_eq(extension.aim_target.z, -100.0, 0.01)
