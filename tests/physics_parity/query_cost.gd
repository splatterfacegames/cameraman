extends SceneTree
## Times the physics queries of a rig with collision enabled, in microseconds per camera per frame,
## on the walks of behaviour_paths.gd. The cost of collision is the rig's update with collision
## minus the same rig's update without it. Each walk is repeated and the least disturbed repeat
## is reported. Also times each raw query on its own.
##
## godot --headless --path <project> -s res://tests/physics_parity/query_cost.gd -- --out=<file>

const ParityWorld: GDScript = preload("res://tests/physics_parity/parity_world.gd")
const REPEATS: int = 7
const RAW_ITERATIONS: int = 20000

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var world: Node3D = Node3D.new()
	root.add_child(world)
	ParityWorld.build_world(world)
	var target: Array[Node3D] = ParityWorld.build_target(world)
	var rigs: Dictionary = {
		"third_person_follow/collision": ParityWorld.build_follow_rig(world, target[0], true),
		"third_person_follow/no_collision": ParityWorld.build_follow_rig(world, target[0], false),
		"deoccluder/collision": ParityWorld.build_deoccluder_rig(world, target[1], true),
		"deoccluder/no_collision": ParityWorld.build_deoccluder_rig(world, target[1], false),
	}
	await physics_frame
	await physics_frame
	# For every rig and walk, the mean of each repeat; the least disturbed repeat is reported.
	var best: Dictionary = {}
	var worst: Dictionary = {}
	var frames: int = 0
	for _repeat in REPEATS:
		for path in ParityWorld.path_names():
			var totals: Dictionary = {}
			for rig_name in rigs:
				totals[rig_name] = 0
			var path_frames: int = ParityWorld.path_frames(path)
			for frame in path_frames:
				target[0].global_transform = ParityWorld.path_transform(path, frame)
				if frame % 8 == 0:
					# Let the server see the moved target now and then; every frame would only time the wait.
					await physics_frame
				frames += 1
				for rig_name in rigs:
					var camera: CameramanCamera = rigs[rig_name]
					var before: int = Time.get_ticks_usec()
					camera.update_state(Vector3.UP, ParityWorld.FRAME)
					var spent: int = Time.get_ticks_usec() - before
					totals[rig_name] += spent
					var key: String = "%s/%s" % [rig_name, path]
					worst[key] = maxi(int(worst.get(key, 0)), spent)
			for rig_name in rigs:
				var key: String = "%s/%s" % [rig_name, path]
				var mean: float = float(totals[rig_name]) / float(path_frames)
				best[key] = minf(float(best.get(key, INF)), mean)
	var per_frame: Dictionary = {}
	for key in best:
		per_frame[key] = {"mean_usec": best[key], "worst_usec": worst[key]}
	var document: Dictionary = {
		"engine": String(ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT")),
		"frames": frames,
		"rigs": per_frame,
		"raw": _time_raw_queries(),
	}
	var out_path: String = ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			out_path = argument.trim_prefix("--out=")
	var file: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(document, "  "))
	file.close()
	print("cost: wrote %s" % out_path)
	quit(0)

## One query of each kind, from the head to where the camera would be, among the pillars.
func _time_raw_queries() -> Dictionary:
	var space: PhysicsDirectSpaceState3D = root.get_world_3d().direct_space_state
	var from: Vector3 = Vector3(0.5, 1.6, 2.0)
	var to: Vector3 = Vector3(1.5, 2.1, 6.0)
	var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
	var sphere: SphereShape3D = SphereShape3D.new()
	sphere.radius = 0.2
	var shape_query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	shape_query.shape = sphere
	shape_query.transform = Transform3D(Basis.IDENTITY, from)
	shape_query.motion = to - from
	var result: Dictionary = {}
	var before: int = Time.get_ticks_usec()
	for _index in RAW_ITERATIONS:
		space.intersect_ray(ray)
	result["intersect_ray_usec"] = float(Time.get_ticks_usec() - before) / float(RAW_ITERATIONS)
	before = Time.get_ticks_usec()
	for _index in RAW_ITERATIONS:
		space.cast_motion(shape_query)
	result["cast_motion_usec"] = float(Time.get_ticks_usec() - before) / float(RAW_ITERATIONS)
	shape_query.motion = Vector3.ZERO
	shape_query.transform = Transform3D(Basis.IDENTITY, Vector3(1.2, 2.0, 5.3))
	before = Time.get_ticks_usec()
	for _index in RAW_ITERATIONS:
		space.intersect_shape(shape_query, 32)
	result["intersect_shape_usec"] = float(Time.get_ticks_usec() - before) / float(RAW_ITERATIONS)
	before = Time.get_ticks_usec()
	for _index in RAW_ITERATIONS:
		var fresh: SphereShape3D = SphereShape3D.new()
		fresh.radius = 0.2
		fresh.get_rid()
	result["new_sphere_shape_usec"] = float(Time.get_ticks_usec() - before) / float(RAW_ITERATIONS)
	return result
