extends RefCounted
## The scripted world and rigs shared by behaviour_paths.gd and query_cost.gd: a floor, a slalom
## of pillars, a wall to back into and a low ceiling, and a target that is moved by hand so that
## its path is the same under every physics engine.

const FRAME: float = 1.0 / 60.0
const WALK_SPEED: float = 3.0

static func build_world(parent: Node3D) -> void:
	_add_box(parent, "floor", Vector3(100, -0.5, 0), Vector3(400, 1, 100))
	# Pillars at x = 0: round and square, either side of the walking line.
	for index in 6:
		var side: float = 1.2 if index % 2 == 0 else -1.2
		var z: float = 9.0 - 3.5 * float(index)
		var body: StaticBody3D = StaticBody3D.new()
		body.name = "pillar_%d" % index
		body.position = Vector3(side, 2.0, z)
		var node: CollisionShape3D = CollisionShape3D.new()
		if index % 3 == 0:
			var box: BoxShape3D = BoxShape3D.new()
			box.size = Vector3(0.6, 4.0, 0.6)
			node.shape = box
		else:
			var cylinder: CylinderShape3D = CylinderShape3D.new()
			cylinder.radius = 0.3
			cylinder.height = 4.0
			node.shape = cylinder
		body.add_child(node)
		parent.add_child(body)
	# A wall of triangles at x = 100, its face at z = 5.
	var wall: StaticBody3D = StaticBody3D.new()
	wall.name = "wall"
	wall.position = Vector3(100, 2, 5.25)
	var wall_node: CollisionShape3D = CollisionShape3D.new()
	var wall_mesh: BoxMesh = BoxMesh.new()
	wall_mesh.size = Vector3(10, 4, 0.5)
	wall_mesh.subdivide_width = 7
	wall_mesh.subdivide_height = 3
	var wall_shape: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
	wall_shape.set_faces(wall_mesh.get_faces())
	wall_node.shape = wall_shape
	wall.add_child(wall_node)
	parent.add_child(wall)
	# A low ceiling at x = 200, its underside at y = 1.9.
	_add_box(parent, "ceiling", Vector3(200, 2.15, 0), Vector3(6, 0.5, 6))

static func _add_box(parent: Node3D, body_name: String, position: Vector3, size: Vector3) -> StaticBody3D:
	var body: StaticBody3D = StaticBody3D.new()
	body.name = body_name
	body.position = position
	var node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = size
	node.shape = box
	body.add_child(node)
	parent.add_child(body)
	return body

## A character body with a capsule and a head marker; returns [body, head].
static func build_target(parent: Node3D) -> Array[Node3D]:
	var body: CharacterBody3D = CharacterBody3D.new()
	body.name = "player"
	var node: CollisionShape3D = CollisionShape3D.new()
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	node.shape = capsule
	node.position.y = 0.9
	body.add_child(node)
	var head: Marker3D = Marker3D.new()
	head.name = "head"
	head.position.y = 1.6
	body.add_child(head)
	parent.add_child(body)
	return [body, head]

## Third-person follow with its own collision: sphere casts from the body to the camera.
static func build_follow_rig(parent: Node3D, target: Node3D, collide: bool) -> CameramanCamera:
	var camera: CameramanCamera = CameramanCamera.new()
	camera.name = "follow_rig"
	camera.tracking_target = target
	var follow: CameramanThirdPersonFollow = CameramanThirdPersonFollow.new()
	follow.name = "follow"
	follow.shoulder_offset = Vector3(0.5, 1.5, 0.0)
	follow.vertical_arm_length = 0.6
	follow.camera_distance = 4.0
	follow.avoid_obstacles.enabled = collide
	follow.avoid_obstacles.camera_radius = 0.2
	camera.add_child(follow)
	parent.add_child(camera)
	return camera

## Third-person follow without collision, corrected by the deoccluder's ray from the head.
static func build_deoccluder_rig(parent: Node3D, head: Node3D, collide: bool) -> CameramanCamera:
	var camera: CameramanCamera = CameramanCamera.new()
	camera.name = "deoccluder_rig"
	camera.tracking_target = head
	var follow: CameramanThirdPersonFollow = CameramanThirdPersonFollow.new()
	follow.name = "follow"
	follow.shoulder_offset = Vector3(0.5, 0.0, 0.0)
	follow.vertical_arm_length = 0.5
	follow.camera_distance = 4.0
	follow.avoid_obstacles.enabled = false
	camera.add_child(follow)
	var deoccluder: CameramanDeoccluder = CameramanDeoccluder.new()
	deoccluder.name = "deoccluder"
	deoccluder.avoid_obstacles_enabled = collide
	deoccluder.camera_radius = 0.2
	camera.add_child(deoccluder)
	parent.add_child(camera)
	return camera

## The scripted walks. Each returns the target's transform at a frame, or null when it is over.
static func path_names() -> PackedStringArray:
	return PackedStringArray(["pillars", "wall", "ceiling"])

static func path_frames(path: String) -> int:
	match path:
		"pillars":
			return int(22.0 / WALK_SPEED / FRAME)
		"wall":
			return int((4.6 / 1.5 * 2.0 + 1.0) / FRAME)
		_:
			return int(16.0 / WALK_SPEED / FRAME)

static func path_transform(path: String, frame: int) -> Transform3D:
	var time: float = float(frame) * FRAME
	match path:
		"pillars":
			# Walks down the slalom looking left and right, so the arm sweeps across the pillars.
			var yaw: float = 0.6 * sin(time * 1.3)
			return Transform3D(Basis(Vector3.UP, yaw), Vector3(0, 0, 11.0 - WALK_SPEED * time))
		"wall":
			# Backs into the wall, waits a second, walks away again.
			var back_time: float = 4.6 / 1.5
			var z: float
			if time < back_time:
				z = 1.5 * time
			elif time < back_time + 1.0:
				z = 4.6
			else:
				z = maxf(4.6 - 1.5 * (time - back_time - 1.0), 0.0)
			return Transform3D(Basis.IDENTITY, Vector3(100, 0, z))
		_:
			return Transform3D(Basis.IDENTITY, Vector3(200, 0, 8.0 - WALK_SPEED * time))
