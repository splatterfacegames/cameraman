extends GutTest
## CameramanPhysicsQueries: the same answers under every 3D physics engine for rays and shape
## casts that start inside geometry, and for hits that are skipped.

func _box(root: Node3D, position: Vector3, size: Vector3, group: StringName = &"") -> StaticBody3D:
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

func _world() -> Node3D:
	var root: Node3D = Node3D.new()
	add_child_autofree(root)
	return root

func _settle() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame

func _never(_node: Node) -> bool:
	return false

func _in_ignored_group(node: Node) -> bool:
	return node != null and node.is_in_group(&"ignored_obstacle")

func _ray(root: Node3D, from: Vector3, to: Vector3, is_ignored: Callable) -> Dictionary:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
	var none: Array[RID] = []
	return CameramanPhysicsQueries.intersect_ray_filtered(
		root.get_world_3d().direct_space_state, query, none, is_ignored
	)

func _cast(root: Node3D, radius: float, from: Vector3, to: Vector3, is_ignored: Callable) -> float:
	var sphere: SphereShape3D = SphereShape3D.new()
	sphere.radius = radius
	var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	var none: Array[RID] = []
	return CameramanPhysicsQueries.cast_shape_filtered(
		root.get_world_3d().direct_space_state, query, from, to - from, none, is_ignored
	)

