extends SceneTree
## Minimal reproduction of the three Box3D query results that differ from GodotPhysics3D and
## Jolt Physics and that Cameraman works around (docs/PHYSICS.md). Prints one line each.
##
## godot --headless --path <project> -s res://tests/physics_parity/box3d_repro.gd
##
## Box3D (Tarragon c103c09308):          GodotPhysics3D and Jolt:
##   1 hit at (0, 0, 0), normal (0, 0, 0)   1 no hit
##   2 [0, 0]                               2 [1, 1]
##   3 safe 4.5 mm past contact, overlaps   3 safe before contact, no overlap

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var node: CollisionShape3D = CollisionShape3D.new()
	var box: BoxShape3D = BoxShape3D.new()
	box.size = Vector3(2, 2, 2)
	node.shape = box
	body.add_child(node)
	root.add_child(body)
	await physics_frame
	await physics_frame
	var space: PhysicsDirectSpaceState3D = root.get_world_3d().direct_space_state
	# 1. A ray from the centre of the box, with hit_from_inside left false.
	var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3(5, 0, 0))
	print("1 ray from inside, hit_from_inside=", ray.hit_from_inside, ": ", space.intersect_ray(ray))
	# 2. A sphere cast that starts inside the box.
	var sphere: SphereShape3D = SphereShape3D.new()
	sphere.radius = 0.2
	var cast: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	cast.shape = sphere
	cast.motion = Vector3(5, 0, 0)
	print("2 cast from inside: ", space.cast_motion(cast))
	# 3. A sphere cast from outside onto the face at x = 1: contact is at 2.8 m of 4.
	var from: Vector3 = Vector3(4, 0, 0)
	cast.transform = Transform3D(Basis.IDENTITY, from)
	cast.motion = Vector3(-4, 0, 0)
	var result: PackedFloat32Array = space.cast_motion(cast)
	var past_contact: float = snappedf((result[0] * 4.0 - 2.8) * 1000.0, 0.01)
	cast.transform = Transform3D(Basis.IDENTITY, from + cast.motion * result[0])
	cast.motion = Vector3.ZERO
	var overlaps: int = space.intersect_shape(cast, 4).size()
	print("3 cast onto face: ", result, ", safe is ", past_contact, " mm past contact, overlaps at safe: ", overlaps)
	quit(0)