func test_ray_reports_nearest_hit() -> void:
	var root: Node3D = _world()
	var wall: StaticBody3D = _box(root, Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var hit: Dictionary = _ray(root, Vector3.ZERO, Vector3(0, 0, 6), _never)
	assert_eq(hit.get("collider"), wall)
	assert_almost_eq((hit["position"] as Vector3).z, 3.75, 0.001)

func test_ray_that_starts_inside_a_shape_leaves_it_and_hits_what_is_beyond() -> void:
	var root: Node3D = _world()
	_box(root, Vector3.ZERO, Vector3(2, 2, 2))
	var wall: StaticBody3D = _box(root, Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var hit: Dictionary = _ray(root, Vector3.ZERO, Vector3(0, 0, 6), _never)
	assert_false(hit.is_empty(), "the wall beyond is found")
	assert_eq(hit.get("collider"), wall)
	assert_almost_eq((hit["position"] as Vector3).z, 3.75, 0.001)

func test_ray_wholly_inside_a_shape_hits_nothing() -> void:
	var root: Node3D = _world()
	_box(root, Vector3.ZERO, Vector3(2, 2, 2))
	await _settle()
	assert_true(_ray(root, Vector3.ZERO, Vector3(0, 0, 0.5), _never).is_empty())
	assert_true(_ray(root, Vector3.ZERO, Vector3(0, 0, 3), _never).is_empty(), "leaving is not a hit")

func test_ray_that_starts_inside_two_nested_shapes_leaves_both() -> void:
	var root: Node3D = _world()
	_box(root, Vector3.ZERO, Vector3(2, 2, 2))
	_box(root, Vector3.ZERO, Vector3(3, 3, 3))
	var wall: StaticBody3D = _box(root, Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var hit: Dictionary = _ray(root, Vector3.ZERO, Vector3(0, 0, 6), _never)
	assert_eq(hit.get("collider"), wall)

func test_ray_skips_ignored_bodies() -> void:
	var root: Node3D = _world()
	_box(root, Vector3(0, 0, 1), Vector3(4, 4, 0.5), &"ignored_obstacle")
	_box(root, Vector3(0, 0, 2), Vector3(4, 4, 0.5), &"ignored_obstacle")
	var wall: StaticBody3D = _box(root, Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var hit: Dictionary = _ray(root, Vector3.ZERO, Vector3(0, 0, 6), _in_ignored_group)
	assert_eq(hit.get("collider"), wall)
	_box(root, Vector3(0, 0, 10), Vector3(4, 4, 0.5), &"ignored_obstacle")
	await _settle()
	assert_true(_ray(root, Vector3(0, 0, 8), Vector3(0, 0, 12), _in_ignored_group).is_empty())

func test_shape_cast_stops_short_of_a_wall() -> void:
	var root: Node3D = _world()
	_box(root, Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var fraction: float = _cast(root, 0.25, Vector3.ZERO, Vector3(0, 0, 6), _never)
	assert_almost_eq(fraction * 6.0, 3.5, 0.03)

func test_shape_cast_from_one_centimetre_away_does_not_pass_through() -> void:
	var root: Node3D = _world()
	_box(root, Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var fraction: float = _cast(root, 0.25, Vector3(0, 0, 3.49), Vector3(0, 0, 6), _never)
	assert_lt(fraction * 2.51, 0.03, "a sphere just clear of a wall is stopped by it")

func test_shape_cast_that_starts_inside_a_shape_leaves_it_and_stops_at_what_is_beyond() -> void:
	var root: Node3D = _world()
	_box(root, Vector3.ZERO, Vector3(2, 2, 2))
	_box(root, Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var fraction: float = _cast(root, 0.25, Vector3.ZERO, Vector3(0, 0, 6), _never)
	assert_almost_eq(fraction * 6.0, 3.5, 0.03)

func test_shape_cast_that_starts_partly_inside_a_shape_leaves_it() -> void:
	var root: Node3D = _world()
	_box(root, Vector3.ZERO, Vector3(2, 2, 2))
	_box(root, Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var fraction: float = _cast(root, 0.25, Vector3(0, 0, 1.1), Vector3(0, 0, 6), _never)
	assert_almost_eq(1.1 + fraction * 4.9, 3.5, 0.03)

func test_shape_cast_that_never_leaves_a_shape_is_unobstructed() -> void:
	var root: Node3D = _world()
	_box(root, Vector3.ZERO, Vector3(8, 8, 8))
	await _settle()
	assert_almost_eq(_cast(root, 0.25, Vector3.ZERO, Vector3(0, 0, 2), _never), 1.0, 0.001)

func test_shape_cast_skips_ignored_bodies() -> void:
	var root: Node3D = _world()
	_box(root, Vector3(0, 0, 1.5), Vector3(4, 4, 0.5), &"ignored_obstacle")
	_box(root, Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var fraction: float = _cast(root, 0.25, Vector3.ZERO, Vector3(0, 0, 6), _in_ignored_group)
	assert_almost_eq(fraction * 6.0, 3.5, 0.03)

func test_shape_cast_that_starts_inside_an_ignored_body_is_not_slowed_by_it() -> void:
	var root: Node3D = _world()
	_box(root, Vector3.ZERO, Vector3(2, 2, 2), &"ignored_obstacle")
	_box(root, Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	var fraction: float = _cast(root, 0.25, Vector3.ZERO, Vector3(0, 0, 6), _in_ignored_group)
	assert_almost_eq(fraction * 6.0, 3.5, 0.03)

func test_target_bodies_cover_ancestor_and_descendants() -> void:
	var root: Node3D = _world()
	var body: CharacterBody3D = CharacterBody3D.new()
	var head: Node3D = Node3D.new()
	var hitbox: Area3D = Area3D.new()
	head.add_child(hitbox)
	body.add_child(head)
	root.add_child(body)
	var exclusions: Array[RID] = []
	CameramanPhysicsQueries.append_target_bodies(exclusions, head)
	assert_true(exclusions.has(body.get_rid()))
	assert_true(exclusions.has(hitbox.get_rid()))
	assert_eq(exclusions.size(), 2)
	CameramanPhysicsQueries.append_target_bodies(exclusions, null)
	assert_eq(exclusions.size(), 2)

func test_deoccluder_ray_from_a_marker_inside_the_target_body_is_not_occluded_by_it() -> void:
	var root: Node3D = _world()
	var body: CharacterBody3D = CharacterBody3D.new()
	var shape_node: CollisionShape3D = CollisionShape3D.new()
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	shape_node.shape = capsule
	shape_node.position.y = 0.9
	body.add_child(shape_node)
	var head: Marker3D = Marker3D.new()
	head.position.y = 1.5
	body.add_child(head)
	root.add_child(body)
	var camera: CameramanCamera = CameramanCamera.new()
	camera.tracking_target = head
	var extension: CameramanDeoccluder = CameramanDeoccluder.new()
	camera.add_child(extension)
	root.add_child(camera)
	await _settle()
	var state: CameramanCameraState = CameramanCameraState.create_default()
	state.raw_position = Vector3(0.0, 1.5, 4.0)
	extension.post_pipeline_stage_callback(camera, CameramanCore.Stage.BODY, state, 0.1)
	assert_false(extension.is_occluded())
	assert_almost_eq(state.get_final_position().z, 4.0, 0.001)

func test_shape_cast_result_does_not_overlap_the_obstacle() -> void:
	var root: Node3D = _world()
	_box(root, Vector3(0, 0, 4), Vector3(4, 4, 0.5))
	await _settle()
	for end in [Vector3(0, 0, 6), Vector3(1.5, 0, 6), Vector3(3.0, 1.0, 5.0)]:
		var fraction: float = _cast(root, 0.25, Vector3.ZERO, end, _never)
		assert_lt(fraction, 1.0)
		var sphere: SphereShape3D = SphereShape3D.new()
		sphere.radius = 0.25
		var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
		query.shape = sphere
		query.transform = Transform3D(Basis.IDENTITY, end * fraction)
		var overlaps: Array[Dictionary] = root.get_world_3d().direct_space_state.intersect_shape(query, 4)
		assert_eq(overlaps.size(), 0, "where the cast stops, the sphere touches nothing")
		# And it stopped within 3 cm of contact along its path, not far short of it.
		var contact: float = (3.75 - 0.25) / end.z
		assert_gt(fraction, contact - 0.03 / end.length())

func test_shape_cast_embedded_in_a_side_wall_still_stops_at_another_body() -> void:
	var root: Node3D = _world()
	# A side wall along the whole path, which the sphere starts 5 cm inside, and a back wall.
	_box(root, Vector3(1.2, 0, 3), Vector3(2, 4, 12))
	_box(root, Vector3(-2, 0, 4), Vector3(4.2, 4, 0.5))
	await _settle()
	var fraction: float = _cast(root, 0.25, Vector3.ZERO, Vector3(0, 0, 6), _never)
	assert_almost_eq(fraction * 6.0, 3.5, 0.03)
